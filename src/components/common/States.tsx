import { AlertCircle, Inbox } from "lucide-react";
import * as React from "react";

import { Alert } from "@/components/ui/alert";
import { SkeletonList } from "@/components/ui/skeleton";
import { cn } from "@/lib/format";

/** 页面级标题 */
export function PageHeader({
  title,
  description,
  actions,
  className,
}: {
  title: string;
  description?: string;
  actions?: React.ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("flex items-start justify-between gap-4", className)}>
      <div className="min-w-0">
        <h1 className="text-[20px] font-semibold tracking-tight">{title}</h1>
        {description && (
          <p className="mt-1 text-[13px] leading-relaxed text-muted-foreground">{description}</p>
        )}
      </div>
      {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
    </div>
  );
}

/** 空状态 */
export function EmptyState({
  title,
  description,
  icon,
  action,
  className,
}: {
  title: string;
  description?: string;
  icon?: React.ReactNode;
  action?: React.ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-col items-center justify-center gap-2 rounded-xl border border-dashed border-border px-6 py-14 text-center",
        className,
      )}
    >
      <div className="mb-1 flex size-11 items-center justify-center rounded-full bg-muted text-muted-foreground">
        {icon ?? <Inbox className="size-5" />}
      </div>
      <p className="text-sm font-medium">{title}</p>
      {description && (
        <p className="max-w-sm text-[13px] leading-relaxed text-muted-foreground">{description}</p>
      )}
      {action && <div className="mt-2">{action}</div>}
    </div>
  );
}

/** 错误状态 */
export function ErrorState({
  title = "加载失败",
  message,
  action,
}: {
  title?: string;
  message: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col gap-3">
      <Alert variant="error" title={title} scrollable={message.length > 160}>
        {message}
      </Alert>
      {action}
    </div>
  );
}

/** 加载状态 */
export function LoadingState({ rows = 3, label }: { rows?: number; label?: string }) {
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-2 text-[13px] text-muted-foreground">
        <AlertCircle className="size-3.5" />
        <span>{label ?? "正在加载…"}</span>
      </div>
      <SkeletonList rows={rows} />
    </div>
  );
}
