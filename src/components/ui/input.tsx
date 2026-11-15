import * as React from "react";

import { cn } from "@/lib/format";

const Input = React.forwardRef<HTMLInputElement, React.ComponentProps<"input">>(
  ({ className, type, ...props }, ref) => (
    <input
      type={type}
      ref={ref}
      className={cn(
        "flex h-[var(--control-height)] w-full rounded-md border border-input bg-card px-3 py-1 text-body shadow-sm transition-colors",
        "placeholder:text-muted-foreground/80",
        "focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/30 focus-visible:outline-none",
        "disabled:cursor-not-allowed disabled:opacity-50",
        className,
      )}
      {...props}
    />
  ),
);
Input.displayName = "Input";

export { Input };
