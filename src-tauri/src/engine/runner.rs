use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::mpsc::UnboundedSender;

use crate::domain::{TaskKind, TaskStatus};
use crate::error::sanitize_engine_output;

use super::binaries::Engines;
use super::progress::{parse_progress_line, ParsedProgress, RawProgress};

/// 下载任务的引擎参数。
#[derive(Debug, Clone)]
pub struct RunSpec {
    pub task_id: String,
    pub url: String,
    pub selector: String,
    /// 任务类型决定输出命名模板（音频没有清晰度概念）
    pub kind: TaskKind,
    pub output_dir: PathBuf,
    /// 音视频分离时合并为该容器
    pub merge_to_mp4: bool,
    /// 音频提取目标格式；None 表示保留原始格式
    pub audio_format: Option<String>,
    /// 临时目录（存放最终路径标记文件）
    pub temp_dir: PathBuf,
}

/// 引擎运行事件。
#[derive(Debug)]
pub enum RunEvent {
    /// 阶段变化（下载 -> 合并 / 音频处理）
    Stage {
        status: TaskStatus,
        detail: Option<String>,
    },
    /// 结构化进度
    Progress(RawProgress),
    /// 运行结束
    Finished(RunOutcome),
}

#[derive(Debug)]
pub struct RunOutcome {
    pub cancelled: bool,
    pub success: bool,
    pub output_path: Option<String>,
    pub error: Option<String>,
    /// 清洗后的引擎日志尾部，便于诊断
    pub log: String,
}

/// 取消令牌：允许在任意线程安全地请求取消。
#[derive(Clone, Default)]
pub struct CancelToken {
    flag: Arc<AtomicBool>,
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.flag.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }
}

/// 启动一次 yt-dlp 下载（不阻塞调用方）。
pub fn spawn_run(
    spec: RunSpec,
    engines: Engines,
    cancel: CancelToken,
    tx: UnboundedSender<RunEvent>,
) {
    tauri::async_runtime::spawn(async move {
        let outcome = run_download(&spec, &engines, &cancel, &tx).await;
        let _ = tx.send(RunEvent::Finished(outcome));
    });
}

async fn run_download(
    spec: &RunSpec,
    engines: &Engines,
    cancel: &CancelToken,
    tx: &UnboundedSender<RunEvent>,
) -> RunOutcome {
    let marker = spec
        .temp_dir
        .join(format!("videoflow-{}.path", spec.task_id));
    let _ = std::fs::remove_file(&marker);

    // 记录启动时间：结束后要求输出文件的 mtime 不早于本次启动，
    // 以此识别「yt-dlp 跳过了下载、只回显了已存在的旧文件」的情况。
    let started_at = std::time::SystemTime::now();

    let yt_dlp = match engines.require_yt_dlp() {
        Ok(path) => path.clone(),
        Err(err) => {
            return RunOutcome {
                cancelled: false,
                success: false,
                output_path: None,
                error: Some(err.to_string()),
                log: String::new(),
            }
        }
    };

    let mut cmd = tokio::process::Command::new(&yt_dlp);
    cmd.args([
        "--newline",
        "--no-colors",
        "--no-warnings",
        "--no-playlist",
        "--no-mtime",
        "--retries",
        "3",
        "--fragment-retries",
        "5",
        "--progress-template",
        "download:%(progress)j",
        "--progress-template",
        "postprocess:%(progress)j",
        "--print-to-file",
        "after_move:filepath",
    ])
    .arg(&marker)
    // 默认策略下同名文件会被视为「已下载」而跳过，但 yt-dlp 仍会打印旧文件路径，
    // 最终被误判为下载成功；这里强制覆盖，保证每次都是真实下载。
    .arg("--force-overwrites")
    .args(["-o", output_template(spec.kind)])
    .args(["-f", &spec.selector])
    .arg("--paths")
    .arg(&spec.output_dir);

    if spec.merge_to_mp4 {
        cmd.args(["--merge-output-format", "mp4"]);
    }
    if let Some(format) = &spec.audio_format {
        cmd.arg("-x")
            .args(["--audio-format", format])
            .args(["--audio-quality", "0"]);
    }
    if let Some(dir) = engines.ffmpeg_dir() {
        cmd.arg("--ffmpeg-location").arg(dir);
    }
    cmd.arg(&spec.url);

    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .env("NO_COLOR", "1");

    // 独立进程组：取消时可以向 yt-dlp 及其 ffmpeg 子进程一起发信号
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.as_std_mut().process_group(0);
    }

    let mut child = match cmd.spawn() {
        Ok(child) => child,
        Err(err) => {
            return RunOutcome {
                cancelled: false,
                success: false,
                output_path: None,
                error: Some(format!("无法启动 yt-dlp：{err}")),
                log: String::new(),
            }
        }
    };

    let pid = child.id().unwrap_or(0);
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    // stderr 单独读取，避免管道缓冲区写满阻塞子进程
    let stderr_handle = stderr.map(|stream| {
        tauri::async_runtime::spawn(async move {
            let mut lines = BufReader::new(stream).lines();
            let mut collected: Vec<String> = Vec::new();
            while let Ok(Some(line)) = lines.next_line().await {
                if collected.len() >= 200 {
                    collected.remove(0);
                }
                collected.push(line);
            }
            collected
        })
    });

    let mut cancelled = false;
    if let Some(stdout) = stdout {
        let mut lines = BufReader::new(stdout).lines();
        let mut ticker = tokio::time::interval(Duration::from_millis(200));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        loop {
            tokio::select! {
                next = lines.next_line() => {
                    match next {
                        Ok(Some(line)) => handle_line(&line, tx),
                        Ok(None) => break,
                        Err(_) => break,
                    }
                }
                _ = ticker.tick() => {
                    if cancel.is_cancelled() {
                        cancelled = true;
                        signal(pid, libc::SIGINT);
                        break;
                    }
                }
            }
        }
    }

    // 等待退出：先礼貌 SIGINT（yt-dlp 会保存 .part），超时再强杀
    let status = match tokio::time::timeout(Duration::from_secs(8), child.wait()).await {
        Ok(result) => result.ok(),
        Err(_) => {
            signal(pid, libc::SIGKILL);
            child.wait().await.ok()
        }
    };

    let stderr_text = match stderr_handle {
        Some(handle) => handle.await.unwrap_or_default().join("\n"),
        None => String::new(),
    };
    let log = sanitize_engine_output(&stderr_text, 30);

    let output_path = read_marker(&marker);
    let _ = std::fs::remove_file(&marker);

    if cancelled {
        return RunOutcome {
            cancelled: true,
            success: false,
            output_path: None,
            error: None,
            log,
        };
    }

    let success = status.map(|s| s.success()).unwrap_or(false);
    if !success {
        let detail = if log.trim().is_empty() {
            "yt-dlp 未正常退出".to_string()
        } else {
            log.lines().last().unwrap_or("下载失败").to_string()
        };
        return RunOutcome {
            cancelled: false,
            success: false,
            output_path: None,
            error: Some(detail),
            log,
        };
    }

    // 校验输出文件真实存在且是本次运行产出的，绝不伪造成功状态
    match output_path.as_ref().map(Path::new) {
        Some(path) if path.is_file() => {
            let metadata = std::fs::metadata(path).ok();
            let size = metadata.as_ref().map(|m| m.len()).unwrap_or(0);
            if size == 0 {
                return RunOutcome {
                    cancelled: false,
                    success: false,
                    output_path: None,
                    error: Some("输出文件为空，可能下载未完成".to_string()),
                    log,
                };
            }
            let fresh = metadata
                .and_then(|m| m.modified().ok())
                .map(|modified| {
                    let floor = started_at
                        .checked_sub(Duration::from_secs(5))
                        .unwrap_or(started_at);
                    modified >= floor
                })
                .unwrap_or(false);
            if !fresh {
                return RunOutcome {
                    cancelled: false,
                    success: false,
                    output_path: None,
                    error: Some(
                        "输出文件未被本次下载更新，可能命中了上一次下载的同名文件".to_string(),
                    ),
                    log,
                };
            }
            RunOutcome {
                cancelled: false,
                success: true,
                output_path,
                error: None,
                log,
            }
        }
        _ => RunOutcome {
            cancelled: false,
            success: false,
            output_path: None,
            error: Some("下载进程已结束，但未找到输出文件".to_string()),
            log,
        },
    }
}

