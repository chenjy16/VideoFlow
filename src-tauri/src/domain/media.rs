use serde::{Deserialize, Serialize};

/// 流类型：纯视频 / 纯音频 / 音视频合一。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FormatKind {
    Video,
    Audio,
    Combined,
}

/// yt-dlp 返回的单个流（format）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaFormat {
    pub format_id: String,
    pub ext: String,
    pub kind: FormatKind,
    pub vcodec: Option<String>,
    pub acodec: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub fps: Option<f64>,
    pub tbr: Option<f64>,
    pub abr: Option<f64>,
    pub filesize: Option<u64>,
    pub filesize_approx: Option<u64>,
    pub format_note: Option<String>,
    pub protocol: Option<String>,
    pub dynamic_range: Option<String>,
}

impl MediaFormat {
    /// 优先使用精确大小，其次使用估算大小。
    pub fn size_bytes(&self) -> Option<u64> {
        self.filesize.or(self.filesize_approx)
    }

    pub fn has_video(&self) -> bool {
        match &self.vcodec {
            Some(codec) => codec != "none",
            None => false,
        }
    }

    pub fn has_audio(&self) -> bool {
        match &self.acodec {
            Some(codec) => codec != "none",
            None => false,
        }
    }
}

/// 下载选项分类，用于前端分组展示。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OptionCategory {
    /// 最佳视频 + 最佳音频
    Best,
    /// 指定清晰度的视频（必要时自动合并音频）
    Video,
    /// 仅视频流
    VideoOnly,
    /// 仅音频（原始格式或转码）
    AudioOnly,
}

/// 动态生成的下载选项。
///
/// `selector` 直接使用 yt-dlp 的 `-f` 表达式；为了精确还原用户选择，
/// 视频选项会使用真实 `format_id` 组合（例如 `30080+30280`）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadOption {
    pub id: String,
    pub category: OptionCategory,
    pub label: String,
    pub description: Option<String>,
    pub height: Option<u32>,
    pub fps: Option<f64>,
    pub container: String,
    pub selector: String,
    pub video_codec: Option<String>,
    pub audio_codec: Option<String>,
    /// 估算体积（视频流 + 音频流），仅用于展示
    pub estimated_bytes: Option<u64>,
    pub requires_merge: bool,
    pub audio_format: Option<String>,
}

/// 解析后的媒体信息。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaInfo {
    pub id: String,
    pub title: String,
    pub thumbnail: Option<String>,
    pub duration: Option<f64>,
    pub uploader: Option<String>,
    pub site: Option<String>,
    pub webpage_url: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub formats: Vec<MediaFormat>,
    pub options: Vec<DownloadOption>,
    /// yt-dlp 版本，便于前端展示解析来源
    pub engine_version: String,
}
