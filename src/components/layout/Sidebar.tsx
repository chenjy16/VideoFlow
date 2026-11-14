import { ArrowDownToLine, History, ListChecks, Settings2, Zap } from "lucide-react";
import { Link, NavLink } from "react-router-dom";

import { cn } from "@/lib/format";
import { useAppStore } from "@/store/app";

const NAV_ITEMS = [
  { to: "/", label: "下载", icon: ArrowDownToLine, end: true },
  { to: "/tasks", label: "任务", icon: ListChecks, end: false },
  { to: "/history", label: "历史", icon: History, end: false },
  { to: "/settings", label: "设置", icon: Settings2, end: false },
];

/** 左侧导航栏 */
export function Sidebar() {
  const tasks = useAppStore((state) => state.tasks);
  const engine = useAppStore((state) => state.engine);

  const activeCount = tasks.filter(
    (task) =>
      task.status === "waiting" ||
      task.status === "downloading" ||
      task.status === "merging" ||
      task.status === "extracting",
  ).length;

  const engineReady = engine?.ready ?? false;

  return (
    <aside className="flex w-[216px] shrink-0 flex-col border-r border-border/70 bg-sidebar">
      {/* 顶部留出 macOS 红绿灯位置，同时作为窗口拖拽区 */}
      <div className="drag-region flex h-[52px] shrink-0 items-center gap-2 px-4 pt-1">
        <div className="no-drag flex size-7 items-center justify-center rounded-[7px] bg-gradient-to-br from-primary to-primary/60 text-primary-foreground shadow-sm">
          <ArrowDownToLine className="size-4" strokeWidth={2.5} />
        </div>
        <span className="text-[13px] font-semibold tracking-tight">VideoFlow</span>
      </div>

      <nav className="no-drag flex flex-col gap-0.5 px-2.5 pt-1">
        {NAV_ITEMS.map(({ to, label, icon: Icon, end }) => (
          <NavLink
            key={to}
            to={to}
            end={end}
            className={({ isActive }) =>
              cn(
                "group flex h-8 items-center gap-2.5 rounded-md px-2.5 text-[13px] font-medium transition-colors",
                isActive
                  ? "bg-accent text-accent-foreground ring-1 ring-border ring-inset"
                  : "text-sidebar-foreground/75 hover:bg-accent/60 hover:text-accent-foreground",
              )
            }
          >
            {({ isActive }) => (
              <>
                <Icon className={cn("size-4", isActive ? "opacity-100" : "opacity-65")} />
                <span className="flex-1">{label}</span>
                {label === "任务" && activeCount > 0 && (
                  <span className="rounded-full bg-primary px-1.5 text-[10px] font-semibold leading-4 text-primary-foreground">
                    {activeCount}
                  </span>
                )}
              </>
            )}
          </NavLink>
        ))}
      </nav>

      <div className="mt-auto p-2.5">
        <Link
          to="/settings"
          className="no-drag block rounded-lg border border-border/70 bg-card/60 px-2.5 py-2 transition-colors hover:bg-card"
        >
          <div className="flex items-center gap-1.5 text-[11px] font-medium">
            <span
              className={cn("size-1.5 rounded-full", engineReady ? "bg-success" : "bg-destructive")}
            />
            <span className={engineReady ? "text-foreground" : "text-destructive"}>
              {engineReady ? "引擎就绪" : "引擎不可用"}
            </span>
            <Zap className="ml-auto size-3 text-muted-foreground" />
          </div>
          <p className="mt-1 truncate text-[11px] text-muted-foreground">
            yt-dlp {engine?.ytDlpVersion ?? "未检测到"}
          </p>
        </Link>
      </div>
    </aside>
  );
}
