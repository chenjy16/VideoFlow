import { useEffect } from "react";
import { HashRouter, Navigate, Route, Routes } from "react-router-dom";

import { AppShell } from "@/components/layout/AppShell";
import { TooltipProvider } from "@/components/ui/tooltip";
import { useAppEvents } from "@/hooks/useAppEvents";
import { useSystemTheme } from "@/hooks/useSystemTheme";
import { DownloadPage } from "@/pages/DownloadPage";
import { HistoryPage } from "@/pages/HistoryPage";
import { SettingsPage } from "@/pages/SettingsPage";
import { TasksPage } from "@/pages/TasksPage";
import { useAppStore } from "@/store/app";

export default function App() {
  const bootstrap = useAppStore((state) => state.bootstrap);

  useSystemTheme();
  useAppEvents();

  useEffect(() => {
    void bootstrap();
  }, [bootstrap]);

  return (
    <TooltipProvider delayDuration={320}>
      <HashRouter>
        <Routes>
          <Route element={<AppShell />}>
            <Route index element={<DownloadPage />} />
            <Route path="tasks" element={<TasksPage />} />
            <Route path="history" element={<HistoryPage />} />
            <Route path="settings" element={<SettingsPage />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Route>
        </Routes>
      </HashRouter>
    </TooltipProvider>
  );
}
