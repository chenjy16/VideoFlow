use crate::domain::{DownloadOption, MediaFormat, OptionCategory};

/// 从真实 formats 动态生成下载选项。
///
/// 设计原则：
/// 1. 不假设某站点一定存在 1080p / 720p，全部以 yt-dlp 返回的流为准；
/// 2. 视频选项使用「真实 format_id 组合」，保证下载的就是用户看到的那条流；
/// 3. 优先选择与 MP4 兼容的编码（H.264），同时保留其它编码选项；
/// 4. 分离流需要 FFmpeg 合并，`requires_merge` 会透出给前端。
pub fn build_options(formats: &[MediaFormat], duration: Option<f64>) -> Vec<DownloadOption> {
    let video_streams: Vec<&MediaFormat> = formats
        .iter()
        .filter(|f| f.has_video() && f.height.is_some())
        .collect();
    let audio_streams: Vec<&MediaFormat> = formats
        .iter()
        .filter(|f| f.has_audio() && !f.has_video())
        .collect();

    let best_audio = audio_streams.iter().copied().max_by(|a, b| {
        audio_score(a)
            .partial_cmp(&audio_score(b))
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let mut heights: Vec<u32> = video_streams.iter().filter_map(|f| f.height).collect();
    heights.sort_unstable_by(|a, b| b.cmp(a));
    heights.dedup();
    heights.truncate(6);

    let mut options: Vec<DownloadOption> = Vec::new();

    // 1. 最佳画质（自动组合最高清晰度的视频流与最佳音频流）
    if let Some(best) = heights.first().and_then(|height| {
        video_streams
            .iter()
            .copied()
            .filter(|f| f.height == Some(*height))
            .max_by(|a, b| {
                video_score(a)
                    .partial_cmp(&video_score(b))
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    }) {
        if let Some(option) =
            video_option("best", OptionCategory::Best, best, best_audio, "最佳画质")
        {
            options.push(option);
        }
    } else if let Some(audio) = best_audio {
        options.push(audio_option(
            "a-original",
            audio,
            None,
            format!("最佳音频 · {}", audio.ext.to_uppercase()),
            "保留原始音频格式，不转码".to_string(),
        ));
    }

    // 2. 各清晰度视频（同一清晰度下按编码分别给出选项）
    for height in &heights {
        let mut candidates: Vec<&MediaFormat> = video_streams
            .iter()
            .copied()
            .filter(|f| f.height == Some(*height))
            .collect();
        candidates.sort_by(|a, b| {
            video_score(b)
                .partial_cmp(&video_score(a))
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let mut seen_families: Vec<&'static str> = Vec::new();
        for candidate in candidates {
            let family = codec_family(candidate.vcodec.as_deref());
            if seen_families.contains(&family) {
                continue;
            }
            seen_families.push(family);
            let id = format!("v-{height}-{}", family_slug(family));
            if let Some(option) = video_option(
                &id,
                OptionCategory::Video,
                candidate,
                best_audio,
                &format!("{height}p"),
            ) {
                options.push(option);
            }
        }
    }

    // 3. 仅视频（不含音频，适合后期自行处理）
    for height in heights.iter().take(3) {
        if let Some(best) = video_streams
            .iter()
            .copied()
            .filter(|f| f.height == Some(*height))
            .max_by(|a, b| {
                video_score(a)
                    .partial_cmp(&video_score(b))
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
        {
            let mut option = DownloadOption {
                id: format!("vo-{height}"),
                category: OptionCategory::VideoOnly,
                label: format!("{height}p 仅视频"),
                description: Some(format!(
                    "{} · {} · 无音轨",
                    best.ext.to_uppercase(),
                    codec_family(best.vcodec.as_deref())
                )),
                height: Some(*height),
                fps: best.fps,
                container: best.ext.clone(),
                selector: best.format_id.clone(),
                video_codec: best.vcodec.clone(),
                audio_codec: None,
                estimated_bytes: best.size_bytes(),
                requires_merge: false,
                audio_format: None,
            };
            if option.label == "仅视频" {
                option.label = format!("{height}p 仅视频");
            }
            options.push(option);
        }
    }

    // 4. 仅音频
    if let Some(audio) = best_audio {
        options.push(audio_option(
            "a-original",
            audio,
            None,
            format!("最佳音频 · {}", audio.ext.to_uppercase()),
            "保留原始音频格式（需要 FFmpeg 提取）".to_string(),
        ));
        options.push(audio_option(
            "a-mp3",
            audio,
            Some("mp3"),
            "MP3".to_string(),
            "兼容性最好，需要 FFmpeg 转码".to_string(),
        ));
        options.push(audio_option(
            "a-m4a",
            audio,
            Some("m4a"),
            "M4A (AAC)".to_string(),
            "适合 Apple 生态，需要 FFmpeg 处理".to_string(),
        ));
        // WAV 体积巨大，仅在时长合理的场景下提供
        if duration.map(|d| d > 0.0 && d <= 7200.0).unwrap_or(false) {
            options.push(audio_option(
                "a-wav",
                audio,
                Some("wav"),
                "WAV".to_string(),
                "无损未压缩音频，文件较大".to_string(),
            ));
        }
    } else if let Some(combined) = formats
        .iter()
        .filter(|f| f.has_audio())
        .max_by(|a, b| a.ext.cmp(&b.ext))
    {
        options.push(audio_option(
            "a-mp3",
            combined,
            Some("mp3"),
            "MP3".to_string(),
            "从音视频文件中提取音频".to_string(),
        ));
    }

    options
}

fn video_option(
    id: &str,
    category: OptionCategory,
    video: &MediaFormat,
    best_audio: Option<&MediaFormat>,
    title: &str,
) -> Option<DownloadOption> {
    let needs_audio = !video.has_audio();
    let audio = if needs_audio { best_audio } else { None };

    // 有独立音轨但缺少音频流时，无法生成完整视频选项（仅音频站点）
    if needs_audio && audio.is_none() {
        return None;
    }

    let selector = match audio {
        Some(audio) => format!("{}+{}", video.format_id, audio.format_id),
        None => video.format_id.clone(),
    };

    let estimated_bytes = match (video.size_bytes(), audio.and_then(|a| a.size_bytes())) {
        (Some(video_size), Some(audio_size)) => Some(video_size + audio_size),
        (video_size, _) => video_size,
    };

    let mut parts = vec![
        "MP4".to_string(),
        codec_family(video.vcodec.as_deref()).to_string(),
    ];
    if let Some(fps) = video.fps.filter(|fps| *fps >= 50.0) {
        parts.push(format!("{}fps", fps.round() as i64));
    }
    parts.push(if audio.is_some() {
        "视频 + 音频".to_string()
    } else {
        "含音轨".to_string()
    });

    let label = if category == OptionCategory::Best {
        let height = video.height.map(|h| format!("{h}p")).unwrap_or_default();
        if height.is_empty() {
            title.to_string()
        } else {
            format!("{title} · {height}")
        }
    } else {
        format!("{title} · {}", codec_family(video.vcodec.as_deref()))
    };

    Some(DownloadOption {
        id: id.to_string(),
        category,
        label,
        description: Some(parts.join(" · ")),
        height: video.height,
        fps: video.fps,
        container: "mp4".to_string(),
        selector,
        video_codec: video.vcodec.clone(),
        audio_codec: audio
            .and_then(|a| a.acodec.clone())
            .or_else(|| video.acodec.clone()),
        estimated_bytes,
        requires_merge: audio.is_some(),
        audio_format: None,
    })
}

fn audio_option(
    id: &str,
    source: &MediaFormat,
    audio_format: Option<&str>,
    label: String,
    description: String,
) -> DownloadOption {
    DownloadOption {
        id: id.to_string(),
        category: OptionCategory::AudioOnly,
        label,
        description: Some(description),
        height: None,
        fps: None,
        container: audio_format.unwrap_or(&source.ext).to_string(),
        selector: source.format_id.clone(),
        video_codec: None,
        audio_codec: source.acodec.clone(),
        estimated_bytes: source.size_bytes(),
        requires_merge: true,
        audio_format: audio_format.map(|value| value.to_string()),
    }
}

/// 编码族：用于分组与展示。
fn codec_family(vcodec: Option<&str>) -> &'static str {
    let codec = vcodec.unwrap_or_default().to_lowercase();
    if codec.starts_with("avc1") || codec.starts_with("h264") {
        "H.264"
    } else if codec.starts_with("hev1") || codec.starts_with("hvc1") {
        "HEVC"
    } else if codec.starts_with("av01") {
        "AV1"
    } else if codec.starts_with("vp9") || codec.starts_with("vp09") {
        "VP9"
    } else if codec.starts_with("vp8") {
        "VP8"
    } else if codec.is_empty() || codec == "none" {
        "未知"
    } else {
        "其它"
    }
}

fn family_slug(family: &str) -> &'static str {
    match family {
        "H.264" => "h264",
        "HEVC" => "hevc",
        "AV1" => "av1",
        "VP9" => "vp9",
        "VP8" => "vp8",
        _ => "other",
    }
}

/// 视频流排序分数：优先 MP4 + H.264（macOS 兼容性最好），其次码率。
fn video_score(format: &MediaFormat) -> f64 {
    let compatibility = if format.ext == "mp4" && codec_family(format.vcodec.as_deref()) == "H.264"
    {
        4.0
    } else if format.ext == "mp4" {
        3.0
    } else if format.ext == "webm" {
        1.5
    } else {
        1.0
    };
    let bitrate = format.tbr.unwrap_or(0.0) / 1000.0;
    compatibility * 1_000.0 + bitrate
}

/// 音频流排序分数：优先 m4a（AAC），其次码率。
fn audio_score(format: &MediaFormat) -> f64 {
    let compatibility = match format.ext.as_str() {
        "m4a" => 3.0,
        "mp4" => 3.0,
        "webm" => 1.0,
        _ => 2.0,
    };
    let bitrate = format.abr.or(format.tbr).unwrap_or(0.0) / 100.0;
    compatibility * 1_000.0 + bitrate
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::FormatKind;

    fn video(id: &str, codec: &str, height: u32, tbr: f64, size: u64) -> MediaFormat {
        MediaFormat {
            format_id: id.to_string(),
            ext: "mp4".to_string(),
            kind: FormatKind::Video,
            vcodec: Some(codec.to_string()),
            acodec: Some("none".to_string()),
            width: Some(height * 16 / 9),
            height: Some(height),
            fps: Some(30.0),
            tbr: Some(tbr),
            abr: None,
            filesize: None,
            filesize_approx: Some(size),
            format_note: None,
            protocol: Some("https".to_string()),
            dynamic_range: None,
        }
    }

    fn audio(id: &str, ext: &str, abr: f64, size: u64) -> MediaFormat {
        MediaFormat {
            format_id: id.to_string(),
            ext: ext.to_string(),
            kind: FormatKind::Audio,
            vcodec: Some("none".to_string()),
            acodec: Some("mp4a.40.2".to_string()),
            width: None,
            height: None,
            fps: None,
            tbr: Some(abr),
            abr: Some(abr),
            filesize: None,
            filesize_approx: Some(size),
            format_note: None,
            protocol: Some("https".to_string()),
            dynamic_range: None,
        }
    }

    /// 近似真实的 B 站 formats 结构
    fn bilibili_formats() -> Vec<MediaFormat> {
        vec![
            audio("30216", "m4a", 43.9, 1_167_152),
            audio("30232", "m4a", 102.9, 2_732_727),
            audio("30280", "m4a", 203.7, 5_410_339),
            video("30016", "avc1.64001E", 360, 350.2, 9_298_910),
            video("100022", "av01.0.08M.08", 360, 155.8, 4_138_132),
            video("30032", "avc1.64001F", 480, 786.7, 20_887_948),
            video("30064", "avc1.640028", 720, 1752.6, 46_531_934),
            video("30080", "avc1.640032", 1080, 2629.4, 69_809_437),
            video("100026", "av01.0.08M.08", 1080, 603.6, 16_026_565),
        ]
    }

    #[test]
    fn generates_options_from_real_formats() {
        let options = build_options(&bilibili_formats(), Some(213.0));
        let ids: Vec<&str> = options.iter().map(|o| o.id.as_str()).collect();
        assert!(ids.contains(&"best"));
        assert!(ids.contains(&"v-1080-h264"));
        assert!(ids.contains(&"v-1080-av1"));
        assert!(ids.contains(&"v-720-h264"));
        assert!(ids.contains(&"vo-1080"));
        assert!(ids.contains(&"a-original"));
        assert!(ids.contains(&"a-mp3"));
        assert!(ids.contains(&"a-m4a"));
    }

    #[test]
    fn video_preset_prefers_best_audio_track() {
        let options = build_options(&bilibili_formats(), Some(213.0));
        let best = options
            .iter()
            .find(|o| o.id == "best")
            .expect("best option");
        // 最高清晰度 + 最佳音频流
        assert!(
            best.selector.ends_with("+30280"),
            "selector = {}",
            best.selector
        );
        assert!(best.requires_merge);
        assert_eq!(best.container, "mp4");
    }

    #[test]
    fn h264_preset_picked_for_compatibility() {
        let options = build_options(&bilibili_formats(), Some(213.0));
        let h264 = options
            .iter()
            .find(|o| o.id == "v-1080-h264")
            .expect("h264 option");
        assert!(
            h264.selector.starts_with("30080+"),
            "selector = {}",
            h264.selector
        );
        assert_eq!(h264.label, "1080p · H.264");
    }

    #[test]
    fn wav_only_offered_for_reasonable_duration() {
        let long = build_options(&bilibili_formats(), Some(10_800.0));
        assert!(!long
            .iter()
            .any(|o| o.audio_format.as_deref() == Some("wav")));

        let short = build_options(&bilibili_formats(), Some(300.0));
        assert!(short
            .iter()
            .any(|o| o.audio_format.as_deref() == Some("wav")));
    }

    #[test]
    fn audio_only_source_produces_audio_options() {
        let formats = vec![audio("140", "m4a", 128.0, 5_000_000)];
        let options = build_options(&formats, Some(300.0));
        assert!(options
            .iter()
            .any(|o| o.category == OptionCategory::AudioOnly));
        assert!(options
            .iter()
            .all(|o| o.category == OptionCategory::AudioOnly));
    }

    #[test]
    fn empty_formats_produce_no_options() {
        assert!(build_options(&[], None).is_empty());
    }

    #[test]
    fn combined_stream_needs_no_merge() {
        let mut format = video("18", "avc1.42001E", 360, 500.0, 10_000_000);
        format.kind = FormatKind::Combined;
        format.acodec = Some("mp4a.40.2".to_string());
        let options = build_options(&[format], None);
        let best = options.iter().find(|o| o.id == "best").expect("best");
        assert!(!best.requires_merge);
        assert_eq!(best.selector, "18");
    }
}
