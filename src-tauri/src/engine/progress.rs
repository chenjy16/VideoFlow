use serde::Deserialize;

/// yt-dlp `--progress-template ...:%(progress)j` 输出的完整进度对象。
///
/// 字段在不同站点 / 阶段并不总是齐全，因此全部使用 Option。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct RawProgress {
    pub status: Option<String>,
    pub downloaded_bytes: Option<i64>,
    pub total_bytes: Option<i64>,
    pub total_bytes_estimate: Option<i64>,
    pub speed: Option<f64>,
    pub eta: Option<i64>,
    pub filename: Option<String>,
    pub tmpfilename: Option<String>,
    pub elapsed: Option<f64>,
    pub postprocessor: Option<String>,
    pub fragment_index: Option<i64>,
    pub fragment_count: Option<i64>,
}

#[derive(Debug, Clone)]
pub enum ParsedProgress {
    /// 下载阶段进度
    Download(RawProgress),
    /// 后处理阶段（合并 / 音频提取 / 移动文件）
    Postprocess(RawProgress),
}

/// 解析一行 stdout。
///
/// yt-dlp 的进度模板输出是单行 JSON；其它日志行返回 None，
/// 从而避免依赖人类可读日志文本。
pub fn parse_progress_line(line: &str) -> Option<ParsedProgress> {
    let trimmed = line.trim();
    if !trimmed.starts_with('{') || !trimmed.ends_with('}') {
        return None;
    }
    let parsed: RawProgress = serde_json::from_str(trimmed).ok()?;

    if parsed.postprocessor.is_some() {
        Some(ParsedProgress::Postprocess(parsed))
    } else if parsed.downloaded_bytes.is_some()
        || parsed.total_bytes.is_some()
        || parsed.status.is_some()
    {
        Some(ParsedProgress::Download(parsed))
    } else {
        None
    }
}

/// 整体下载进度快照。
#[derive(Debug, Clone)]
pub struct ProgressSnapshot {
    pub downloaded_bytes: i64,
    pub total_bytes: Option<i64>,
    pub speed: Option<f64>,
    pub eta: Option<i64>,
    pub percent: f64,
}

/// 分片下载（视频流 + 音频流）会分别上报进度，
/// 这里按「已完成流 + 当前流」聚合出整体进度。
#[derive(Debug, Default)]
pub struct ProgressAccumulator {
    expected_total: Option<i64>,
    completed_bytes: i64,
    current_file: Option<String>,
    current_total: Option<i64>,
}

impl ProgressAccumulator {
    pub fn new(expected_total: Option<i64>) -> Self {
        Self {
            expected_total: expected_total.filter(|value| *value > 0),
            ..Default::default()
        }
    }

    pub fn on_progress(&mut self, progress: &RawProgress) -> ProgressSnapshot {
        if let Some(filename) = &progress.filename {
            let changed = self.current_file.as_deref() != Some(filename.as_str());
            if changed {
                if let Some(previous_total) = self.current_total {
                    self.completed_bytes += previous_total;
                }
                self.current_file = Some(filename.clone());
                self.current_total = None;
            }
        }

        let stream_total = progress.total_bytes.or(progress.total_bytes_estimate);
        if stream_total.is_some() {
            self.current_total = stream_total;
        }

        let downloaded = self.completed_bytes + progress.downloaded_bytes.unwrap_or(0);

        let total = match (self.expected_total, stream_total) {
            (Some(expected), _) => Some(expected),
            (None, Some(current)) => Some(self.completed_bytes + current),
            (None, None) => None,
        }
        .map(|total| total.max(downloaded));

        let percent = match total {
            Some(total) if total > 0 => {
                (downloaded as f64 / total as f64 * 100.0).clamp(0.0, 100.0)
            }
            _ => 0.0,
        };

        ProgressSnapshot {
            downloaded_bytes: downloaded,
            total_bytes: total,
            speed: progress.speed,
            eta: progress.eta,
            percent,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 真实取自 yt-dlp 2026.10 的 B 站下载输出
    const REAL_LINE: &str = r#"{"status": "downloading", "downloaded_bytes": 7168, "total_bytes": 20872903, "tmpfilename": "/tmp/a.f30032.mp4.part", "filename": "/tmp/a.f30032.mp4", "eta": 3, "speed": 5702725.924127466, "elapsed": 0.69, "ctx_id": null, "_eta_str": "00:03", "_percent_str": "  0.0%"}"#;

    const POSTPROCESS_LINE: &str = r#"{"status": "started", "postprocessor": "Merger", "_default_template": "Merger started"}"#;

    #[test]
    fn parses_download_progress() {
        match parse_progress_line(REAL_LINE) {
            Some(ParsedProgress::Download(p)) => {
                assert_eq!(p.downloaded_bytes, Some(7168));
                assert_eq!(p.total_bytes, Some(20872903));
                assert_eq!(p.eta, Some(3));
                assert!(p.speed.unwrap() > 0.0);
            }
            other => panic!("expected download progress, got {other:?}"),
        }
    }

    #[test]
    fn parses_postprocess_progress() {
        match parse_progress_line(POSTPROCESS_LINE) {
            Some(ParsedProgress::Postprocess(p)) => {
                assert_eq!(p.postprocessor.as_deref(), Some("Merger"));
                assert_eq!(p.status.as_deref(), Some("started"));
            }
            other => panic!("expected postprocess, got {other:?}"),
        }
    }

    #[test]
    fn ignores_human_readable_logs() {
        assert!(parse_progress_line("[BiliBili] Downloading webpage").is_none());
        assert!(parse_progress_line("[download] Destination: /tmp/a.mp4").is_none());
        assert!(parse_progress_line("{}").is_none());
    }

    #[test]
    fn aggregates_two_streams_against_expected_total() {
        let mut acc = ProgressAccumulator::new(Some(30_000_000));
        let first = acc.on_progress(&RawProgress {
            filename: Some("/tmp/video.mp4".into()),
            downloaded_bytes: Some(10_000_000),
            total_bytes: Some(20_000_000),
            ..Default::default()
        });
        assert!((first.percent - 33.3).abs() < 0.2);

        // 第二个流（音频）开始，第一个流按它的总大小计入已完成
        let second = acc.on_progress(&RawProgress {
            filename: Some("/tmp/audio.m4a".into()),
            downloaded_bytes: Some(5_000_000),
            total_bytes: Some(10_000_000),
            ..Default::default()
        });
        assert!((second.percent - 83.3).abs() < 0.3);
        assert_eq!(second.total_bytes, Some(30_000_000));
    }

    #[test]
    fn falls_back_to_stream_total_without_expected() {
        let mut acc = ProgressAccumulator::new(None);
        let snapshot = acc.on_progress(&RawProgress {
            filename: Some("/tmp/a.mp4".into()),
            downloaded_bytes: Some(5_000_000),
            total_bytes: Some(10_000_000),
            ..Default::default()
        });
        assert!((snapshot.percent - 50.0).abs() < 0.1);
        assert_eq!(snapshot.total_bytes, Some(10_000_000));
    }

    #[test]
    fn percent_never_exceeds_one_hundred() {
        let mut acc = ProgressAccumulator::new(Some(1_000));
        let snapshot = acc.on_progress(&RawProgress {
            downloaded_bytes: Some(5_000),
            total_bytes: Some(5_000),
            ..Default::default()
        });
        assert_eq!(snapshot.percent, 100.0);
    }
}
