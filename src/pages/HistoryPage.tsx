import { History, RefreshCw, Search, X } from "lucide-react";
import { useEffect, useState } from "react";

import { EmptyState, ErrorState, LoadingState, PageHeader } from "@/components/common/States";
import { TaskCard } from "@/components/tasks/TaskCard";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { t } from "@/i18n";
import { api, toErrorMessage } from "@/lib/api";
import { cn } from "@/lib/format";
import { useAppStore } from "@/store/app";
import type { DownloadTask, TaskStatus } from "@/types";

const FILTERS: { value: "all" | TaskStatus; label: string }[] = [
  { value: "all", label: t.history.all },
  { value: "completed", label: t.status.completed },
  { value: "failed", label: t.status.failed },
  { value: "interrupted", label: t.status.interrupted },
  { value: "cancelled", label: t.status.cancelled },
];

const HISTORY_LIMIT = 200;

export function HistoryPage() {
  const tasks = useAppStore((state) => state.tasks);

  const [query, setQuery] = useState("");
  const [debounced, setDebounced] = useState("");
  const [filter, setFilter] = useState<"all" | TaskStatus>("all");
  const [items, setItems] = useState<DownloadTask[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(query.trim()), 250);
    return () => window.clearTimeout(timer);
  }, [query]);

  // Refetch whenever a task changes state (finished / failed / removed).
  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      setLoading(true);
      try {
        const rows = await api.listHistory(debounced || undefined, HISTORY_LIMIT, 0);
        if (!cancelled) {
          setItems(rows);
          setError(null);
        }
      } catch (err) {
        if (!cancelled) setError(toErrorMessage(err));
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    void load();
    return () => {
      cancelled = true;
    };
  }, [debounced, tasks, reloadKey]);

  const visible = filter === "all" ? items : items.filter((item) => item.status === filter);

  return (
    <div className="flex flex-col gap-5">
      <PageHeader
        title={t.history.title}
        description={t.history.description}
        actions={
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setReloadKey((key) => key + 1)}
            disabled={loading}
          >
            <RefreshCw className={loading ? "animate-spin" : undefined} />
            {t.common.refresh}
          </Button>
        }
      />

      <div className="flex flex-col gap-3">
        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t.history.searchPlaceholder}
            className="pl-9 pr-9"
            aria-label={t.history.searchLabel}
          />
          {query && (
            <button
              type="button"
              onClick={() => setQuery("")}
              aria-label={t.history.clearSearch}
              className="absolute right-2 top-1/2 -translate-y-1/2 rounded p-1 text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
            >
              <X className="size-3.5" />
            </button>
          )}
        </div>

        <div className="flex flex-wrap items-center gap-1.5">
          {FILTERS.map((item) => {
            const active = filter === item.value;
            return (
              <button
                key={item.value}
                type="button"
                onClick={() => setFilter(item.value)}
                aria-pressed={active}
                className={cn(
                  "rounded-full border px-2.5 py-1 text-meta font-medium transition-colors",
                  active
                    ? "border-primary/40 bg-primary/10 text-primary"
                    : "border-border bg-card text-muted-foreground hover:bg-accent/60",
                )}
              >
                {item.label}
              </button>
            );
          })}
          <span className="ml-auto text-meta tabular-nums text-faint">
            {t.history.count(visible.length)}
          </span>
        </div>
      </div>

      {error && (
        <ErrorState
          title={t.history.loadError}
          message={error}
          action={
            <div>
              <Button variant="outline" size="sm" onClick={() => setReloadKey((key) => key + 1)}>
                <RefreshCw />
                {t.common.retry}
              </Button>
            </div>
          }
        />
      )}

      {loading && items.length === 0 && !error && (
        <LoadingState rows={4} label={t.history.loading} />
      )}

      {!loading && !error && items.length === 0 && (
        <EmptyState
          icon={<History className="size-5" />}
          title={debounced ? t.history.empty.searchTitle : t.history.empty.title}
          description={debounced ? t.history.empty.searchDescription : t.history.empty.description}
        />
      )}

      {!error && items.length > 0 && visible.length === 0 && (
        <EmptyState title={t.history.noMatch.title} description={t.history.noMatch.description} />
      )}

      {visible.length > 0 && (
        <div className="flex flex-col gap-2">
          {visible.map((task) => (
            <TaskCard key={task.id} task={task} compact />
          ))}
        </div>
      )}
    </div>
  );
}
