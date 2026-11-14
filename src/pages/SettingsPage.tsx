import { open } from "@tauri-apps/plugin-dialog";
import { Check, Cpu, FolderOpen, Info, Loader2, RefreshCw, ShieldCheck } from "lucide-react";
import { useState } from "react";
import type { ReactNode } from "react";

import { PageHeader } from "@/components/common/States";
import { Alert } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { Switch } from "@/components/ui/switch";
import { api, toErrorMessage } from "@/lib/api";
import { formatDateTime } from "@/lib/format";
import { useAppStore } from "@/store/app";
import type { SettingsPatch } from "@/types";

const CONTAINERS = [
  { value: "mp4", label: "MP4（兼容性最好）" },
  { value: "mkv", label: "MKV（保留原始编码）" },
  { value: "original", label: "保留原始格式" },
];

const QUALITIES = [
  { value: "best", label: "最佳可用画质" },
  { value: "1080p", label: "1080p" },
  { value: "720p", label: "720p" },
  { value: "480p", label: "480p" },
  { value: "360p", label: "360p" },
];

const CONCURRENCY = [1, 2, 3, 4, 5];

/** 一行设置项 */
function Row({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: ReactNode;
}) {
  return (
    <div className="flex items-center justify-between gap-6 py-3.5">
      <div className="min-w-0">
        <p className="text-[13px] font-medium">{title}</p>
        {description && (
          <p className="mt-0.5 text-[11px] leading-relaxed text-muted-foreground">{description}</p>
        )}
      </div>
      <div className="flex shrink-0 items-center gap-2">{children}</div>
    </div>
  );
}

