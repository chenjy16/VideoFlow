import { FolderOpen, Loader2, Play, RotateCw, Square, Trash2 } from "lucide-react";
import { useState } from "react";

import { StatusBadge } from "@/components/common/StatusBadge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Hint } from "@/components/ui/tooltip";
import { Progress } from "@/components/ui/progress";
import { api, toErrorMessage } from "@/lib/api";
import { cn, formatBytes, formatDateTime, formatEta, formatSpeed, prettySite } from "@/lib/format";
import { isActive, useAppStore } from "@/store/app";
import type { DownloadTask } from "@/types";

interface TaskCardProps {
  task: DownloadTask;
  /** 历史页使用更紧凑的布局 */
  compact?: boolean;
}

/** 单个任务卡片：状态、进度与操作 */
export function TaskCard({ task, compact = false }: TaskCardProps) {
  const progress = useAppStore((state) => state.progress[task.id]);
  const busy = useAppStore((state) => state.busy[task.id]);
  const cancelTask = useAppStore((state) => state.cancelTask);
  const retryTask = useAppStore((state) => state.retryTask);
  const removeTask = useAppStore((state) => state.removeTask);
  const redownloadTask = useAppStore((state) => state.redownloadTask);

  const [error, setError] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);

  const active = isActive(task.status);
  const canOpen = task.status === "completed" && Boolean(task.outputPath);
  const percent = progress?.percent ?? 0;
  const totalBytes = progress?.totalBytes ?? task.totalBytes;
  const downloadedBytes = progress?.downloadedBytes ?? task.downloadedBytes;
  const speed = progress?.speed ?? task.speed;
  const eta = progress?.eta ?? task.eta;

  const run = async (action: () => Promise<unknown>) => {
    setError(null);
    try {
      await action();
    } catch (err) {
      setError(toErrorMessage(err));
    }
  };

  const openFile = () =>
    run(async () => {
      await api.openDownloadFile(task.id);
    });

  const revealFile = () =>
    run(async () => {
      await api.revealDownloadInFinder(task.id);
    });

  const remove = () =>
    run(async () => {
      await removeTask(task.id);
      setConfirming(false);
    });

  return (
    <div
      className={cn(
        "flex flex-col gap-2 rounded-xl border border-border bg-card px-3 py-2.5 transition-colors",
        active && "border-primary/25",
      )}
    >
      <div className="flex items-start gap-3">
        <div
          className={cn(
            "relative aspect-video shrink-0 overflow-hidden rounded-md bg-muted",
            compact ? "w-[60px]" : "w-[76px]",
          )}
        >
          {task.thumbnail ? (
            <img
              src={task.thumbnail}
              alt=""
              className="size-full object-cover"
              loading="lazy"
              referrerPolicy="no-referrer"
            />
          ) : (
            <div className="flex size-full items-center justify-center text-[10px] text-muted-foreground">
              无封面
            </div>
          )}
        </div>

        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <div className="flex items-start gap-2">
            <p
              className="line-clamp-1 flex-1 text-[13px] font-medium leading-snug"
              title={task.title}
            >
              {task.title}
            </p>
            <StatusBadge status={task.status} />
          </div>

          <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px] text-muted-foreground">
            <span>{prettySite(task.site)}</span>
            {task.formatLabel && <span className="truncate">· {task.formatLabel}</span>}
            {task.container && <span>· {task.container.toUpperCase()}</span>}
            <span>· {formatDateTime(task.createdAt)}</span>
          </div>

          {active && (
            <div className="mt-0.5 flex flex-col gap-1">
              <Progress
                value={percent}
                indeterminate={
                  task.status === "merging" || (!progress && task.status !== "waiting")
                }
              />
              <div className="flex items-center justify-between gap-2 text-[11px] tabular-nums text-muted-foreground">
                <span className="truncate">
                  {task.status === "waiting" && "等待下载"}
                  {task.status === "extracting" && "正在解析链接…"}
                  {task.status === "merging" && "正在合并音视频…"}
                  {task.status === "downloading" &&
                    `${formatBytes(downloadedBytes)} / ${formatBytes(totalBytes)}`}
                </span>
                <span className="shrink-0">
                  {task.status === "downloading" && (
                    <>
                      {formatSpeed(speed)} {percent > 0 && `· ${percent.toFixed(0)}%`}
                      {eta ? ` · 剩余 ${formatEta(eta)}` : ""}
                    </>
                  )}
                </span>
              </div>
            </div>
          )}

          {!active && task.status === "completed" && (
            <p className="truncate text-[11px] text-muted-foreground" title={task.outputPath ?? ""}>
              {formatBytes(task.totalBytes ?? task.downloadedBytes)} ·{" "}
              {task.outputPath ?? "文件已就绪"}
            </p>
          )}

          {(task.status === "failed" || task.status === "interrupted") && task.errorMessage && (
            <p
              className={cn(
                "line-clamp-2 rounded bg-destructive/8 px-1.5 py-1 text-[11px] leading-snug",
                task.status === "interrupted" ? "text-warning" : "text-destructive",
              )}
              title={task.errorMessage}
            >
              {task.errorMessage}
            </p>
          )}

          {error && (
            <p className="rounded bg-destructive/8 px-1.5 py-1 text-[11px] leading-snug text-destructive">
              {error}
            </p>
          )}
        </div>
      </div>

      <div className={cn("flex items-center justify-end gap-1.5", compact && "-mt-0.5")}>
        {active && (
          <Button
            variant="outline"
            size="sm"
            disabled={busy}
            onClick={() => run(() => cancelTask(task.id))}
          >
            {busy ? <Loader2 className="animate-spin" /> : <Square />}
            取消
          </Button>
        )}

        {(task.status === "failed" ||
          task.status === "cancelled" ||
          task.status === "interrupted") && (
          <Button
            variant="secondary"
            size="sm"
            disabled={busy}
            onClick={() => run(() => retryTask(task.id))}
          >
            {busy ? <Loader2 className="animate-spin" /> : <RotateCw />}
            重试
          </Button>
        )}

        {canOpen && (
          <>
            <Button variant="secondary" size="sm" onClick={openFile}>
              <Play />
              打开文件
            </Button>
            <Hint label="在 Finder 中显示">
              <Button
                variant="ghost"
                size="icon"
                onClick={revealFile}
                aria-label="在 Finder 中显示"
              >
                <FolderOpen />
              </Button>
            </Hint>
          </>
        )}

        {!active && (
          <Hint label="重新下载">
            <Button
              variant="ghost"
              size="icon"
              disabled={busy}
              onClick={() => run(() => redownloadTask(task.id))}
              aria-label="重新下载"
            >
              <RotateCw />
            </Button>
          </Hint>
        )}

        {!active && (
          <Hint label="移除记录（不会删除文件）">
            <Button
              variant="ghost"
              size="icon"
              disabled={busy}
              onClick={() => setConfirming(true)}
              aria-label="移除记录"
            >
              <Trash2 />
            </Button>
          </Hint>
        )}
      </div>

      <Dialog open={confirming} onOpenChange={setConfirming}>
        <DialogContent className="w-[min(440px,calc(100vw-48px))]">
          <DialogHeader>
            <DialogTitle>移除下载记录？</DialogTitle>
            <DialogDescription>
              仅从列表中移除该记录，已下载的文件会保留在原位置。此操作不可撤销。
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="ghost" size="sm" onClick={() => setConfirming(false)}>
              取消
            </Button>
            <Button variant="destructive" size="sm" disabled={busy} onClick={remove}>
              {busy ? <Loader2 className="animate-spin" /> : <Trash2 />}
              移除记录
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
