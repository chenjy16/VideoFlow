use serde::Serialize;

/// Application-wide error type.
///
/// Every variant surfaces to the frontend as a plain English string, so the UI can
/// render it directly; the original `source` is kept for diagnostics.
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("Invalid link: {0}")]
    InvalidUrl(String),

    #[error("Unsupported link scheme. Only http and https are supported: {0}")]
    UnsupportedScheme(String),

    #[error("yt-dlp wasn't found. Install it and try again.")]
    YtDlpMissing,

    /// Engine tool the task needs but this build doesn't have (e.g. ffmpeg).
    ///
    /// Released builds bundle ffmpeg / ffprobe, so hitting this means the app bundle
    /// is damaged. Block the task instead of letting yt-dlp write broken files.
    #[error("The bundled {0} is unavailable. Reinstall VideoFlow.")]
    EngineMissing(&'static str),

    #[error("Couldn't read video info: {0}")]
    Inspection(String),

    #[error("This task no longer exists.")]
    TaskNotFound(String),

    #[error("This task can't do that right now: {0}")]
    InvalidState(String),

    #[error("Can't access the download folder: {0}")]
    OutputDir(String),

    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("File operation failed: {0}")]
    Io(#[from] std::io::Error),

    #[error("Couldn't parse data: {0}")]
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

/// Truncates and scrubs engine output so oversized logs and secrets never reach the UI / database.
pub fn sanitize_engine_output(raw: &str, max_lines: usize) -> String {
    let mut kept: Vec<String> = raw
        .lines()
        .map(|line| line.trim_end())
        .filter(|line| !line.is_empty())
        // Never log cookies or credentials
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
