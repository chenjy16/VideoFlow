import { invoke } from "@tauri-apps/api/core";

import type {
  AppSettings,
  CreateDownloadRequest,
  DownloadTask,
  EngineStatus,
  MediaInfo,
  SettingsPatch,
} from "@/types";

/**
 * 所有后端调用集中在此，UI 只依赖这些函数，
 * 便于后续替换传输层或做 mock 测试。
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
};

/** 把后端返回的错误统一转换成可展示文案 */
export function toErrorMessage(error: unknown): string {
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object" && "message" in error) {
    return String((error as { message: unknown }).message);
  }
  return "发生未知错误";
}
