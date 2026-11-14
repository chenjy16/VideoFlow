pub mod binaries;
pub mod inspect;
pub mod options;
pub mod progress;
pub mod runner;

pub use binaries::{EngineStatus, Engines};
pub use inspect::inspect_url;
pub use progress::ProgressAccumulator;
pub use runner::{spawn_run, CancelToken, RunEvent, RunOutcome, RunSpec};

use url::Url;

use crate::error::{AppError, AppResult};

/// 校验用户输入的链接。
///
/// 只接受 http / https，其它协议（file://、data: 等）一律拒绝，
/// 避免把本地路径当作下载源。
pub fn validate_url(raw: &str) -> AppResult<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(AppError::InvalidUrl("链接不能为空".into()));
    }
    let parsed = Url::parse(trimmed)
        .map_err(|_| AppError::InvalidUrl(format!("无法识别的链接：{trimmed}")))?;
    match parsed.scheme() {
        "http" | "https" => {}
        other => return Err(AppError::UnsupportedScheme(other.to_string())),
    }
    if parsed.host_str().unwrap_or_default().is_empty() {
        return Err(AppError::InvalidUrl(format!("链接缺少主机名：{trimmed}")));
    }
    Ok(parsed.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_http_urls() {
        assert!(validate_url("https://www.bilibili.com/video/BV1xx").is_ok());
        assert!(validate_url("  http://example.com/a.mp4  ").is_ok());
    }

    #[test]
    fn rejects_empty_and_invalid() {
        assert!(validate_url("").is_err());
        assert!(validate_url("not a url").is_err());
        assert!(validate_url("https://").is_err());
    }

    #[test]
    fn rejects_non_http_schemes() {
        assert!(validate_url("file:///etc/passwd").is_err());
        assert!(validate_url("ftp://example.com/a.mp4").is_err());
    }
}
