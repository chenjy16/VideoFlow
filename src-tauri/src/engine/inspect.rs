use std::process::Stdio;
use std::time::Duration;

use serde_json::Value;

use crate::domain::{FormatKind, MediaFormat, MediaInfo};
use crate::error::{sanitize_engine_output, AppError, AppResult};

use super::binaries::Engines;
use super::options::build_options;

const INSPECT_TIMEOUT: Duration = Duration::from_secs(120);

/// 使用 `--dump-single-json` 获取结构化元信息。
///
/// 严格依赖结构化 JSON，不解析人类可读日志。
pub async fn inspect_url(engines: &Engines, raw_url: &str) -> AppResult<MediaInfo> {
    let url = super::validate_url(raw_url)?;
    let yt_dlp = engines.require_yt_dlp()?;

    let mut cmd = tokio::process::Command::new(yt_dlp);
    cmd.args([
        "--dump-single-json",
        "--no-warnings",
        "--no-playlist",
        "--no-colors",
        "--no-progress",
        "--socket-timeout",
        "20",
        "--retries",
        "3",
    ])
    .arg(&url)
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .kill_on_drop(true);

    let output = match tokio::time::timeout(INSPECT_TIMEOUT, cmd.output()).await {
        Ok(result) => result?,
        Err(_) => {
            return Err(AppError::Inspection(
                "解析超时，请检查网络连接或稍后重试".to_string(),
            ))
        }
    };

    if !output.status.success() {
        let stderr = sanitize_engine_output(&String::from_utf8_lossy(&output.stderr), 6);
        let detail = if stderr.is_empty() {
            format!("yt-dlp 退出码 {}", output.status.code().unwrap_or(-1))
        } else {
            stderr
        };
        return Err(AppError::Inspection(detail));
    }

    let value: Value = serde_json::from_slice(&output.stdout)
        .map_err(|err| AppError::Inspection(format!("无法解析 yt-dlp 返回的 JSON：{err}")))?;

    parse_media_info(
        &value,
        &url,
        engines.yt_dlp_version.as_deref().unwrap_or("unknown"),
    )
}

/// 把 yt-dlp 的 JSON 映射成领域模型。
///
/// 单独拆出来便于用固定 fixture 做单元测试。
pub fn parse_media_info(
    value: &Value,
    requested_url: &str,
    engine_version: &str,
) -> AppResult<MediaInfo> {
    if value
        .get("_has_drm")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return Err(AppError::Inspection(
            "该内容受 DRM 保护，VideoFlow 不支持也不应绕过访问控制".to_string(),
        ));
    }

    let formats = parse_formats(value);
    if formats.is_empty() {
        let is_playlist = value.get("_type").and_then(Value::as_str) == Some("playlist");
        return Err(AppError::Inspection(if is_playlist {
            "该链接是播放列表或多 P 合集，请使用单个视频链接".to_string()
        } else {
            "没有解析到可下载的格式".to_string()
        }));
    }

    let duration = number(value, "duration");
    let options = build_options(&formats, duration);

    if options.is_empty() {
        return Err(AppError::Inspection("该内容没有可用的音视频流".to_string()));
    }

    Ok(MediaInfo {
        id: string_of(value.get("id")).unwrap_or_else(|| "unknown".to_string()),
        title: string_of(value.get("title")).unwrap_or_else(|| "未命名视频".to_string()),
        thumbnail: string_of(value.get("thumbnail")),
        duration,
        uploader: string_of(value.get("uploader")).or_else(|| string_of(value.get("channel"))),
        site: string_of(value.get("extractor_key")).or_else(|| string_of(value.get("extractor"))),
        webpage_url: string_of(value.get("webpage_url"))
            .or_else(|| string_of(value.get("original_url")))
            .unwrap_or_else(|| requested_url.to_string()),
        width: number(value, "width").map(|v| v as u32),
        height: number(value, "height").map(|v| v as u32),
        formats,
        options,
        engine_version: engine_version.to_string(),
    })
}

