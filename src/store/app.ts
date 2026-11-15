import { create } from "zustand";

import { api, toErrorMessage } from "@/lib/api";
import type { AppSettings, DownloadTask, EngineStatus, TaskProgress, TaskStatus } from "@/types";

/** 仍在排队或执行中的状态 */
const ACTIVE_STATUSES: TaskStatus[] = ["waiting", "extracting", "downloading", "merging"];

/**
 * 状态推进顺序。命令返回值可能比事件更旧：任务入库后调度器会立即把它推进到
 * extracting 并广播事件，而创建命令的返回值仍是 waiting。用这个顺序丢掉迟到的
 * 旧快照，避免把已经在跑的任务写回排队中。
 */
const STATUS_RANK: Record<TaskStatus, number> = {
  waiting: 0,
  extracting: 1,
  downloading: 2,
  merging: 3,
  completed: 4,
  failed: 4,
  cancelled: 4,
  interrupted: 4,
};

/** 终态：不会再自行变化，只有重试会把它重新排队。 */
const TERMINAL_RANK = 4;

/** 判断一份快照是否比已知状态更新；陈旧的命令返回值会在这里被丢掉。 */
function canApply(current: TaskStatus | undefined, incoming: TaskStatus): boolean {
  if (!current) return true;
  if (STATUS_RANK[incoming] >= STATUS_RANK[current]) return true;
  // 唯一的回退：终态任务重新排队（重试）
  return incoming === "waiting" && STATUS_RANK[current] === TERMINAL_RANK;
}

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
      const current = state.tasks.find((item) => item.id === task.id);
      if (!canApply(current?.status, task.status)) return state;
      const exists = Boolean(current);
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
      // 进度事件携带后端最新阶段（extracting/downloading/merging），
      // 一并修正任务状态，卡片标签才不会停留在排队中；阶段同样只向前推进。
      const status =
        STATUS_RANK[incoming.status] >= STATUS_RANK[task.status] ? incoming.status : task.status;
      const tasks =
        status === task.status
          ? state.tasks
          : state.tasks.map((item) => (item.id === task.id ? { ...item, status } : item));
      return { tasks, progress: { ...state.progress, [incoming.id]: incoming } };
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
