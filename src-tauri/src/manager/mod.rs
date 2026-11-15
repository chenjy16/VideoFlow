use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use tauri::{AppHandle, Emitter};
use tokio::sync::mpsc;

use crate::domain::{
    AppSettings, CreateDownloadRequest, DownloadTask, SettingsPatch, TaskProgress, TaskStatus,
};
use crate::engine::{
    spawn_run, CancelToken, EngineStatus, Engines, ProgressAccumulator, RunEvent, RunSpec,
};
use crate::error::{AppError, AppResult};
use crate::storage::database::now_iso;
use crate::storage::{download_repo, settings_repo, Database};

pub const EVENT_TASK_UPDATED: &str = "task:updated";
pub const EVENT_TASK_PROGRESS: &str = "task:progress";
pub const EVENT_TASK_REMOVED: &str = "task:removed";

/// 进度推送节流间隔
const PROGRESS_EMIT_INTERVAL: Duration = Duration::from_millis(200);
/// 进度落库间隔
const PROGRESS_PERSIST_INTERVAL: Duration = Duration::from_secs(2);

#[derive(Default)]
struct Runtime {
    cancels: HashMap<String, CancelToken>,
    started: HashSet<String>,
}

/// 下载任务管理器：队列调度、并发控制、子进程生命周期与事件推送。
pub struct TaskManager {
    app: AppHandle,
    db: Arc<Database>,
    engines: RwLock<Engines>,
    settings: Mutex<AppSettings>,
    runtime: Mutex<Runtime>,
    temp_dir: PathBuf,
}

impl TaskManager {
    pub fn new(
        app: AppHandle,
        db: Arc<Database>,
        engines: Engines,
        settings: AppSettings,
        temp_dir: PathBuf,
    ) -> Arc<Self> {
        Arc::new(Self {
            app,
            db,
            engines: RwLock::new(engines),
            settings: Mutex::new(settings),
            runtime: Mutex::new(Runtime::default()),
            temp_dir,
        })
    }

    /// 启动时调用：未完成任务统一标记为 interrupted。
    pub fn recover(&self) -> AppResult<usize> {
        let ids = self
            .db
            .with_conn(download_repo::mark_active_as_interrupted)?;
        if !ids.is_empty() {
            log::info!("检测到 {} 个未完成任务，已标记为 interrupted", ids.len());
        }
        Ok(ids.len())
    }

    pub fn settings(&self) -> AppSettings {
        self.settings
            .lock()
            .map(|guard| guard.clone())
            .unwrap_or_else(|_| AppSettings::defaults("/tmp".into()))
    }

    pub fn engine_status(&self) -> EngineStatus {
        self.engines_snapshot().status()
    }

    /// 当前引擎快照（Clone 后使用，避免持有读锁跨越 await）。
    pub fn engines_snapshot(&self) -> Engines {
        self.engines
            .read()
            .map(|guard| guard.clone())
            .unwrap_or_default()
    }

    /// 重新检测引擎；用户安装依赖后无需重启应用。
    pub async fn refresh_engines(self: &Arc<Self>) {
        let detected = Engines::detect().await;
        if let Ok(mut guard) = self.engines.write() {
            *guard = detected;
        }
        self.pump();
    }

    pub fn update_settings(&self, patch: SettingsPatch) -> AppResult<AppSettings> {
        let mut guard = self
            .settings
            .lock()
            .map_err(|_| AppError::Other("设置状态损坏".into()))?;
        settings_repo::update(&self.db, patch, &mut guard)
    }

    pub fn list_tasks(&self, limit: i64) -> AppResult<Vec<DownloadTask>> {
        self.db
            .with_conn(|conn| download_repo::list_tasks(conn, limit))
    }