fn parse_formats(value: &Value) -> Vec<MediaFormat> {
    let Some(array) = value.get("formats").and_then(Value::as_array) else {
        return Vec::new();
    };

    array
        .iter()
        .filter_map(|entry| {
            let format_id = string_of(entry.get("format_id"))?;
            let ext = string_of(entry.get("ext")).unwrap_or_else(|| "unknown".to_string());

            let vcodec = string_of(entry.get("vcodec"));
            let acodec = string_of(entry.get("acodec"));
            let has_video = vcodec.as_deref().map(|c| c != "none").unwrap_or(false);
            let has_audio = acodec.as_deref().map(|c| c != "none").unwrap_or(false);

            // 跳过封面 / 雪碧图 / 无任何流的条目
            if ext == "mhtml" || (!has_video && !has_audio) {
                return None;
            }
            if entry
                .get("format_note")
                .and_then(Value::as_str)
                .map(|note| note.to_lowercase().contains("storyboard"))
                .unwrap_or(false)
            {
                return None;
            }

            let kind = if has_video && has_audio {
                FormatKind::Combined
            } else if has_video {
                FormatKind::Video
            } else {
                FormatKind::Audio
            };

            Some(MediaFormat {
                format_id,
                ext,
                kind,
                vcodec: vcodec.filter(|c| c != "none"),
                acodec: acodec.filter(|c| c != "none"),
                width: number(entry, "width").map(|v| v as u32),
                height: number(entry, "height").map(|v| v as u32),
                fps: number(entry, "fps"),
                tbr: number(entry, "tbr"),
                abr: number(entry, "abr"),
                filesize: number(entry, "filesize").map(|v| v as u64),
                filesize_approx: number(entry, "filesize_approx").map(|v| v as u64),
                format_note: string_of(entry.get("format_note")),
                protocol: string_of(entry.get("protocol")),
                dynamic_range: string_of(entry.get("dynamic_range")),
            })
        })
        .collect()
}

fn string_of(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(text) if !text.trim().is_empty() => Some(text.trim().to_string()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

fn number(value: &Value, key: &str) -> Option<f64> {
    value.get(key).and_then(Value::as_f64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::OptionCategory;

    const FIXTURE: &str = r#"{
        "id": "BV1GJ411x7h7",
        "title": "【官方 MV】Never Gonna Give You Up",
        "thumbnail": "https://i0.hdslb.com/cover.jpg",
        "duration": 213.0,
        "uploader": "索尼音乐中国",
        "extractor_key": "BiliBili",
        "webpage_url": "https://www.bilibili.com/video/BV1GJ411x7h7",
        "formats": [
            {"format_id": "30232", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2",
             "abr": 102.9, "filesize_approx": 2732727, "protocol": "https"},
            {"format_id": "30080", "ext": "mp4", "vcodec": "avc1.640032", "acodec": "none",
             "height": 1080, "width": 1920, "fps": 30, "tbr": 2629.4,
             "filesize_approx": 69809437, "protocol": "https"},
            {"format_id": "100026", "ext": "mp4", "vcodec": "av01.0.08M.08", "acodec": "none",
             "height": 1080, "width": 1920, "fps": 30, "tbr": 603.6,
             "filesize_approx": 16026565, "protocol": "https"},
            {"format_id": "sb0", "ext": "mhtml", "vcodec": "none", "acodec": "none",
             "format_note": "storyboard"}
        ]
    }"#;

    #[test]
    fn parses_realistic_payload() {
        let value: Value = serde_json::from_str(FIXTURE).unwrap();
        let info = parse_media_info(
            &value,
            "https://www.bilibili.com/video/BV1GJ411x7h7",
            "2026.10.26",
        )
        .expect("parse");

        assert_eq!(info.title, "【官方 MV】Never Gonna Give You Up");
        assert_eq!(info.site.as_deref(), Some("BiliBili"));
        assert_eq!(info.duration, Some(213.0));
        // storyboard 与空流被过滤掉
        assert_eq!(info.formats.len(), 3);
        assert!(info
            .options
            .iter()
            .any(|o| o.category == OptionCategory::Best));
        assert!(info.options.iter().any(|o| o.container == "mp3"));
        assert_eq!(info.engine_version, "2026.10.26");
    }

    #[test]
    fn rejects_drm_content() {
        let value: Value = serde_json::json!({"_has_drm": true, "formats": []});
        let err = parse_media_info(&value, "https://example.com", "test").unwrap_err();
        assert!(err.to_string().contains("DRM"));
    }

    #[test]
    fn reports_playlist_links() {
        let value: Value = serde_json::json!({"_type": "playlist", "entries": []});
        let err = parse_media_info(&value, "https://example.com/playlist", "test").unwrap_err();
        assert!(err.to_string().contains("播放列表"));
    }

    #[test]
    fn falls_back_when_fields_missing() {
        let value: Value = serde_json::json!({
            "formats": [
                {"format_id": 18, "ext": "mp4", "vcodec": "avc1.42001E", "acodec": "mp4a.40.2",
                 "height": 360, "tbr": 500}
            ]
        });
        let info = parse_media_info(&value, "https://example.com/v", "test").expect("parse");
        assert_eq!(info.id, "unknown");
        assert_eq!(info.title, "未命名视频");
        assert_eq!(info.webpage_url, "https://example.com/v");
        // 数字形式的 format_id 也能识别
        assert_eq!(info.formats[0].format_id, "18");
    }
}