fn handle_line(line: &str, tx: &UnboundedSender<RunEvent>) {
    let Some(parsed) = parse_progress_line(line) else {
        return;
    };
    match parsed {
        ParsedProgress::Download(progress) => {
            let _ = tx.send(RunEvent::Progress(progress));
        }
        ParsedProgress::Postprocess(progress) => {
            let name = progress.postprocessor.clone().unwrap_or_default();
            let finished = progress.status.as_deref() == Some("finished");

            // 文件搬移是 yt-dlp 的内部收尾动作，对用户没有意义
            if name == "MoveFiles" {
                return;
            }

            let detail = if name.contains("Merger") {
                Some(if finished {
                    "合并完成".to_string()
                } else {
                    "正在使用 FFmpeg 合并音视频".to_string()
                })
            } else {
                Some(if finished {
                    format!("{name} 完成")
                } else {
                    format!("正在执行 {name}")
                })
            };

            let _ = tx.send(RunEvent::Stage {
                status: TaskStatus::Merging,
                detail,
            });
        }
    }
}

/// 输出模板：视频必须带上清晰度，否则不同清晰度会写入同名文件。
fn output_template(kind: TaskKind) -> &'static str {
    match kind {
        TaskKind::Video => "%(title).140B [%(id)s] %(resolution)s.%(ext)s",
        TaskKind::Audio => "%(title).140B [%(id)s].%(ext)s",
    }
}

fn read_marker(path: &Path) -> Option<String> {
    let content = std::fs::read_to_string(path).ok()?;
    let last = content
        .lines()
        .map(str::trim)
        .rfind(|line| !line.is_empty())?;
    Some(last.to_string())
}

/// 向整个进程组发送信号，避免遗留孤儿 ffmpeg 进程。
fn signal(pid: u32, sig: i32) {
    if pid == 0 {
        return;
    }
    #[cfg(unix)]
    unsafe {
        libc::kill(-(pid as i32), sig);
    }
    #[cfg(not(unix))]
    {
        let _ = (pid, sig);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancel_token_is_shared() {
        let token = CancelToken::new();
        let clone = token.clone();
        assert!(!clone.is_cancelled());
        token.cancel();
        assert!(clone.is_cancelled());
    }

    #[test]
    fn marker_reads_last_non_empty_line() {
        let dir = std::env::temp_dir().join("videoflow-marker-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("m.path");
        std::fs::write(&path, "\n/tmp/a.mp4\n\n").unwrap();
        assert_eq!(read_marker(&path), Some("/tmp/a.mp4".to_string()));
        let _ = std::fs::remove_file(&path);
    }
}
