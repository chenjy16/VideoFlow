import { create } from "zustand";

import { api, toErrorMessage } from "@/lib/api";
import type { AppSettings, DownloadTask, EngineStatus, TaskProgress, TaskStatus } from "@/types";

/** 仍在排队或执行中的状态 */
const ACTIVE_STATUSES: TaskStatus[] = ["waiting", "extracting", "downloading", "merging"];

export function isActive(status: TaskStatus): boolean {
  return ACTIVE_STATUSES.includes(status);
}

/** 需要用户介入的状态 */
export function needsAttention(status: TaskStatus): boolean {
  return status === "interrupted" || status === "failed";
}

function sortTasks(tasks: DownloadTask[]): DownloadTask[] {
  const weight = (status: TaskStatus) => (isActive(status) ? 0 : needsAttention(status) ? 1 : 2);
  return [...tasks].sort((a, b) => {
    const diff = weight(a.status) - weight(b.status);
    if (diff !== 0) return diff;
    return new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime();
  });
}

interface AppStore {
  tasks: DownloadTask[];
  /** 任务 id -> 最新进度（仅运行中的任务会产生） */
  progress: Record<string, TaskProgress>;
  /** 正在执行命令的任务，用于禁用按钮 */
  busy: Record<string, boolean>;
  settings: AppSettings | null;
  engine: EngineStatus | null;

  bootstrapped: boolean;
  loadingTasks: boolean;
  loadError: string | null;

  bootstrap: () => Promise<void>;
  refreshTasks: () => Promise<void>;
  refreshEngine: () => Promise<void>;

  applyTask: (task: DownloadTask) => void;
  applyProgress: (progress: TaskProgress) => void;
  dropTask: (id: string) => void;

  setSettings: (settings: AppSettings) => void;

  cancelTask: (id: string) => Promise<void>;
  retryTask: (id: string) => Promise<void>;
  removeTask: (id: string) => Promise<void>;
  redownloadTask: (id: string) => Promise<DownloadTask>;
}

export const useAppStore = create<AppStore>((set, get) => ({
  tasks: [],
  progress: {},
  busy: {},
  settings: null,
  engine: null,

  bootstrapped: false,
  loadingTasks: false,
  loadError: null,

  async bootstrap() {
    if (get().loadingTasks) return;
    set({ loadingTasks: true, loadError: null });
    try {
      const [tasks, settings, engine] = await Promise.all([
        api.listTasks(),
        api.getSettings(),
        api.getEngineStatus(),
      ]);
      set({
        tasks: sortTasks(tasks),
        settings,
        engine,
        bootstrapped: true,
        loadingTasks: false,
      });
    } catch (error) {
      set({
        loadError: toErrorMessage(error),
        bootstrapped: true,
        loadingTasks: false,
      });
    }
  },

  async refreshTasks() {
    set({ loadingTasks: true });
    try {
      const tasks = await api.listTasks();
      set({ tasks: sortTasks(tasks), loadError: null });
    } catch (error) {
      set({ loadError: toErrorMessage(error) });
    } finally {
      set({ loadingTasks: false });
    }
  },

  async refreshEngine() {
    try {
      set({ engine: await api.refreshEngineState() });
    } catch (error) {
      set({ loadError: toErrorMessage(error) });
    }
  },

  applyTask(task) {
    set((state) => {
      const exists = state.tasks.some((item) => item.id === task.id);
      const tasks = exists
        ? state.tasks.map((item) => (item.id === task.id ? task : item))
        : [...state.tasks, task];
      const progress = { ...state.progress };
      if (!isActive(task.status)) {
        delete progress[task.id];
      }
      return { tasks: sortTasks(tasks), progress };
    });
  },

  applyProgress(incoming) {
    set((state) => {
      const task = state.tasks.find((item) => item.id === incoming.id);
      // 任务已被移除或进入终态时，丢弃迟到的进度事件
      if (!task || !isActive(task.status)) return state;
      return { progress: { ...state.progress, [incoming.id]: incoming } };
    });
  },

  dropTask(id) {
    set((state) => {
      const progress = { ...state.progress };
      delete progress[id];
      return {
        tasks: state.tasks.filter((task) => task.id !== id),
        progress,
      };
    });
  },

  setSettings(settings) {
    set({ settings });
  },

  async cancelTask(id) {
    set((state) => ({ busy: { ...state.busy, [id]: true } }));
    try {
      get().applyTask(await api.cancelDownload(id));
    } finally {
      set((state) => ({ busy: { ...state.busy, [id]: false } }));
    }
  },

  async retryTask(id) {
    set((state) => ({ busy: { ...state.busy, [id]: true } }));
    try {
      get().applyTask(await api.retryDownload(id));
    } finally {
      set((state) => ({ busy: { ...state.busy, [id]: false } }));
    }
  },

  async removeTask(id) {
    set((state) => ({ busy: { ...state.busy, [id]: true } }));
    try {
      await api.removeDownload(id);
      get().dropTask(id);
    } finally {
      set((state) => ({ busy: { ...state.busy, [id]: false } }));
    }
  },

  async redownloadTask(id) {
    const task = await api.redownload(id);
    get().applyTask(task);
    return task;
  },
}));
