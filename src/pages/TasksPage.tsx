import { CheckCircle2, ListChecks, RefreshCw } from "lucide-react";
import { useEffect, useState } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";

import { EmptyState, ErrorState, LoadingState, PageHeader } from "@/components/common/States";
import { TaskCard } from "@/components/tasks/TaskCard";
import { Alert } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { useAppStore } from "@/store/app";

export function TasksPage() {
  const tasks = useAppStore((state) => state.tasks);
  const loadingTasks = useAppStore((state) => state.loadingTasks);
  const loadError = useAppStore((state) => state.loadError);
  const refreshTasks = useAppStore((state) => state.refreshTasks);

  const location = useLocation();
  const navigate = useNavigate();
  const [notice, setNotice] = useState<string | null>(null);

  // 从下载页跳转过来时提示任务已创建，并清空路由 state 避免刷新重复提示
  useEffect(() => {
    const createdId = (location.state as { createdId?: string } | null)?.createdId;
    if (!createdId) return;
    setNotice("任务已加入队列，可在下方查看实时进度。");
    navigate(location.pathname, { replace: true, state: null });
  }, [location.state, location.pathname, navigate]);

  const activeTasks = tasks.filter(
    (task) =>
      task.status === "waiting" ||
      task.status === "extracting" ||
      task.status === "downloading" ||
      task.status === "merging",
  );
  const attentionTasks = tasks.filter(
    (task) => task.status === "failed" || task.status === "interrupted",
  );
  const recentTasks = tasks
    .filter((task) => task.status === "completed" || task.status === "cancelled")
    .slice(0, 4);

  const isEmpty = activeTasks.length === 0 && attentionTasks.length === 0;

  return (
    <div className="flex flex-col gap-5">
      <PageHeader
        title="任务"
        description={
          activeTasks.length > 0
            ? `${activeTasks.length} 个任务正在执行`
            : "队列空闲，可随时开始新的下载"
        }
        actions={
          <Button
            variant="ghost"
            size="sm"
            onClick={() => void refreshTasks()}
            disabled={loadingTasks}
          >
            <RefreshCw className={loadingTasks ? "animate-spin" : undefined} />
            刷新
          </Button>
        }
      />

      {notice && (
        <Alert variant="success" title="创建成功">
          <div className="flex items-center justify-between gap-3">
            <span>{notice}</span>
            <Button variant="ghost" size="sm" onClick={() => setNotice(null)}>
              知道了
            </Button>
          </div>
        </Alert>
      )}

      {loadError && (
        <ErrorState
          title="任务列表加载失败"
          message={loadError}
          action={
            <div>
              <Button variant="outline" size="sm" onClick={() => void refreshTasks()}>
                <RefreshCw />
                重新加载
              </Button>
            </div>
          }
        />
      )}

      {loadingTasks && tasks.length === 0 && <LoadingState rows={3} label="正在读取任务…" />}

      {!loadingTasks && tasks.length === 0 && !loadError && (
        <EmptyState
          icon={<ListChecks className="size-5" />}
          title="还没有下载任务"
          description="在下载页粘贴链接并选择格式，任务会出现在这里。"
          action={
            <Button asChild size="sm">
              <Link to="/">去下载</Link>
            </Button>
          }
        />
      )}

      {activeTasks.length > 0 && (
        <section className="flex flex-col gap-2">
          <h2 className="text-[12px] font-semibold uppercase tracking-wide text-muted-foreground">
            进行中
          </h2>
          {activeTasks.map((task) => (
            <TaskCard key={task.id} task={task} />
          ))}
        </section>
      )}

      {attentionTasks.length > 0 && (
        <section className="flex flex-col gap-2">
          <h2 className="text-[12px] font-semibold uppercase tracking-wide text-muted-foreground">
            需要处理
          </h2>
          {attentionTasks.map((task) => (
            <TaskCard key={task.id} task={task} />
          ))}
        </section>
      )}

      {!loadError && isEmpty && tasks.length > 0 && (
        <EmptyState
          icon={<CheckCircle2 className="size-5" />}
          title="队列已清空"
          description="所有任务都已结束，可以继续添加新的下载。"
          action={
            <Button asChild size="sm" variant="outline">
              <Link to="/">下载新视频</Link>
            </Button>
          }
        />
      )}

      {recentTasks.length > 0 && (
        <section className="flex flex-col gap-2">
          <div className="flex items-center justify-between">
            <h2 className="text-[12px] font-semibold uppercase tracking-wide text-muted-foreground">
              最近完成
            </h2>
            <Link
              to="/history"
              className="text-[11px] text-muted-foreground transition-colors hover:text-foreground"
            >
              查看全部历史
            </Link>
          </div>
          {recentTasks.map((task) => (
            <TaskCard key={task.id} task={task} compact />
          ))}
        </section>
      )}
    </div>
  );
}