export function SettingsPage() {
  const settings = useAppStore((state) => state.settings);
  const engine = useAppStore((state) => state.engine);
  const setSettings = useAppStore((state) => state.setSettings);
  const refreshEngine = useAppStore((state) => state.refreshEngine);

  const [saving, setSaving] = useState(false);
  const [savedAt, setSavedAt] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const patch = async (next: SettingsPatch) => {
    setSaving(true);
    setError(null);
    try {
      const updated = await api.updateSettings(next);
      setSettings(updated);
      setSavedAt(new Date().toISOString());
    } catch (err) {
      setError(toErrorMessage(err));
    } finally {
      setSaving(false);
    }
  };

  const chooseDirectory = async () => {
    try {
      const picked = await open({
        directory: true,
        multiple: false,
        title: "选择下载目录",
        defaultPath: settings?.downloadDir,
      });
      if (typeof picked === "string" && picked !== settings?.downloadDir) {
        await patch({ downloadDir: picked });
      }
    } catch (err) {
      setError(toErrorMessage(err));
    }
  };

  const recheckEngine = async () => {
    setRefreshing(true);
    setError(null);
    try {
      await refreshEngine();
    } finally {
      setRefreshing(false);
    }
  };

  if (!settings) {
    return (
      <div className="flex flex-col gap-5">
        <PageHeader title="设置" description="正在读取本地配置…" />
        <div className="flex items-center gap-2 text-[13px] text-muted-foreground">
          <Loader2 className="size-4 animate-spin" />
          加载设置中…
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-5">
      <PageHeader
        title="设置"
        description="修改后自动保存，新的下载任务会立即生效。"
        actions={
          <span className="flex items-center gap-1.5 text-[11px] text-muted-foreground">
            {saving ? (
              <>
                <Loader2 className="size-3 animate-spin" />
                保存中…
              </>
            ) : savedAt ? (
              <>
                <Check className="size-3 text-success" />
                已保存 {formatDateTime(savedAt)}
              </>
            ) : null}
          </span>
        }
      />

      {error && (
        <Alert variant="error" title="设置保存失败">
          {error}
        </Alert>
      )}

      <Card>
        <CardHeader className="pb-1">
          <CardTitle>下载</CardTitle>
          <CardDescription>下载位置与默认格式，可在下载页临时覆盖。</CardDescription>
        </CardHeader>
        <CardContent className="pt-2">
          <Row title="下载目录" description="所有文件默认保存到此目录">
            <div className="flex max-w-[320px] items-center gap-2">
              <span
                className="truncate rounded-md border border-border bg-muted/50 px-2 py-1 text-[11px]"
                title={settings.downloadDir}
              >
                {settings.downloadDir}
              </span>
              <Button variant="outline" size="sm" onClick={chooseDirectory} disabled={saving}>
                <FolderOpen />
                选择
              </Button>
            </div>
          </Row>
          <Separator />
          <Row title="默认容器" description="合并音视频时使用的封装格式">
            <Select
              value={settings.defaultContainer}
              onValueChange={(value) => void patch({ defaultContainer: value })}
              disabled={saving}
            >
              <SelectTrigger className="w-[190px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {CONTAINERS.map((item) => (
                  <SelectItem key={item.value} value={item.value}>
                    {item.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Row>
          <Separator />
          <Row title="默认清晰度" description="解析后自动选中的格式，若不存在则回退到最佳">
            <Select
              value={settings.defaultQuality}
              onValueChange={(value) => void patch({ defaultQuality: value })}
              disabled={saving}
            >
              <SelectTrigger className="w-[190px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {QUALITIES.map((item) => (
                  <SelectItem key={item.value} value={item.value}>
                    {item.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Row>
          <Separator />
          <Row title="最大同时下载数" description="同时执行的任务数量，过高会占用更多带宽">
            <Select
              value={String(settings.maxConcurrent)}
              onValueChange={(value) => void patch({ maxConcurrent: Number(value) })}
              disabled={saving}
            >
              <SelectTrigger className="w-[190px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {CONCURRENCY.map((value) => (
                  <SelectItem key={value} value={String(value)}>
                    {value} 个任务
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Row>
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-1">
          <CardTitle>通知</CardTitle>
          <CardDescription>下载完成后发送系统通知</CardDescription>
        </CardHeader>
        <CardContent className="pt-2">
          <Row title="完成时通知" description="合并或转换结束后提醒你">
            <Switch
              checked={settings.notifications}
              onCheckedChange={(checked) => void patch({ notifications: checked })}
              disabled={saving}
              aria-label="下载完成通知"
            />
          </Row>
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-1">
          <div className="flex items-center justify-between gap-3">
            <div>
              <CardTitle>下载引擎</CardTitle>
              <CardDescription>VideoFlow 依赖 yt-dlp 与 FFmpeg 完成解析与合并</CardDescription>
            </div>
            <Button variant="outline" size="sm" onClick={recheckEngine} disabled={refreshing}>
              <RefreshCw className={refreshing ? "animate-spin" : undefined} />
              重新检测
            </Button>
          </div>
        </CardHeader>
        <CardContent className="flex flex-col gap-2 pt-3">
          <div className="flex items-center gap-2 rounded-lg border border-border bg-muted/40 px-3 py-2">
            <Cpu className="size-3.5 shrink-0 text-muted-foreground" />
            <span className="w-[64px] shrink-0 text-[11px] text-muted-foreground">yt-dlp</span>
            <span
              className="min-w-0 flex-1 truncate font-mono text-[11px]"
              title={engine?.ytDlpPath ?? ""}
            >
              {engine?.ytDlpPath ?? "未找到"}
            </span>
            <span className="shrink-0 text-[11px] tabular-nums text-muted-foreground">
              {engine?.ytDlpVersion ?? "—"}
            </span>
          </div>
          <div className="flex items-center gap-2 rounded-lg border border-border bg-muted/40 px-3 py-2">
            <Cpu className="size-3.5 shrink-0 text-muted-foreground" />
            <span className="w-[64px] shrink-0 text-[11px] text-muted-foreground">FFmpeg</span>
            <span
              className="min-w-0 flex-1 truncate font-mono text-[11px]"
              title={engine?.ffmpegPath ?? ""}
            >
              {engine?.ffmpegPath ?? "未找到（仅影响合并与音频转换）"}
            </span>
            <span className="shrink-0 text-[11px] tabular-nums text-muted-foreground">
              {engine?.ffmpegVersion ?? "—"}
            </span>
          </div>
          {!engine?.ready && (
            <Alert variant="warning" title="引擎未就绪">
              缺少 yt-dlp 时无法解析或下载。请将 yt-dlp 放入应用资源目录，或安装到 PATH
              后点击重新检测。
            </Alert>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-1">
          <CardTitle>关于</CardTitle>
          <CardDescription>VideoFlow 0.1.0 · 本地运行，不收集任何数据</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-2 pt-3 text-[11px] leading-relaxed text-muted-foreground">
          <p className="flex items-start gap-1.5">
            <ShieldCheck className="mt-0.5 size-3.5 shrink-0 text-success" />
            下载记录只保存在本机 SQLite 数据库，不会上传云端；日志中的 Cookie 与认证信息会被过滤。
          </p>
          <p className="flex items-start gap-1.5">
            <Info className="mt-0.5 size-3.5 shrink-0" />
            本应用不绕过 DRM 与付费墙，请仅下载你有权保存的内容，并遵守各站点服务条款。
          </p>
        </CardContent>
      </Card>
    </div>
  );
}
