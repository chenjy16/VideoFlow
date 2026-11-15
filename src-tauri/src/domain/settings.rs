use serde::{Deserialize, Serialize};

/// 用户设置。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    /// 默认下载目录（绝对路径）
    pub download_dir: String,
    /// 默认容器：mp4 / mkv / 原始
    pub default_container: String,
    /// 默认清晰度：best / 1080p / 720p / 480p / 360p
    pub default_quality: String,
    /// 最大并发下载数
    pub max_concurrent: u32,
    /// 下载完成通知
    pub notifications: bool,
}

impl AppSettings {
    pub fn defaults(download_dir: String) -> Self {
        Self {
            download_dir,
            default_container: "mp4".to_string(),
            default_quality: "best".to_string(),
            max_concurrent: 2,
            notifications: true,
        }
    }
}

/// Settings patch: only the explicitly provided fields are updated.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsPatch {
    pub download_dir: Option<String>,
    pub default_container: Option<String>,
    pub default_quality: Option<String>,
    pub max_concurrent: Option<u32>,
    pub notifications: Option<bool>,
}

impl AppSettings {
    pub fn apply_patch(&mut self, patch: SettingsPatch) -> crate::error::AppResult<()> {
        if let Some(dir) = patch.download_dir {
            let trimmed = dir.trim();
            if !trimmed.starts_with('/') {
                return Err(crate::error::AppError::OutputDir(
                    "The download folder must be an absolute path".into(),
                ));
            }
            if trimmed.contains("..") {
                return Err(crate::error::AppError::OutputDir(
                    "The download folder contains an invalid path segment".into(),
                ));
            }
            self.download_dir = trimmed.to_string();
        }
        if let Some(container) = patch.default_container {
            let allowed = ["mp4", "mkv", "original"];
            if !allowed.contains(&container.as_str()) {
                return Err(crate::error::AppError::Other(format!(
                    "Unsupported default container: {container}"
                )));
            }
            self.default_container = container;
        }
        if let Some(quality) = patch.default_quality {
            let allowed = ["best", "1080p", "720p", "480p", "360p"];
            if !allowed.contains(&quality.as_str()) {
                return Err(crate::error::AppError::Other(format!(
                    "Unsupported default quality: {quality}"
                )));
            }
            self.default_quality = quality;
        }
        if let Some(max) = patch.max_concurrent {
            if !(1..=5).contains(&max) {
                return Err(crate::error::AppError::Other(
                    "Concurrent downloads must stay between 1 and 5".into(),
                ));
            }
            self.max_concurrent = max;
        }
        if let Some(notifications) = patch.notifications {
            self.notifications = notifications;
        }
        Ok(())
    }
}
