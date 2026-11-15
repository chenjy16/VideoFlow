import { Check, Sparkles } from "lucide-react";

import { t } from "@/i18n";
import { cn, formatBytes } from "@/lib/format";
import type { DownloadOption, OptionCategory } from "@/types";

const GROUPS: { category: OptionCategory; title: string; hint?: string }[] = [
  {
    category: "best",
    title: t.download.formats.recommended,
    hint: t.download.formats.recommendedHint,
  },
  { category: "video", title: t.download.formats.video, hint: t.download.formats.videoHint },
  {
    category: "video_only",
    title: t.download.formats.videoOnly,
    hint: t.download.formats.videoOnlyHint,
  },
  {
    category: "audio_only",
    title: t.download.formats.audioOnly,
    hint: t.download.formats.audioOnlyHint,
  },
];

interface FormatPickerProps {
  options: DownloadOption[];
  value: string | null;
  onChange: (option: DownloadOption) => void;
  disabled?: boolean;
}

/** Formats this video actually offers, grouped by kind. */
export function FormatPicker({ options, value, onChange, disabled = false }: FormatPickerProps) {
  return (
    <div className="flex flex-col gap-5">
      {GROUPS.map((group) => {
        const items = options.filter((option) => option.category === group.category);
        if (items.length === 0) return null;

        return (
          <section key={group.category} className="flex flex-col gap-2">
            <div className="flex items-baseline gap-2">
              <h3 className="text-section font-semibold uppercase tracking-wide text-muted-foreground">
                {group.title}
              </h3>
              {group.hint && <span className="text-meta text-faint">{group.hint}</span>}
            </div>
            <div role="radiogroup" aria-label={group.title} className="flex flex-col gap-1">
              {items.map((option) => {
                const selected = option.id === value;
                return (
                  <button
                    key={option.id}
                    type="button"
                    role="radio"
                    aria-checked={selected}
                    disabled={disabled}
                    onClick={() => onChange(option)}
                    className={cn(
                      "group flex w-full items-center gap-3 rounded-md border px-3 py-2 text-left transition-colors",
                      "outline-none focus-visible:ring-2 focus-visible:ring-ring/60",
                      selected
                        ? "border-primary/50 bg-primary/[0.06]"
                        : "border-border bg-card hover:border-border hover:bg-accent/50",
                      disabled && "cursor-not-allowed opacity-60",
                    )}
                  >
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-1.5">
                        <span className="truncate text-body font-medium">{option.label}</span>
                        {option.category === "best" && (
                          <Sparkles className="size-3 shrink-0 text-primary" aria-hidden />
                        )}
                        {option.requiresMerge && (
                          <span className="shrink-0 rounded bg-muted px-1 py-px text-caption text-muted-foreground">
                            {t.download.formats.mergeBadge}
                          </span>
                        )}
                      </div>
                      <p className="mt-0.5 truncate text-meta text-muted-foreground">
                        {option.description ?? option.container.toUpperCase()}
                      </p>
                    </div>
                    <span className="shrink-0 text-meta tabular-nums text-muted-foreground">
                      {formatBytes(option.estimatedBytes)}
                    </span>
                    <span
                      className={cn(
                        "flex size-4 shrink-0 items-center justify-center rounded-full border transition-colors",
                        selected
                          ? "border-primary bg-primary text-primary-foreground"
                          : "border-border text-transparent group-hover:border-muted-foreground/50",
                      )}
                      aria-hidden
                    >
                      <Check className="size-2.5" strokeWidth={3} />
                    </span>
                  </button>
                );
              })}
            </div>
          </section>
        );
      })}
    </div>
  );
}