    pub fn list_history(
        &self,
        query: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> AppResult<Vec<DownloadTask>> {
        self.db
            .with_conn(|conn| download_repo::list_history(conn, query, limit, offset))
    }

    pub fn get_task(&self, id: &str) -> AppResult<DownloadTask> {
        self.db
            .with_conn(|conn| download_repo::get(conn, id))?
            .ok_or_else(|| AppError::TaskNotFound(id.to_string()))
    }

    /// 读取任务日志（已清洗），用于错误诊断。
    pub fn task_logs(&self, id: &str, limit: i64) -> AppResult<Vec<String>> {
        self.db
            .with_conn(|conn| download_repo::list_logs(conn, id, limit))
    }

    /// 创建任务并加入队列。
    pub fn create(self: &Arc<Self>, request: CreateDownloadRequest) -> AppResult<DownloadTask> {
        request.validate()?;
        let engines = self.engines_snapshot();
        engines.require_yt_dlp()?;

        // 分离流合并与音频提取必须有 FFmpeg（ffprobe 同样必需：yt-dlp 的后处理
        // 会用它读取码流信息），否则 yt-dlp 会留下无法播放的文件。
        // selector 里带 '+' 说明是分离的音视频流，不论容器如何都需要合并。
        // 缺工具时直接报错，而不是先下载再失败。
        let needs_ffmpeg = request.merge_to_mp4
            || request.audio_format.is_some()
            || request.selector.contains('+');
        if needs_ffmpeg && !engines.has_ffmpeg() {
            return Err(AppError::EngineMissing("FFmpeg"));
        }
        if needs_ffmpeg && !engines.has_ffprobe() {
            return Err(AppError::EngineMissing("FFprobe"));
        }

        let output_dir = PathBuf::from(&request.output_dir);
        std::fs::create_dir_all(&output_dir)
            .map_err(|err| AppError::OutputDir(format!("{} ({err})", output_dir.display())))?;
        if !output_dir.is_dir() {
            return Err(AppError::OutputDir(format!(
                "{} 不是目录",
                output_dir.display()
            )));
        }

        let task = DownloadTask {
            id: uuid::Uuid::new_v4().to_string(),
            url: request.url,
            title: request.title,
            thumbnail: request.thumbnail,
            site: request.site,
            status: TaskStatus::Waiting,
            kind: request.kind,
            selector: Some(request.selector),
            format_label: Some(request.format_label),
            container: Some(request.container),
            audio_format: request.audio_format,
            output_dir: Some(request.output_dir),
            output_path: None,
            total_bytes: request.expected_bytes,
            downloaded_bytes: 0,
            speed: None,
            eta: None,
            created_at: now_iso(),
            started_at: None,
            completed_at: None,
            error_message: None,
        };

        self.db
            .with_conn(|conn| download_repo::insert(conn, &task))?;
        let _ = self.app.emit(EVENT_TASK_UPDATED, &task);
        self.pump();
        Ok(task)
    }

    /// 取消任务：等待中的直接取消，运行中的向进程组发送 SIGINT。
    pub fn cancel(self: &Arc<Self>, id: &str) -> AppResult<DownloadTask> {
        let task = self.get_task(id)?;

        let token = {
            let runtime = self
                .runtime
                .lock()
                .map_err(|_| AppError::Other("任务状态损坏".into()))?;
            runtime.cancels.get(id).cloned()
        };

        if let Some(token) = token {
            token.cancel();
            return Ok(task);
        }

        if task.status == TaskStatus::Waiting {
            self.db.with_conn(|conn| {
                download_repo::set_status(conn, id, TaskStatus::Cancelled, None)
            })?;
            let updated = self.get_task(id)?;
            let _ = self.app.emit(EVENT_TASK_UPDATED, &updated);
            self.pump();
            return Ok(updated);
        }

        Err(AppError::InvalidState(format!(
            "任务当前状态为 {}，无法取消",
            task.status.as_str()
        )))
    }

    /// 重试：仅允许终态任务重新排队。
    pub fn retry(self: &Arc<Self>, id: &str) -> AppResult<DownloadTask> {
        let task = self.get_task(id)?;
        if !task.status.is_terminal() {
            return Err(AppError::InvalidState(
                "只有已结束的任务可以重新开始".into(),
            ));
        }
        if task.status == TaskStatus::Completed {
            return Err(AppError::InvalidState(
                "任务已完成，如需重新下载请从历史记录中重新下载".into(),
            ));
        }

        self.db
            .with_conn(|conn| download_repo::reset_for_retry(conn, id))?;

        let updated = self.get_task(id)?;
        let _ = self.app.emit(EVENT_TASK_UPDATED, &updated);
        self.pump();
        Ok(updated)
    }

    /// 删除任务记录（不删除磁盘文件）。
    pub fn remove(self: &Arc<Self>, id: &str) -> AppResult<()> {
        let task = self.get_task(id)?;
        if task.status.is_running() {
            return Err(AppError::InvalidState("请先取消任务再删除".into()));
        }

        self.runtime
            .lock()
            .map_err(|_| AppError::Other("任务状态损坏".into()))?
            .cancels
            .remove(id);

        self.db.with_conn(|conn| download_repo::delete(conn, id))?;
        let _ = self.app.emit(EVENT_TASK_REMOVED, id);
        self.pump();
        Ok(())
    }

    /// 重新下载（历史记录）：复制原任务参数并新建任务。
    pub fn redownload(self: &Arc<Self>, id: &str) -> AppResult<DownloadTask> {
        let task = self.get_task(id)?;
        let container = task.container.clone().unwrap_or_else(|| "mp4".into());
        let request = CreateDownloadRequest {
            url: task.url,
            title: task.title,
            thumbnail: task.thumbnail,
            site: task.site,
            kind: task.kind,
            selector: task.selector.unwrap_or_default(),
            format_label: task.format_label.unwrap_or_default(),
            container: container.clone(),
            output_dir: task
                .output_dir
                .unwrap_or_else(|| self.settings().download_dir),
            merge_to_mp4: container != "original",
            audio_format: task.audio_format,
            expected_bytes: task.total_bytes,
        };
        self.create(request)
    }

    /// 调度：在并发上限内启动等待中的任务。
    pub fn pump(self: &Arc<Self>) {
        let max_concurrent = self.settings().max_concurrent.max(1) as usize;

        loop {
            let running = self
                .runtime
                .lock()
                .map(|runtime| runtime.cancels.len())
                .unwrap_or(0);
            if running >= max_concurrent {
                return;
            }

            let next = match self.db.with_conn(download_repo::next_waiting) {
                Ok(task) => task,
                Err(err) => {
                    log::error!("读取待执行任务失败: {err}");
                    return;
                }
            };

            match next {
                Some(task) => {
                    if !self.start_task(&task) {
                        return;
                    }
                }
                None => return,
            }
        }
    }

    fn start_task(self: &Arc<Self>, task: &DownloadTask) -> bool {
        {
            let mut runtime = match self.runtime.lock() {
                Ok(runtime) => runtime,
                Err(_) => return false,
            };
            if !runtime.started.insert(task.id.clone()) {
                return false;
            }
        }

        let _ = self
            .db
            .with_conn(|conn| download_repo::mark_started(conn, &task.id));

        if let Ok(updated) = self.get_task(&task.id) {
            let _ = self.app.emit(EVENT_TASK_UPDATED, &updated);
        }

        let cancel = CancelToken::new();
        if let Ok(mut runtime) = self.runtime.lock() {
            runtime.cancels.insert(task.id.clone(), cancel.clone());
        }

        let spec = RunSpec {
            task_id: task.id.clone(),
            url: task.url.clone(),
            selector: task.selector.clone().unwrap_or_default(),
            kind: task.kind,
            output_dir: PathBuf::from(
                task.output_dir
                    .clone()
                    .unwrap_or_else(|| self.settings().download_dir),
            ),
            merge_to_mp4: task.kind == crate::domain::TaskKind::Video
                && task.container.as_deref() != Some("original"),
            audio_format: task.audio_format.clone(),
            temp_dir: self.temp_dir.clone(),
        };

        let (tx, rx) = mpsc::unbounded_channel();
        spawn_run(spec, self.engines_snapshot(), cancel, tx);

        let manager = Arc::clone(self);
        let task_id = task.id.clone();
        let expected = task.total_bytes;
        tauri::async_runtime::spawn(async move {
            manager.monitor(task_id, expected, rx).await;
        });
        true
    }

    async fn monitor(
        self: Arc<Self>,
        task_id: String,
        expected_bytes: Option<i64>,
        mut rx: mpsc::UnboundedReceiver<RunEvent>,
    ) {
        let mut accumulator = ProgressAccumulator::new(expected_bytes);
        let mut status = TaskStatus::Extracting;
        let mut last_emit = Instant::now() - PROGRESS_EMIT_INTERVAL;
        let mut last_persist = Instant::now();
        let mut last_snapshot = crate::engine::progress::ProgressSnapshot {
            downloaded_bytes: 0,
            total_bytes: expected_bytes,
            speed: None,
            eta: None,
            percent: 0.0,
        };

        while let Some(event) = rx.recv().await {
            match event {
                RunEvent::Progress(progress) => {
                    let snapshot = accumulator.on_progress(&progress);
                    last_snapshot = snapshot.clone();
                    if status == TaskStatus::Extracting || status == TaskStatus::Waiting {
                        status = TaskStatus::Downloading;
                    }
                    if status == TaskStatus::Downloading {
                        self.emit_progress(
                            &task_id,
                            status,
                            "downloading",
                            &snapshot,
                            &mut last_emit,
                        );

                        if last_persist.elapsed() >= PROGRESS_PERSIST_INTERVAL {
                            last_persist = Instant::now();
                            let _ = self.db.with_conn(|conn| {
                                download_repo::update_progress(
                                    conn,
                                    &task_id,
                                    snapshot.downloaded_bytes,
                                    snapshot.total_bytes,
                                    snapshot.speed,
                                    snapshot.eta,
                                )
                            });
                        }
                    }
                }
                RunEvent::Stage {
                    status: stage,
                    detail,
                } => {
                    status = stage;
                    // 进入后处理阶段：下载已完成，进度按 100% 展示
                    let snapshot = crate::engine::progress::ProgressSnapshot {
                        downloaded_bytes: last_snapshot
                            .total_bytes
                            .unwrap_or(last_snapshot.downloaded_bytes),
                        total_bytes: last_snapshot.total_bytes,
                        speed: None,
                        eta: None,
                        percent: 100.0,
                    };
                    self.emit_progress(
                        &task_id,
                        status,
                        detail.as_deref().unwrap_or("merging"),
                        &snapshot,
                        &mut last_emit,
                    );
                }
                RunEvent::Finished(outcome) => {
                    self.finish(&task_id, outcome).await;
                    break;
                }
            }
        }
    }

    fn emit_progress(
        &self,
        task_id: &str,
        status: TaskStatus,
        stage: &str,
        snapshot: &crate::engine::progress::ProgressSnapshot,
        last_emit: &mut Instant,
    ) {
        if last_emit.elapsed() < PROGRESS_EMIT_INTERVAL {
            return;
        }
        *last_emit = Instant::now();

        let progress = TaskProgress {
            id: task_id.to_string(),
            status,
            stage: stage.to_string(),
            downloaded_bytes: snapshot.downloaded_bytes,
            total_bytes: snapshot.total_bytes,
            speed: snapshot.speed,
            eta: snapshot.eta,
            percent: snapshot.percent,
            current_file: None,
        };
        let _ = self.app.emit(EVENT_TASK_PROGRESS, &progress);
    }

    async fn finish(self: &Arc<Self>, task_id: &str, outcome: crate::engine::RunOutcome) {
        {
            if let Ok(mut runtime) = self.runtime.lock() {
                runtime.cancels.remove(task_id);
                runtime.started.remove(task_id);
            }
        }

        if !outcome.log.trim().is_empty() {
            let level = if outcome.success { "info" } else { "error" };
            let _ = self
                .db
                .with_conn(|conn| download_repo::append_log(conn, task_id, level, &outcome.log));
        }

        if outcome.cancelled {
            let _ = self
                .db
                .with_conn(|conn| download_repo::mark_cancelled(conn, task_id));
        } else if outcome.success {
            let size = outcome
                .output_path
                .as_ref()
                .and_then(|path| std::fs::metadata(path).ok())
                .map(|meta| meta.len() as i64);

            if let Some(path) = outcome.output_path.as_deref() {
                let _ = self
                    .db
                    .with_conn(|conn| download_repo::mark_completed(conn, task_id, path, size));
            }
        } else {
            let message = outcome.error.unwrap_or_else(|| "下载失败".to_string());
            let _ = self
                .db
                .with_conn(|conn| download_repo::mark_failed(conn, task_id, &message));
        }

        if let Ok(task) = self.get_task(task_id) {
            let _ = self.app.emit(EVENT_TASK_UPDATED, &task);
            if task.status == TaskStatus::Completed {
                self.notify_completed(&task);
            }
        }

        self.pump();
    }

    fn notify_completed(&self, task: &DownloadTask) {
        if !self.settings().notifications {
            return;
        }
        use tauri_plugin_notification::NotificationExt;
        let _ = self
            .app
            .notification()
            .builder()
            .title("下载完成")
            .body(format!("{} 已保存到下载目录", task.title))
            .show();
    }

    /// 应用退出时取消所有运行中任务，避免孤儿进程。
    pub fn shutdown(&self) {
        if let Ok(runtime) = self.runtime.lock() {
            for token in runtime.cancels.values() {
                token.cancel();
            }
        }
    }
}
