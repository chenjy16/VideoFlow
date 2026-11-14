import { History, RefreshCw, Search, X } from "lucide-react";
import { useEffect, useState } from "react";

import { EmptyState, ErrorState, LoadingState, PageHeader } from "@/components/common/States";
import { TaskCard } from "@/components/tasks/TaskCard";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { api, toErrorMessage } from "@/lib/api";
import { cn } from "@/lib/format";
import { useAppStore } from "@/store/app";
import type { DownloadTask, TaskStatus } from "@/types";

const FILTERS: { value: "all" | TaskStatus; label: string }[] = [
  { value: "all", label: "全部" },
  { value: "completed", label: "已完成" },
  { value: "failed", label: "失败" },
  { value: "interrupted", label: "已中断" },
  { value: "cancelled", label: "已取消" },
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

  // 任务状态变化（完成 / 失败 / 删除）后重新拉取历史
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
        title="历史"
        description="已结束的下载记录。移除记录不会删除已下载的文件。"
        actions={
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setReloadKey((key) => key + 1)}
            disabled={loading}
          >
            <RefreshCw className={loading ? "animate-spin" : undefined} />
            刷新
          </Button>
        }
      />

      <div className="flex flex-col gap-3">
        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="搜索标题或链接"
            className="pl-9 pr-9"
            aria-label="搜索历史记录"
          />
          {query && (
            <button
              type="button"
              onClick={() => setQuery("")}
              aria-label="清空搜索"
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
                className={cn(
                  "rounded-full border px-2.5 py-1 text-[11px] font-medium transition-colors",
                  active
                    ? "border-primary/40 bg-primary/10 text-primary"
                    : "border-border bg-card text-muted-foreground hover:bg-accent/60",
                )}
              >
                {item.label}
              </button>
            );
          })}
          <span className="ml-auto text-[11px] tabular-nums text-muted-foreground">
            {visible.length} 条记录
          </span>
        </div>
      </div>

      {error && (
        <ErrorState
          title="历史记录加载失败"
          message={error}
          action={
            <div>
              <Button variant="outline" size="sm" onClick={() => setReloadKey((key) => key + 1)}>
                <RefreshCw />
                重试
              </Button>
            </div>
          }
        />
      )}

      {loading && items.length === 0 && !error && (
        <LoadingState rows={4} label="正在读取历史记录…" />
      )}

      {!loading && !error && items.length === 0 && (
        <EmptyState
          icon={<History className="size-5" />}
          title={debounced ? "没有匹配的记录" : "还没有历史记录"}
          description={
            debounced
              ? "试试其他关键词，或清空搜索条件。"
              : "完成、失败或取消的下载都会自动归档到这里。"
          }
        />
      )}

      {!error && items.length > 0 && visible.length === 0 && (
        <EmptyState title="该筛选条件下没有记录" description="切换其他状态查看。" />
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
