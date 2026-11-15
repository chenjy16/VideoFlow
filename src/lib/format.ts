import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/** Human readable byte size */
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

/** Download speed */
export function formatSpeed(bytesPerSecond?: number | null): string {
  if (!bytesPerSecond || bytesPerSecond <= 0) return "—";
  return `${formatBytes(bytesPerSecond)}/s`;
}

/** Remaining time, abbreviated (45s / 3m 20s / 1h 05m) */
export function formatEta(seconds?: number | null): string {
  if (seconds === null || seconds === undefined || seconds <= 0) return "—";
  const total = Math.round(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  if (hours > 0) return `${hours}h ${minutes.toString().padStart(2, "0")}m`;
  if (minutes > 0) return `${minutes}m ${secs.toString().padStart(2, "0")}s`;
  return `${secs}s`;
}

/** Media duration as H:MM:SS / M:SS */
export function formatDuration(seconds?: number | null): string {
  if (!seconds || seconds <= 0) return "—";
  const total = Math.round(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  const pad = (value: number) => value.toString().padStart(2, "0");
  return hours > 0 ? `${hours}:${pad(minutes)}:${pad(secs)}` : `${minutes}:${pad(secs)}`;
}

/**
 * Timestamp in the UI language's conventions (Nov 15, 2:08 PM).
 * Fixed to en-US so an English UI never renders localised date names.
 */
export function formatDateTime(value?: string | null): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

/** Codec name shorthand: avc1.640032 -> H.264 */
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

/**
 * Site name as reported by yt-dlp, or null when it is missing/blank.
 * The caller supplies the fallback so the wording stays in the dictionary.
 */
export function siteName(site?: string | null): string | null {
  const trimmed = site?.trim();
  return trimmed ? trimmed : null;
}
