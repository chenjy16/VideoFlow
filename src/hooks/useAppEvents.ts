import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { useEffect } from "react";

import { isTauri } from "@/lib/env";
import { useAppStore } from "@/store/app";
import type { DownloadTask, TaskProgress } from "@/types";

/**
 * 订阅后端任务事件。
 * 后端通过 `task:updated` / `task:progress` / `task:removed` 推送状态，
 * 前端只在事件到达时增量合并，不轮询数据库。
 */
export function useAppEvents() {
  useEffect(() => {
    if (!isTauri()) return;

    const { applyTask, applyProgress, dropTask } = useAppStore.getState();
    let disposed = false;
    const unlisteners: UnlistenFn[] = [];

    const register = async () => {
      const listeners = await Promise.all([
        listen<DownloadTask>("task:updated", (event) => applyTask(event.payload)),
        listen<TaskProgress>("task:progress", (event) => applyProgress(event.payload)),
        listen<string>("task:removed", (event) => dropTask(event.payload)),
      ]);
      if (disposed) {
        listeners.forEach((unlisten) => unlisten());
      } else {
        unlisteners.push(...listeners);
      }
    };

    register().catch((error) => {
      console.error("Couldn't subscribe to task events", error);
    });

    return () => {
      disposed = true;
      unlisteners.forEach((unlisten) => unlisten());
    };
  }, []);
}
