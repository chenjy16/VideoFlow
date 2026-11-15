import { ArrowDownToLine, History, ListChecks, Settings2, Zap } from "lucide-react";
import { Link, NavLink } from "react-router-dom";

import { t } from "@/i18n";
import { cn } from "@/lib/format";
import { isActive, useAppStore } from "@/store/app";

const NAV_ITEMS = [
  { to: "/", label: t.nav.download, icon: ArrowDownToLine, end: true },
  { to: "/tasks", label: t.nav.tasks, icon: ListChecks, end: false },
  { to: "/history", label: t.nav.history, icon: History, end: false },
  { to: "/settings", label: t.nav.settings, icon: Settings2, end: false },
];

/** Fixed-width primary navigation with the engine status pinned to the bottom. */
export function Sidebar() {
  const tasks = useAppStore((state) => state.tasks);
  const engine = useAppStore((state) => state.engine);

  const activeCount = tasks.filter((task) => isActive(task.status)).length;
  const engineReady = engine?.ready ?? false;

  return (
    <aside className="flex w-[var(--sidebar-width)] shrink-0 flex-col border-r border-border bg-sidebar">
      {/* Reserved strip for the macOS traffic lights, also a window drag surface. */}
      <div data-tauri-drag-region className="h-[var(--titlebar-height)] shrink-0" />

      {/*
        Decorative brand row. `pointer-events-none` on the children is deliberate: the
        mousedown then lands on the row itself, which is a drag region, so the header is
        draggable without swallowing clicks meant for controls.
      */}
      <div data-tauri-drag-region className="flex h-9 shrink-0 items-center gap-2 px-3">
        <span className="pointer-events-none flex size-6 items-center justify-center rounded-[6px] bg-primary text-primary-foreground">
          <ArrowDownToLine className="size-3.5" strokeWidth={2.5} />
        </span>
        <span className="pointer-events-none text-card-title font-semibold tracking-tight">
          {t.app.name}
        </span>
      </div>

      <nav className="flex flex-col gap-0.5 px-2 pb-2 pt-1">
        {NAV_ITEMS.map(({ to, label, icon: Icon, end }) => (
          <NavLink
            key={to}
            to={to}
            end={end}
            className={({ isActive: isCurrent }) =>
              cn(
                "group flex h-[var(--control-height)] items-center gap-2.5 rounded-md px-2.5 text-body font-medium transition-colors",
                "outline-none focus-visible:ring-2 focus-visible:ring-ring/60",
                isCurrent
                  ? "bg-card text-foreground shadow-[0_1px_2px_rgba(16,24,40,0.06)] ring-1 ring-border"
                  : "text-muted-foreground hover:bg-accent/70 hover:text-foreground",
              )
            }
          >
            {({ isActive: isCurrent }) => (
              <>
                {/*
                  `label === t.nav.tasks` compares against the same dictionary value, so the
                  badge keeps following the Tasks entry if the wording ever changes.
                */}
                <Icon
                  className={cn(
                    "size-4 shrink-0 transition-opacity",
                    isCurrent ? "opacity-100" : "opacity-60",
                  )}
                  strokeWidth={1.9}
                />
                <span className="flex-1 truncate">{label}</span>
                {label === t.nav.tasks && activeCount > 0 && (
                  <span
                    className="rounded-full bg-primary px-1.5 text-caption font-semibold tabular-nums leading-4 text-primary-foreground"
                    aria-label={t.nav.badge(activeCount)}
                  >
                    {activeCount}
                  </span>
                )}
              </>
            )}
          </NavLink>
        ))}
      </nav>

      <div className="mt-auto p-2">
        <Link
          to="/settings"
          className="block rounded-lg border border-border bg-card/70 px-2.5 py-2 transition-colors hover:bg-card focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60"
        >
          <div className="flex items-center gap-1.5 text-meta font-medium">
            <span
              className={cn(
                "size-1.5 shrink-0 rounded-full",
                engineReady ? "bg-success" : "bg-destructive",
              )}
              aria-hidden
            />
            <span className={engineReady ? "text-foreground" : "text-destructive"}>
              {engineReady ? t.engine.ready : t.engine.unavailable}
            </span>
            <Zap className="ml-auto size-3 text-faint" strokeWidth={1.9} />
          </div>
          <p className="mt-1 truncate font-mono text-meta text-muted-foreground">
            {engine?.ytDlpVersion ? t.engine.version(engine.ytDlpVersion) : t.engine.notDetected}
          </p>
        </Link>
      </div>
    </aside>
  );
}
