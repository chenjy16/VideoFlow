export type TaskStatus =
  | "waiting"
  | "extracting"
  | "downloading"
  | "merging"
  | "completed"
  | "failed"
  | "cancelled"
  | "interrupted";

export type TaskKind = "video" | "audio";

export type OptionCategory = "best" | "video" | "video_only" | "audio_only";

export type FormatKind = "video" | "audio" | "combined";

export interface MediaFormat {
  formatId: string;
  ext: string;
  kind: FormatKind;
  vcodec: string | null;
  acodec: string | null;
  width: number | null;
  height: number | null;
  fps: number | null;
  tbr: number | null;
  abr: number | null;
  filesize: number | null;
  filesizeApprox: number | null;
  formatNote: string | null;
  protocol: string | null;
  dynamicRange: string | null;
}

export interface DownloadOption {
  id: string;
  category: OptionCategory;
  label: string;
  description: string | null;
  height: number | null;
  fps: number | null;
  container: string;
  selector: string;
  videoCodec: string | null;
  audioCodec: string | null;
  estimatedBytes: number | null;
  requiresMerge: boolean;
  audioFormat: string | null;
}

export interface MediaInfo {
  id: string;
  title: string;
  thumbnail: string | null;
  duration: number | null;
  uploader: string | null;
  site: string | null;
  webpageUrl: string;
  width: number | null;
  height: number | null;
  formats: MediaFormat[];
  options: DownloadOption[];
  engineVersion: string;
}

export interface DownloadTask {
  id: string;
  url: string;
  title: string;
  thumbnail: string | null;
  site: string | null;
  status: TaskStatus;
  kind: TaskKind;
  /** yt-dlp `-f` 表达式（真实 format_id 组合，如 `30032+30280`） */
  selector: string | null;
  formatLabel: string | null;
  container: string | null;
  audioFormat: string | null;
  outputDir: string | null;
  outputPath: string | null;
  totalBytes: number | null;
  downloadedBytes: number;
  speed: number | null;
  eta: number | null;
  createdAt: string;
  startedAt: string | null;
  completedAt: string | null;
  errorMessage: string | null;
}

export interface TaskProgress {
  id: string;
  status: TaskStatus;
  stage: string;
  downloadedBytes: number;
  totalBytes: number | null;
  speed: number | null;
  eta: number | null;
  percent: number;
  currentFile: string | null;
}

export interface CreateDownloadRequest {
  url: string;
  title: string;
  thumbnail: string | null;
  site: string | null;
  kind: TaskKind;
  /** yt-dlp `-f` 表达式，来自解析结果中的 Option.selector */
  selector: string;
  formatLabel: string;
  container: string;
  outputDir: string;
  mergeToMp4: boolean;
  audioFormat: string | null;
  expectedBytes: number | null;
}

export interface AppSettings {
  downloadDir: string;
  defaultContainer: string;
  defaultQuality: string;
  maxConcurrent: number;
  notifications: boolean;
}

export type SettingsPatch = Partial<AppSettings>;

export interface EngineStatus {
  ytDlpPath: string | null;
  ytDlpVersion: string | null;
  ffmpegPath: string | null;
  ffmpegVersion: string | null;
  ready: boolean;
}
