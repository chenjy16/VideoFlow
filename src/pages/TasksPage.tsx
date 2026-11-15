import { CheckCircle2, ListChecks, RefreshCw } from "lucide-react";
import { useEffect, useState } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";

import {
  EmptyState,
  ErrorState,
  LoadingState,
  PageHeader,
  SectionLabel,
} from "@/components/common/States";
import { TaskCard } from "@/components/tasks/TaskCard";
import { Alert } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { t } from "@/i18n";
import { useAppStore } from "@/store/app";

export function TasksPage() {
  const tasks = useAppStore((state) => state.tasks);
  const loadingTasks = useAppStore((state) => state.loadingTasks);
  const loadError = useAppStore((state) => state.loadError);
  const refreshTasks = useAppStore((state) => state.refreshTasks);

  const location = useLocation();
  const navigate = useNavigate();
  const [notice, setNotice] = useState<string | null>(null);

  // A task created on the Download page navigates here once; clear the router
  // state afterwards so a re-render doesn't repeat the banner.
  useEffect(() => {
    const createdId = (location.state as { createdId?: string } | null)?.createdId;
    if (!createdId) return;
    setNotice(t.tasks.notice.body);
    navigate(location.pathname, { replace: true, state: null });
  }, [location.state, location.pathname, navigate]);

  // The summary and the sections are derived from the backend state only —
  // never from "how many tasks exist" or how long they have been around.
  const queuedTasks = tasks.filter((task) => task.status === "waiting");
  const activeTasks = tasks.filter(
    (task) =>
      task.status === "extracting" || task.status === "downloading" || task.status === "merging",
  );
  const attentionTasks = tasks.filter(
    (task) => task.status === "failed" || task.status === "interrupted",
  );
  const recentTasks = tasks
    .filter((task) => task.status === "completed" || task.status === "cancelled")
    .slice(0, 4);

  const inProgress = [...activeTasks, ...queuedTasks];
  const isEmpty = inProgress.length === 0 && attentionTasks.length === 0;

  const summary =
    activeTasks.length > 0 && queuedTasks.length > 0
      ? t.tasks.summary.activeAndQueued(activeTasks.length, queuedTasks.length)
      : activeTasks.length > 0
        ? t.tasks.summary.active(activeTasks.length)
        : queuedTasks.length > 0
          ? t.tasks.summary.queued(queuedTasks.length)
          : t.tasks.summary.idle;

  return (
    <div className="flex flex-col gap-6">
      <PageHeader
        title={t.tasks.title}
        description={summary}
        actions={
          <Button
            variant="ghost"
            size="sm"
            onClick={() => void refreshTasks()}
            disabled={loadingTasks}
          >
            <RefreshCw className={loadingTasks ? "animate-spin" : undefined} />
            {t.common.refresh}
          </Button>
        }
      />

      {notice && (
        <Alert variant="success" title={t.tasks.notice.title}>
          <div className="flex items-center justify-between gap-3">
            <span>{notice}</span>
            <Button variant="ghost" size="sm" onClick={() => setNotice(null)}>
              {t.tasks.notice.dismiss}
            </Button>
          </div>
        </Alert>
      )}

      {loadError && (
        <ErrorState
          title={t.tasks.loadError}
          message={loadError}
          action={
            <div>
              <Button variant="outline" size="sm" onClick={() => void refreshTasks()}>
                <RefreshCw />
                {t.common.reload}
              </Button>
            </div>
          }
        />
      )}

      {loadingTasks && tasks.length === 0 && <LoadingState rows={3} label={t.tasks.loading} />}

      {!loadingTasks && tasks.length === 0 && !loadError && (
        <EmptyState
          icon={<ListChecks className="size-5" />}
          title={t.tasks.empty.title}
          description={t.tasks.empty.description}
          action={
            <Button asChild size="sm">
              <Link to="/">{t.tasks.empty.action}</Link>
            </Button>
          }
        />
      )}

      {inProgress.length > 0 && (
        <section className="flex flex-col gap-2">
          <SectionLabel>{t.tasks.sections.active}</SectionLabel>
          {inProgress.map((task) => (
            <TaskCard key={task.id} task={task} />
          ))}
        </section>
      )}

      {attentionTasks.length > 0 && (
        <section className="flex flex-col gap-2">
          <SectionLabel>{t.tasks.sections.attention}</SectionLabel>
          {attentionTasks.map((task) => (
            <TaskCard key={task.id} task={task} />
          ))}
        </section>
      )}

      {!loadError && isEmpty && tasks.length > 0 && (
        <EmptyState
          icon={<CheckCircle2 className="size-5" />}
          title={t.tasks.idle.title}
          description={t.tasks.idle.description}
          action={
            <Button asChild size="sm" variant="outline">
              <Link to="/">{t.tasks.idle.action}</Link>
            </Button>
          }
        />
      )}

      {recentTasks.length > 0 && (
        <section className="flex flex-col gap-2">
          <div className="flex items-center justify-between">
            <SectionLabel>{t.tasks.sections.recent}</SectionLabel>
            <Link
              to="/history"
              className="text-meta text-muted-foreground transition-colors hover:text-foreground"
            >
              {t.tasks.sections.viewAll}
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
