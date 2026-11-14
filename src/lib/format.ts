import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/** 人类可读的文件体积 */
export function formatBytes(bytes?: number | null): string {
  if (bytes === null || bytes === undefined || Number.isNaN(bytes) || bytes <= 0) {
    return "—";
  }
  const units = ["B", "KB", "MB", "GB", "TB"];
  const exponent = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const value = bytes / 1024 ** exponent;
  const digits = value >= 100 || exponent === 0 ? 0 : 1;
  return `${value.toFixed(digits)} ${units[exponent]}`;
}

/** 下载速度 */
export function formatSpeed(bytesPerSecond?: number | null): string {
  if (!bytesPerSecond || bytesPerSecond <= 0) return "—";
  return `${formatBytes(bytesPerSecond)}/s`;
}

/** 剩余时间（秒） */
export function formatEta(seconds?: number | null): string {
  if (seconds === null || seconds === undefined || seconds <= 0) return "—";
  const total = Math.round(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  if (hours > 0) return `${hours} 小时 ${minutes} 分`;
  if (minutes > 0) return `${minutes} 分 ${secs} 秒`;
  return `${secs} 秒`;
}

/** 视频时长 */
export function formatDuration(seconds?: number | null): string {
  if (!seconds || seconds <= 0) return "—";
  const total = Math.round(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  const pad = (value: number) => value.toString().padStart(2, "0");
  return hours > 0 ? `${hours}:${pad(minutes)}:${pad(secs)}` : `${minutes}:${pad(secs)}`;
}

/** 时间戳展示 */
export function formatDateTime(value?: string | null): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

/** 编码名简写：avc1.640032 -> H.264 */
export function prettyCodec(codec?: string | null): string {
  if (!codec || codec === "none") return "—";
  const lower = codec.toLowerCase();
  if (lower.startsWith("avc1") || lower.startsWith("h264")) return "H.264";
  if (lower.startsWith("hev1") || lower.startsWith("hvc1")) return "HEVC";
  if (lower.startsWith("av01")) return "AV1";
  if (lower.startsWith("vp9") || lower.startsWith("vp09")) return "VP9";
  if (lower.startsWith("vp8")) return "VP8";
  if (lower.startsWith("mp4a")) return "AAC";
  if (lower.startsWith("opus")) return "Opus";
  if (lower.startsWith("vorbis")) return "Vorbis";
  return codec;
}

/** 站点名美化 */
export function prettySite(site?: string | null): string {
  if (!site) return "未知站点";
  return site;
}
