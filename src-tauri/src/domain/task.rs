use serde::{Deserialize, Serialize};

use crate::error::{AppError, AppResult};

/// 任务状态。
///
/// `Paused` 仅在未来底层引擎支持可靠断点续传时启用，MVP 阶段不对外暴露，
/// 因此不会出现“把取消伪装成暂停”的情况。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Waiting,
    Extracting,
    Downloading,
    Merging,
    Completed,
    Failed,
    Cancelled,
    /// 应用退出或异常终止导致的未完成任务
    Interrupted,
}

impl TaskStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            TaskStatus::Waiting => "waiting",
            TaskStatus::Extracting => "extracting",
            TaskStatus::Downloading => "downloading",
            TaskStatus::Merging => "merging",
            TaskStatus::Completed => "completed",
            TaskStatus::Failed => "failed",
            TaskStatus::Cancelled => "cancelled",
            TaskStatus::Interrupted => "interrupted",
        }
    }

    pub fn parse(value: &str) -> Self {
        match value {
            "waiting" => TaskStatus::Waiting,
            "extracting" => TaskStatus::Extracting,
            "downloading" => TaskStatus::Downloading,
            "merging" => TaskStatus::Merging,
            "completed" => TaskStatus::Completed,
            "failed" => TaskStatus::Failed,
            "cancelled" => TaskStatus::Cancelled,
            _ => TaskStatus::Interrupted,
        }
    }

    /// 终态：不会再变化，除非用户重试。
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            TaskStatus::Completed
                | TaskStatus::Failed
                | TaskStatus::Cancelled
                | TaskStatus::Interrupted
        )
    }

    /// 由引擎运行中阶段映射任务状态。
    pub fn is_running(&self) -> bool {
        matches!(
            self,
            TaskStatus::Extracting | TaskStatus::Downloading | TaskStatus::Merging
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskKind {
    Video,
    Audio,
}

impl TaskKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            TaskKind::Video => "video",
            TaskKind::Audio => "audio",
        }
    }

    pub fn parse(value: &str) -> Self {
        match value {
            "audio" => TaskKind::Audio,
            _ => TaskKind::Video,
        }
    }
}

/// 持久化的下载任务。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadTask {
    pub id: String,
    pub url: String,
    pub title: String,
    pub thumbnail: Option<String>,
    pub site: Option<String>,
    pub status: TaskStatus,
    pub kind: TaskKind,
    /// yt-dlp `-f` 表达式（真实 format_id 组合，例如 `30032+30280`）
    pub selector: Option<String>,
    pub format_label: Option<String>,
    pub container: Option<String>,
    /// 音频提取目标格式（mp3 / m4a / wav）；None 表示视频任务或保留原始格式
    pub audio_format: Option<String>,
    pub output_dir: Option<String>,
    pub output_path: Option<String>,
    pub total_bytes: Option<i64>,
    pub downloaded_bytes: i64,
    pub speed: Option<f64>,
    pub eta: Option<i64>,
    pub created_at: String,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub error_message: Option<String>,
}

/// 创建下载任务的入参。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateDownloadRequest {
    pub url: String,
    pub title: String,
    pub thumbnail: Option<String>,
    pub site: Option<String>,
    pub kind: TaskKind,
    /// yt-dlp `-f` 表达式，必须来自解析结果中的真实 format_id
    pub selector: String,
    pub format_label: String,
    pub container: String,
    pub output_dir: String,
    /// 视频 + 音频分离时使用 FFmpeg 合并到指定容器
    #[serde(default)]
    pub merge_to_mp4: bool,
    /// 音频提取目标格式：mp3 / m4a / wav，None 表示保留原始格式
    #[serde(default)]
    pub audio_format: Option<String>,
    /// 解析阶段得到的预估总大小，用于整体进度计算
    #[serde(default)]
    pub expected_bytes: Option<i64>,
}

/// 推送给前端的进度快照（高频，轻量）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskProgress {
    pub id: String,
    pub status: TaskStatus,
    pub stage: String,
    pub downloaded_bytes: i64,
    pub total_bytes: Option<i64>,
    pub speed: Option<f64>,
    pub eta: Option<i64>,
    pub percent: f64,
    pub current_file: Option<String>,
}

impl CreateDownloadRequest {
    /// Validates the payload: no path traversal, illegal formats or empty fields.
    pub fn validate(&self) -> AppResult<()> {
        if self.url.trim().is_empty() {
            return Err(AppError::InvalidUrl("The link can't be empty".into()));
        }
        if self.selector.trim().is_empty() {
            return Err(AppError::Other("The download format can't be empty".into()));
        }
        if !self.output_dir.starts_with('/') {
            return Err(AppError::OutputDir(
                "The download folder must be an absolute path".into(),
            ));
        }
        if self.output_dir.contains("..") {
            return Err(AppError::OutputDir(
                "The download folder contains an invalid path segment".into(),
            ));
        }
        if self.container.contains('/') || self.container.contains("..") {
            return Err(AppError::Other("Invalid container format".into()));
        }
        if let Some(fmt) = &self.audio_format {
            let allowed = ["mp3", "m4a", "wav", "aac", "opus", "flac"];
            if !allowed.contains(&fmt.as_str()) {
                return Err(AppError::Other(format!("Unsupported audio format: {fmt}")));
            }
        }
        Ok(())
    }
}
