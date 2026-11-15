import { invoke } from "@tauri-apps/api/core";

import { t } from "@/i18n";
import type {
  AppSettings,
  CreateDownloadRequest,
  DownloadTask,
  EngineStatus,
  MediaInfo,
  SettingsPatch,
} from "@/types";

/**
 * Every backend call lives here so the UI only depends on these functions —
 * the transport can be swapped or mocked without touching components.
 */
export const api = {
  inspectUrl(url: string): Promise<MediaInfo> {
    return invoke<MediaInfo>("inspect_url", { url });
  },

  listTasks(limit?: number): Promise<DownloadTask[]> {
    return invoke<DownloadTask[]>("list_tasks", { limit });
  },

  getTask(id: string): Promise<DownloadTask> {
    return invoke<DownloadTask>("get_task", { id });
  },

  createDownload(request: CreateDownloadRequest): Promise<DownloadTask> {
    return invoke<DownloadTask>("create_download", { request });
  },

  cancelDownload(id: string): Promise<DownloadTask> {
    return invoke<DownloadTask>("cancel_download", { id });
  },

  retryDownload(id: string): Promise<DownloadTask> {
    return invoke<DownloadTask>("retry_download", { id });
  },

  removeDownload(id: string): Promise<void> {
    return invoke<void>("remove_download", { id });
  },

  redownload(id: string): Promise<DownloadTask> {
    return invoke<DownloadTask>("redownload", { id });
  },

  listHistory(query?: string, limit?: number, offset?: number): Promise<DownloadTask[]> {
    return invoke<DownloadTask[]>("list_history", { query, limit, offset });
  },

  getTaskLogs(id: string, limit?: number): Promise<string[]> {
    return invoke<string[]>("get_task_logs", { id, limit });
  },

  openDownloadFile(id: string): Promise<void> {
    return invoke<void>("open_download_file", { id });
  },

  revealDownloadInFinder(id: string): Promise<void> {
    return invoke<void>("reveal_download_in_finder", { id });
  },

  getSettings(): Promise<AppSettings> {
    return invoke<AppSettings>("get_settings");
  },

  updateSettings(patch: SettingsPatch): Promise<AppSettings> {
    return invoke<AppSettings>("update_settings", { patch });
  },

  getEngineStatus(): Promise<EngineStatus> {
    return invoke<EngineStatus>("get_engine_status");
  },

  refreshEngineState(): Promise<EngineStatus> {
    return invoke<EngineStatus>("refresh_engine_state");
  },

  revealLicenses(): Promise<void> {
    return invoke<void>("reveal_licenses");
  },
};

/** Normalizes whatever the backend threw into a single displayable string. */
export function toErrorMessage(error: unknown): string {
  if (typeof error === "string" && error.trim()) return error;
  if (error instanceof Error && error.message.trim()) return error.message;
  if (error && typeof error === "object" && "message" in error) {
    const message = String((error as { message: unknown }).message).trim();
    if (message) return message;
  }
  return t.common.unknownError;
}
