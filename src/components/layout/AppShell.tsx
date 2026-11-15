import { Outlet } from "react-router-dom";

import { Sidebar } from "@/components/layout/Sidebar";

/** Application shell: fixed sidebar + scrollable content column. */
export function AppShell() {
  return (
    <div className="flex h-screen w-screen overflow-hidden bg-background text-foreground">
      <Sidebar />
      <div className="flex min-w-0 flex-1 flex-col">
        {/*
          Window drag surface.
          The window uses an overlay title bar (`hiddenTitle`), so the webview covers the
          title bar area and there is no native drag strip left. Tauri only starts a window
          drag from elements carrying `data-tauri-drag-region` (WKWebView ignores the
          Chromium-only `-webkit-app-region`), so this strip is what makes the window
          movable. It stays empty on purpose: nothing interactive may sit inside it.
        */}
        <div data-tauri-drag-region className="h-[var(--titlebar-height)] shrink-0" />
        <main className="min-h-0 flex-1 overflow-y-auto px-8 pb-10">
          <div className="mx-auto w-full max-w-[var(--content-max)]">
            <Outlet />
          </div>
        </main>
      </div>
    </div>
  );
}
