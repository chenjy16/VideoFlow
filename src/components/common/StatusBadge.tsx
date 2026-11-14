import { Loader2 } from "lucide-react";

import { cn } from "@/lib/format";
import { isActive } from "@/store/app";
import type { TaskStatus } from "@/types";

const LABELS: Record<TaskStatus, string> = {
  waiting: "排队中",
  extracting: "解析中",
  downloading: "下载中",
  merging: "合并中",
  completed: "已完成",
  failed: "失败",
  cancelled: "已取消",
  interrupted: "已中断",
};

const TONES: Record<TaskStatus, string> = {
  waiting: "border-border bg-muted text-muted-foreground",
  extracting: "border-primary/25 bg-primary/10 text-primary",
  downloading: "border-primary/25 bg-primary/10 text-primary",
  merging: "border-warning/30 bg-warning/12 text-warning",
  completed: "border-success/30 bg-success/12 text-success",
  failed: "border-destructive/30 bg-destructive/10 text-destructive",
  cancelled: "border-border bg-muted text-muted-foreground",
  interrupted: "border-warning/30 bg-warning/12 text-warning",
};

/** 任务状态标签 */
export function StatusBadge({ status, className }: { status: TaskStatus; className?: string }) {
  return (
    <span
      className={cn(
        "inline-flex shrink-0 items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium leading-4",
        TONES[status],
        className,
      )}
    >
      {isActive(status) && <Loader2 className="size-3 animate-spin" />}
      {LABELS[status]}
    </span>
  );
}

export function statusLabel(status: TaskStatus): string {
  return LABELS[status];
}
