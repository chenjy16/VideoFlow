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
    pub ffprobe_path: Option<String>,
    pub ffprobe_version: Option<String>,
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
    pub ffprobe: Option<PathBuf>,
    pub ffprobe_version: Option<String>,
}

impl Engines {
    /// 解析 yt-dlp / ffmpeg / ffprobe 路径。
    ///
    /// 发布版（运行于 `.app/Contents/MacOS`）只认应用自带的可执行文件，
    /// 不回落系统或 Homebrew 路径；开发期才允许多路径查找，便于本机调试。
    pub async fn detect() -> Self {
        let yt_dlp = resolve_ytdlp();
        let yt_dlp_version = match &yt_dlp {
            Some(path) => probe_version(path, &["--version"]).await,
            None => None,
        };

        let ffmpeg = resolve_ffmpeg();
        let ffmpeg_version = match &ffmpeg {
            Some(path) => probe_version(path, &["-version"]).await,
            None => None,
        };

        let ffprobe = resolve_ffprobe();
        let ffprobe_version = match &ffprobe {
            Some(path) => probe_version(path, &["-version"]).await,
            None => None,
        };

        Self {
            yt_dlp,
            yt_dlp_version,
            ffmpeg,
            ffmpeg_version,
            ffprobe,
            ffprobe_version,
        }
    }

    pub fn status(&self) -> EngineStatus {
        EngineStatus {
            yt_dlp_path: self.yt_dlp.as_ref().map(|path| path.display().to_string()),
            yt_dlp_version: self.yt_dlp_version.clone(),
            ffmpeg_path: self.ffmpeg.as_ref().map(|path| path.display().to_string()),
            ffmpeg_version: self.ffmpeg_version.clone(),
            ffprobe_path: self.ffprobe.as_ref().map(|path| path.display().to_string()),
            ffprobe_version: self.ffprobe_version.clone(),
            ready: self.yt_dlp.is_some(),
        }
    }

    pub fn require_yt_dlp(&self) -> AppResult<&PathBuf> {
        self.yt_dlp.as_ref().ok_or(AppError::YtDlpMissing)
    }

    pub fn has_ffmpeg(&self) -> bool {
        self.ffmpeg.is_some()
    }

    pub fn has_ffprobe(&self) -> bool {
        self.ffprobe.is_some()
    }

    /// 传给 yt-dlp 的 `--ffmpeg-location`，为空表示交给 yt-dlp 自行查找。
    ///
    /// ffmpeg 与 ffprobe 同目录，yt-dlp 会一并找到。
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

    // 1. 打包后：externalBin 会被放到可执行文件同级目录（Contents/MacOS）
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

/// 判断可执行文件路径是否位于 macOS 应用包内（`.app/Contents/MacOS/`）。
fn looks_bundled(exe: &Path) -> bool {
    let Some(dir) = exe.parent() else {
        return false;
    };
    let is_macos_dir = dir.file_name().is_some_and(|name| name == "MacOS");
    let is_contents_dir = dir
        .parent()
        .and_then(Path::file_name)
        .is_some_and(|name| name == "Contents");
    is_macos_dir && is_contents_dir
}

/// 当前进程是否运行在打包后的 `.app` 内。
fn is_bundled_app() -> bool {
    std::env::current_exe()
        .map(|exe| looks_bundled(&exe))
        .unwrap_or(false)
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

fn resolve_ytdlp() -> Option<PathBuf> {
    resolve_tool("yt-dlp", "VIDEOFLOW_YTDLP_PATH")
}

fn resolve_ffmpeg() -> Option<PathBuf> {
    resolve_tool("ffmpeg", "VIDEOFLOW_FFMPEG_PATH")
}

fn resolve_ffprobe() -> Option<PathBuf> {
    resolve_tool("ffprobe", "VIDEOFLOW_FFPROBE_PATH")
}

/// Single place that resolves tool paths.
///
/// Order:
///   1. Explicit environment override (handy for debugging, works in releases too)
///   2. Bundled sidecar / the `binaries` folder during development
///   3. Development only: well-known install locations and PATH
///
/// A released build must **never** pick up Homebrew / PATH tools from the build machine,
/// otherwise the bundle looks tiny but only runs where it was built.
fn resolve_tool(name: &str, env_key: &str) -> Option<PathBuf> {
    if let Some(raw) = std::env::var_os(env_key) {
        let path = PathBuf::from(raw);
        if is_executable(&path) {
            return Some(path);
        }
        log::warn!(
            "{} points to a non-executable path, ignoring it: {}",
            env_key,
            path.display()
        );
    }

    for candidate in sidecar_candidates(name) {
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }

    if is_bundled_app() {
        return None;
    }

    for candidate in common_install_paths(name) {
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }

    lookup_in_path(name)
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
    let first_line = text.lines().map(str::trim).find(|line| !line.is_empty())?;
    Some(short_version(first_line))
}

/// 从 `-version` 首行中截出纯版本号。
///
/// ffmpeg / ffprobe 的首行形如 "ffprobe version 8.0.1 Copyright (c) ..."，
/// 其余工具（yt-dlp）本身就是纯版本号，原样返回。
fn short_version(first_line: &str) -> String {
    let rest = first_line
        .strip_prefix("ffmpeg version ")
        .or_else(|| first_line.strip_prefix("ffprobe version "));
    match rest {
        Some(rest) => rest.split_whitespace().next().unwrap_or(rest).to_string(),
        None => first_line.to_string(),
    }
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

    #[test]
    fn short_version_strips_ffmpeg_banner() {
        assert_eq!(
            short_version("ffmpeg version 8.0.1 Copyright (c) 2007-2025 the FFmpeg developers"),
            "8.0.1"
        );
        assert_eq!(
            short_version("ffprobe version 8.0.1 Copyright (c) 2007-2025 the FFmpeg developers"),
            "8.0.1"
        );
        assert_eq!(short_version("2026.10.26"), "2026.10.26");
    }

    #[test]
    fn bundled_detection_recognizes_app_layout() {
        assert!(looks_bundled(Path::new(
            "/Applications/VideoFlow.app/Contents/MacOS/videoflow"
        )));
        assert!(!looks_bundled(Path::new(
            "/Users/dev/project/src-tauri/target/debug/videoflow"
        )));
        assert!(!looks_bundled(Path::new("/opt/homebrew/bin/ffmpeg")));
    }
}
