import { cn } from "@/lib/format";

interface ProgressProps {
  value: number;
  className?: string;
  indeterminate?: boolean;
}

/** 进度条：clamp 到 0-100，未知总量时展示流动条纹 */
export function Progress({ value, className, indeterminate = false }: ProgressProps) {
  const clamped = Math.max(0, Math.min(100, Number.isFinite(value) ? value : 0));

  return (
    <div
      className={cn("relative h-1.5 w-full overflow-hidden rounded-full bg-muted", className)}
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={indeterminate ? undefined : Math.round(clamped)}
    >
      <div
        className={cn(
          "h-full rounded-full bg-primary transition-[width] duration-300 ease-out",
          indeterminate && "animate-pulse",
        )}
        style={{ width: indeterminate ? "35%" : `${clamped}%` }}
      />
    </div>
  );
}
