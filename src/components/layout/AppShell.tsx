import { Outlet } from "react-router-dom";

import { Sidebar } from "@/components/layout/Sidebar";

/** 应用外壳：左侧固定导航 + 右侧可滚动内容区 */
export function AppShell() {
  return (
    <div className="flex h-screen w-screen overflow-hidden bg-background text-foreground">
      <Sidebar />
      <div className="flex min-w-0 flex-1 flex-col">
        {/* 与 Overlay 标题栏配合的可拖拽条，避免内容被红绿灯遮挡 */}
        <div className="drag-region h-[26px] shrink-0" />
        <main className="min-h-0 flex-1 overflow-y-auto px-8 pb-10">
          <div className="mx-auto w-full max-w-[900px]">
            <Outlet />
          </div>
        </main>
      </div>
    </div>
  );
}
