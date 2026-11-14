use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;

use crate::error::{AppError, AppResult};

/// 引擎状态，用于设置页展示。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineStatus {
    pub yt_dlp_path: Option<String>,
    pub yt_dlp_version: Option<String>,
    pub ffmpeg_path: Option<String>,
    pub ffmpeg_version: Option<String>,
    pub ready: bool,
}

/// 已解析的下载引擎。
///
/// 允许缺失：应用仍可正常启动，设置页会提示缺少 yt-dlp / FFmpeg。
#[derive(Debug, Clone, Default)]
pub struct Engines {
    pub yt_dlp: Option<PathBuf>,
    pub yt_dlp_version: Option<String>,
    pub ffmpeg: Option<PathBuf>,
    pub ffmpeg_version: Option<String>,
}

impl Engines {
    /// 解析 yt-dlp 与 ffmpeg 路径。
    ///
    /// 顺序：环境变量覆盖 -> 随包 sidecar -> 开发目录 -> 常见安装位置 -> PATH。
    pub async fn detect() -> Self {
        let yt_dlp = find_yt_dlp();
        let yt_dlp_version = match &yt_dlp {
            Some(path) => probe_version(path, &["--version"]).await,
            None => None,
        };

        let ffmpeg = find_ffmpeg();
        let ffmpeg_version = match &ffmpeg {
            Some(path) => probe_version(path, &["-version"]).await,
            None => None,
        };

        Self {
            yt_dlp,
            yt_dlp_version,
            ffmpeg,
            ffmpeg_version,
        }
    }

    pub fn status(&self) -> EngineStatus {
        EngineStatus {
            yt_dlp_path: self.yt_dlp.as_ref().map(|path| path.display().to_string()),
            yt_dlp_version: self.yt_dlp_version.clone(),
            ffmpeg_path: self.ffmpeg.as_ref().map(|path| path.display().to_string()),
            ffmpeg_version: self.ffmpeg_version.clone(),
            ready: self.yt_dlp.is_some(),
        }
    }

    pub fn require_yt_dlp(&self) -> AppResult<&PathBuf> {
        self.yt_dlp.as_ref().ok_or(AppError::YtDlpMissing)
    }

    pub fn has_ffmpeg(&self) -> bool {
        self.ffmpeg.is_some()
    }

    /// 传给 yt-dlp 的 `--ffmpeg-location`，为空表示交给 yt-dlp 自行查找。
    pub fn ffmpeg_dir(&self) -> Option<PathBuf> {
        self.ffmpeg
            .as_ref()
            .and_then(|path| path.parent().map(Path::to_path_buf))
    }
}

/// 可执行文件所在的 target triple，用于定位 sidecar。
fn target_triple() -> &'static str {
    if cfg!(target_arch = "aarch64") {
        "aarch64-apple-darwin"
    } else {
        "x86_64-apple-darwin"
    }
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        match std::fs::metadata(path) {
            Ok(meta) => meta.is_file() && meta.permissions().mode() & 0o111 != 0,
            Err(_) => false,
        }
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

fn sidecar_candidates(name: &str) -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    // 1. 打包后：externalBin 会被放到可执行文件同级目录
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join(name));
        }
    }

    // 2. 开发期：src-tauri/binaries/<name>-<triple>
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    candidates.push(
        manifest_dir
            .join("binaries")
            .join(format!("{name}-{}", target_triple())),
    );
    candidates.push(manifest_dir.join("binaries").join(name));

    candidates
}

fn common_install_paths(name: &str) -> Vec<PathBuf> {
    let mut paths = vec![
        PathBuf::from("/opt/homebrew/bin").join(name),
        PathBuf::from("/usr/local/bin").join(name),
        PathBuf::from("/usr/bin").join(name),
    ];
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        paths.push(home.join(".local/bin").join(name));
        paths.push(home.join("bin").join(name));
    }
    paths
}

/// 在 PATH 中查找可执行文件（不依赖 `which` 命令）。
fn lookup_in_path(name: &str) -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join(name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn find_yt_dlp() -> Option<PathBuf> {
    if let Some(raw) = std::env::var_os("VIDEOFLOW_YTDLP_PATH") {
        let path = PathBuf::from(raw);
        if is_executable(&path) {
            return Some(path);
        }
    }

    for candidate in sidecar_candidates("yt-dlp")
        .into_iter()
        .chain(common_install_paths("yt-dlp"))
    {
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }

    lookup_in_path("yt-dlp")
}

fn find_ffmpeg() -> Option<PathBuf> {
    if let Some(raw) = std::env::var_os("VIDEOFLOW_FFMPEG_PATH") {
        let path = PathBuf::from(raw);
        if is_executable(&path) {
            return Some(path);
        }
    }

    for candidate in sidecar_candidates("ffmpeg")
        .into_iter()
        .chain(common_install_paths("ffmpeg"))
    {
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }

    lookup_in_path("ffmpeg")
}

/// 运行 `--version` 之类的探针命令并取首行输出。
async fn probe_version(bin: &Path, args: &[&str]) -> Option<String> {
    let output = tokio::time::timeout(
        Duration::from_secs(15),
        tokio::process::Command::new(bin)
            .args(args)
            .stdin(std::process::Stdio::null())
            .output(),
    )
    .await
    .ok()?
    .ok()?;

    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let first_line = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())?
        .to_string();

    // ffmpeg -version 首行形如 "ffmpeg version 8.0 Copyright ..."，只取版本号片段
    if let Some(rest) = first_line.strip_prefix("ffmpeg version ") {
        return Some(rest.split_whitespace().next().unwrap_or(rest).to_string());
    }
    Some(first_line)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_lookup_ignores_non_executable() {
        // /tmp 下不会是 yt-dlp 可执行文件
        assert!(lookup_in_path("definitely-not-a-real-binary-xyz").is_none());
    }

    #[test]
    fn target_triple_matches_platform() {
        let triple = target_triple();
        assert!(triple.contains("apple-darwin"));
    }
}
