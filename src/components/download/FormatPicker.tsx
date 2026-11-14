import { Check, Sparkles } from "lucide-react";

import { cn, formatBytes } from "@/lib/format";
import type { DownloadOption, OptionCategory } from "@/types";

const GROUPS: { category: OptionCategory; title: string; hint?: string }[] = [
  { category: "best", title: "推荐", hint: "自动选择最佳画面与音轨" },
  { category: "video", title: "视频", hint: "含音轨，可直接播放" },
  { category: "video_only", title: "仅视频", hint: "无声音，适合二次剪辑" },
  { category: "audio_only", title: "仅音频", hint: "提取为音频文件" },
];

interface FormatPickerProps {
  options: DownloadOption[];
  value: string | null;
  onChange: (option: DownloadOption) => void;
  disabled?: boolean;
}

/** 格式选择器：按类别分组展示真实可用的格式 */
export function FormatPicker({ options, value, onChange, disabled = false }: FormatPickerProps) {
  return (
    <div className="flex flex-col gap-4">
      {GROUPS.map((group) => {
        const items = options.filter((option) => option.category === group.category);
        if (items.length === 0) return null;

        return (
          <section key={group.category} className="flex flex-col gap-1.5">
            <div className="flex items-baseline gap-2">
              <h3 className="text-[12px] font-semibold uppercase tracking-wide text-muted-foreground">
                {group.title}
              </h3>
              {group.hint && (
                <span className="text-[11px] text-muted-foreground/70">{group.hint}</span>
              )}
            </div>
            <div className="flex flex-col gap-1">
              {items.map((option) => {
                const selected = option.id === value;
                return (
                  <button
                    key={option.id}
                    type="button"
                    disabled={disabled}
                    onClick={() => onChange(option)}
                    aria-pressed={selected}
                    className={cn(
                      "group flex w-full items-center gap-3 rounded-lg border px-3 py-2 text-left transition-colors",
                      selected
                        ? "border-primary/60 bg-primary/[0.07] ring-1 ring-primary/30"
                        : "border-border bg-card hover:border-border hover:bg-accent/50",
                      disabled && "cursor-not-allowed opacity-60",
                    )}
                  >
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-1.5">
                        <span className="truncate text-[13px] font-medium">{option.label}</span>
                        {option.category === "best" && (
                          <Sparkles className="size-3 shrink-0 text-primary" />
                        )}
                        {option.requiresMerge && (
                          <span className="shrink-0 rounded bg-muted px-1 py-px text-[10px] text-muted-foreground">
                            需合并
                          </span>
                        )}
                      </div>
                      <p className="mt-0.5 truncate text-[11px] text-muted-foreground">
                        {option.description ?? option.container.toUpperCase()}
                      </p>
                    </div>
                    <span className="shrink-0 text-[11px] tabular-nums text-muted-foreground">
                      {formatBytes(option.estimatedBytes)}
                    </span>
                    <span
                      className={cn(
                        "flex size-4 shrink-0 items-center justify-center rounded-full border transition-colors",
                        selected
                          ? "border-primary bg-primary text-primary-foreground"
                          : "border-border text-transparent group-hover:border-muted-foreground/50",
                      )}
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
