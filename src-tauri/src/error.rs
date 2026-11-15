use serde::Serialize;

/// 应用统一错误类型。
///
/// 所有错误都会以中文字符串形式返回给前端，保证 UI 能直接展示可读信息，
/// 同时保留原始的 source 便于排查。
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("无效的链接：{0}")]
    InvalidUrl(String),

    #[error("链接协议不受支持，仅支持 http / https：{0}")]
    UnsupportedScheme(String),

    #[error("未找到 yt-dlp 可执行文件，请安装后重试")]
    YtDlpMissing,

    /// 任务需要但当前环境缺少的引擎工具（如 ffmpeg）。
    ///
    /// 发布版内置 ffmpeg / ffprobe，出现该错误说明应用包被破坏，
    /// 因此直接阻断任务，而不是让 yt-dlp 产出损坏的文件。
    #[error("应用内置的 {0} 不可用，请重新安装 VideoFlow")]
    EngineMissing(&'static str),

    #[error("视频信息解析失败：{0}")]
    Inspection(String),

    #[error("任务不存在或已被删除")]
    TaskNotFound(String),

    #[error("任务当前状态不允许该操作：{0}")]
    InvalidState(String),

    #[error("无法访问下载目录：{0}")]
    OutputDir(String),

    #[error("数据库错误：{0}")]
    Database(#[from] rusqlite::Error),

    #[error("文件操作失败：{0}")]
    Io(#[from] std::io::Error),

    #[error("数据解析失败：{0}")]
    Serde(#[from] serde_json::Error),

    #[error("{0}")]
    Other(String),
}

impl Serialize for AppError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

pub type AppResult<T> = Result<T, AppError>;

/// 截断并清洗引擎输出，避免超长日志与敏感字段进入 UI / 数据库。
pub fn sanitize_engine_output(raw: &str, max_lines: usize) -> String {
    let mut kept: Vec<String> = raw
        .lines()
        .map(|line| line.trim_end())
        .filter(|line| !line.is_empty())
        // Cookie 与认证信息不写入日志
        .filter(|line| {
            let lower = line.to_lowercase();
            !(lower.contains("cookie")
                || lower.contains("authorization")
                || lower.contains("--password")
                || lower.contains("bearer "))
        })
        .map(|line| line.to_string())
        .collect();

    if kept.len() > max_lines {
        kept = kept.split_off(kept.len() - max_lines);
    }
    kept.join("\n")
}
