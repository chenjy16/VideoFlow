import { AlertCircle, CheckCircle2, Info, TriangleAlert } from "lucide-react";
import * as React from "react";

import { cn } from "@/lib/format";

type AlertVariant = "error" | "success" | "warning" | "info";

const ICONS: Record<AlertVariant, React.ComponentType<{ className?: string }>> = {
  error: AlertCircle,
  success: CheckCircle2,
  warning: TriangleAlert,
  info: Info,
};

const TONES: Record<AlertVariant, string> = {
  error: "border-destructive/30 bg-destructive/8 text-destructive",
  success: "border-success/30 bg-success/10 text-success",
  warning: "border-warning/35 bg-warning/12 text-warning",
  info: "border-border bg-muted text-muted-foreground",
};

interface AlertProps extends React.HTMLAttributes<HTMLDivElement> {
  variant?: AlertVariant;
  title?: string;
  /** Long engine errors are shown in a scrollable block */
  scrollable?: boolean;
}

/** Inline banner: error / success / warning / info */
export function Alert({
  variant = "info",
  title,
  scrollable = false,
  className,
  children,
  ...props
}: AlertProps) {
  const Icon = ICONS[variant];

  return (
    <div
      role="alert"
      className={cn(
        "flex items-start gap-2.5 rounded-lg border px-3 py-2.5 text-body",
        TONES[variant],
        className,
      )}
      {...props}
    >
      <Icon className="mt-0.5 size-4 shrink-0" />
      <div className="min-w-0 flex-1">
        {title && <p className="font-medium leading-snug">{title}</p>}
        {children && (
          <div
            className={cn(
              "leading-relaxed break-words",
              title && "mt-0.5",
              scrollable && "max-h-40 overflow-auto whitespace-pre-wrap font-mono text-meta",
            )}
          >
            {children}
          </div>
        )}
      </div>
    </div>
  );
}
