import { AlertCircle, Inbox } from "lucide-react";
import * as React from "react";

import { Alert } from "@/components/ui/alert";
import { SkeletonList } from "@/components/ui/skeleton";
import { t } from "@/i18n";
import { cn } from "@/lib/format";

/** Page-level heading, used identically on all four pages. */
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
        <h1 className="text-page-title font-semibold tracking-tight">{title}</h1>
        {description && <p className="mt-1 text-body text-muted-foreground">{description}</p>}
      </div>
      {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
    </div>
  );
}

/** Section label above a group of cards. */
export function SectionLabel({
  children,
  className,
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <h2
      className={cn(
        "text-section font-semibold uppercase tracking-wide text-muted-foreground",
        className,
      )}
    >
      {children}
    </h2>
  );
}

/** Empty placeholder for a page or a list. */
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
        "flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border px-6 py-12 text-center",
        className,
      )}
    >
      <div className="mb-1 flex size-10 items-center justify-center rounded-full bg-muted text-muted-foreground">
        {icon ?? <Inbox className="size-5" />}
      </div>
      <p className="text-body font-medium">{title}</p>
      {description && <p className="max-w-sm text-meta text-muted-foreground">{description}</p>}
      {action && <div className="mt-2">{action}</div>}
    </div>
  );
}

/** Error block with an optional recovery action. */
export function ErrorState({
  title,
  message,
  action,
}: {
  title: string;
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

/** Loading placeholder. */
export function LoadingState({ rows = 3, label }: { rows?: number; label?: string }) {
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-2 text-body text-muted-foreground">
        <AlertCircle className="size-3.5" aria-hidden />
        <span>{label ?? t.common.loading}</span>
      </div>
      <SkeletonList rows={rows} />
    </div>
  );
}
