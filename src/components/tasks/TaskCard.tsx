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
import { Progress } from "@/components/ui/progress";
import { Hint } from "@/components/ui/tooltip";
import { t } from "@/i18n";
import { api, toErrorMessage } from "@/lib/api";
import { cn, formatBytes, formatDateTime, formatEta, formatSpeed, siteName } from "@/lib/format";
import { isActive, useAppStore } from "@/store/app";
import type { DownloadTask } from "@/types";

interface TaskCardProps {
  task: DownloadTask;
  /** Tighter layout for the history list */
  compact?: boolean;
}

function MetaDot() {
  return (
    <span className="text-faint" aria-hidden>
      ·
    </span>
  );
}

/** One task row: identity, live progress and the actions valid for its state. */
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
  const canRetry =
    task.status === "failed" || task.status === "cancelled" || task.status === "interrupted";

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

  // Left/right halves of the progress caption. Only the backend state decides
  // which line is shown — the UI never infers a state from timings or counts.
  const progressLeft =
    task.status === "waiting"
      ? t.tasks.card.waiting
      : task.status === "extracting"
        ? t.tasks.card.preparing
        : task.status === "merging"
          ? t.tasks.card.merging
          : `${formatBytes(downloadedBytes)} / ${formatBytes(totalBytes)}`;

  const progressRight = [
    task.status === "downloading" ? formatSpeed(speed) : null,
    task.status === "downloading" && percent > 0 ? `${percent.toFixed(0)}%` : null,
    task.status === "downloading" && eta ? t.tasks.card.eta(formatEta(eta)) : null,
  ]
    .filter(Boolean)
    .join(" · ");

  const site = siteName(task.site);

  return (
    <div
      className={cn(
        "flex flex-col gap-2.5 rounded-lg border bg-card p-3 transition-colors",
        active ? "border-primary/30" : "border-border",
      )}
    >
      <div className="flex items-start gap-3">
        <div
          className={cn(
            "relative shrink-0 overflow-hidden rounded-md bg-muted",
            compact ? "h-9 w-16" : "h-[54px] w-24",
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
            <div className="flex size-full items-center justify-center text-caption text-faint">
              {t.tasks.card.noThumbnail}
            </div>
          )}
        </div>

        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <div className="flex items-start gap-2">
            <p
              className="line-clamp-1 min-w-0 flex-1 text-card-title font-medium"
              title={task.title}
            >
              {task.title}
            </p>
            <StatusBadge status={task.status} />
          </div>

          <div className="flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-0.5 text-meta text-muted-foreground">
            <span className="truncate">{site ?? t.common.unknownSite}</span>
            {task.formatLabel && (
              <>
                <MetaDot />
                <span className="truncate">{task.formatLabel}</span>
              </>
            )}
            {task.container && (
              <>
                <MetaDot />
                <span>{task.container.toUpperCase()}</span>
              </>
            )}
            <MetaDot />
            <span className="tabular-nums">{formatDateTime(task.createdAt)}</span>
          </div>

          {active && (
            <div className="mt-1 flex flex-col gap-1.5">
              <Progress
                value={percent}
                indeterminate={
                  task.status === "merging" || (!progress && task.status !== "waiting")
                }
              />
              <div className="flex items-baseline justify-between gap-3 text-meta tabular-nums text-muted-foreground">
                <span className="truncate">{progressLeft}</span>
                {progressRight && <span className="shrink-0">{progressRight}</span>}
              </div>
            </div>
          )}

          {!active && task.status === "completed" && (
            <p className="truncate text-meta text-muted-foreground" title={task.outputPath ?? ""}>
              {formatBytes(task.totalBytes ?? task.downloadedBytes)}
              <MetaDot /> {task.outputPath ?? t.tasks.card.fileReady}
            </p>
          )}

          {(task.status === "failed" || task.status === "interrupted") && task.errorMessage && (
            <p
              className={cn(
                "line-clamp-2 rounded bg-destructive/8 px-1.5 py-1 text-meta",
                task.status === "interrupted" ? "text-warning" : "text-destructive",
              )}
              title={task.errorMessage}
            >
              {task.errorMessage}
            </p>
          )}

          {error && (
            <p className="rounded bg-destructive/8 px-1.5 py-1 text-meta text-destructive">
              {error}
            </p>
          )}
        </div>
      </div>

      <div className="flex items-center justify-end gap-2">
        {active && (
          <Button
            variant="outline"
            size="sm"
            disabled={busy}
            onClick={() => run(() => cancelTask(task.id))}
          >
            {busy ? <Loader2 className="animate-spin" /> : <Square />}
            {t.tasks.card.actions.cancel}
          </Button>
        )}

        {canRetry && (
          <Button
            variant="secondary"
            size="sm"
            disabled={busy}
            onClick={() => run(() => retryTask(task.id))}
          >
            {busy ? <Loader2 className="animate-spin" /> : <RotateCw />}
            {t.tasks.card.actions.retry}
          </Button>
        )}

        {canOpen && (
          <>
            <Button variant="secondary" size="sm" onClick={openFile}>
              <Play />
              {t.tasks.card.actions.open}
            </Button>
            <Hint label={t.tasks.card.actions.reveal}>
              <Button
                variant="ghost"
                size="icon"
                onClick={revealFile}
                aria-label={t.tasks.card.actions.reveal}
              >
                <FolderOpen />
              </Button>
            </Hint>
          </>
        )}

        {!active && (
          <Hint label={t.tasks.card.actions.downloadAgain}>
            <Button
              variant="ghost"
              size="icon"
              disabled={busy}
              onClick={() => run(() => redownloadTask(task.id))}
              aria-label={t.tasks.card.actions.downloadAgain}
            >
              <RotateCw />
            </Button>
          </Hint>
        )}

        {!active && (
          <Hint label={t.tasks.card.actions.remove}>
            <Button
              variant="ghost"
              size="icon"
              disabled={busy}
              onClick={() => setConfirming(true)}
              aria-label={t.tasks.card.actions.remove}
            >
              <Trash2 />
            </Button>
          </Hint>
        )}
      </div>

      <Dialog open={confirming} onOpenChange={setConfirming}>
        <DialogContent className="w-[min(440px,calc(100vw-48px))]">
          <DialogHeader>
            <DialogTitle>{t.tasks.card.removeDialog.title}</DialogTitle>
            <DialogDescription>{t.tasks.card.removeDialog.description}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="ghost" size="sm" onClick={() => setConfirming(false)}>
              {t.common.cancel}
            </Button>
            <Button variant="destructive" size="sm" disabled={busy} onClick={remove}>
              {busy ? <Loader2 className="animate-spin" /> : <Trash2 />}
              {t.tasks.card.removeDialog.confirm}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
