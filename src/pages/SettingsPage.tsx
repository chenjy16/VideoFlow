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
import { t } from "@/i18n";
import { api, toErrorMessage } from "@/lib/api";
import { formatDateTime } from "@/lib/format";
import { useAppStore } from "@/store/app";
import type { SettingsPatch } from "@/types";

const CONTAINERS = [
  { value: "mp4", label: t.settings.containers.mp4 },
  { value: "mkv", label: t.settings.containers.mkv },
  { value: "original", label: t.settings.containers.original },
];

const QUALITIES = [
  { value: "best", label: t.settings.qualities.best },
  { value: "1080p", label: "1080p" },
  { value: "720p", label: "720p" },
  { value: "480p", label: "480p" },
  { value: "360p", label: "360p" },
];

const CONCURRENCY = [1, 2, 3, 4, 5];

/** One settings row: label + short explanation on the left, control on the right. */
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
    <div className="flex items-center justify-between gap-6 py-3">
      <div className="min-w-0">
        <p className="text-body font-medium">{title}</p>
        {description && (
          <p className="mt-0.5 text-meta leading-relaxed text-muted-foreground">{description}</p>
        )}
      </div>
      <div className="flex shrink-0 items-center gap-2">{children}</div>
    </div>
  );
}

/** One engine row: name, resolved path, version. */
function EngineRow({
  name,
  path,
  version,
  missingLabel,
}: {
  name: string;
  path?: string | null;
  version?: string | null;
  missingLabel: string;
}) {
  return (
    <div className="flex items-center gap-2 rounded-md border border-border bg-muted/40 px-3 py-2">
      <Cpu className="size-3.5 shrink-0 text-faint" />
      <span className="w-[60px] shrink-0 text-meta text-muted-foreground">{name}</span>
      <span className="min-w-0 flex-1 truncate font-mono text-meta" title={path ?? ""}>
        {path ?? missingLabel}
      </span>
      <span className="shrink-0 text-meta tabular-nums text-faint">{version ?? "—"}</span>
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
        title: t.settings.rows.folderPickerTitle,
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

  const openLicenses = async () => {
    setError(null);
    try {
      await api.revealLicenses();
    } catch (err) {
      setError(toErrorMessage(err));
    }
  };

  if (!settings) {
    return (
      <div className="flex flex-col gap-5">
        <PageHeader title={t.settings.title} description={t.settings.loadingDescription} />
        <div className="flex items-center gap-2 text-body text-muted-foreground">
          <Loader2 className="size-4 animate-spin" />
          {t.settings.loading}
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-5">
      <PageHeader
        title={t.settings.title}
        description={t.settings.description}
        actions={
          <span className="flex items-center gap-1.5 text-meta text-muted-foreground">
            {saving ? (
              <>
                <Loader2 className="size-3 animate-spin" />
                {t.settings.saving}
              </>
            ) : savedAt ? (
              <>
                <Check className="size-3 text-success" />
                {t.settings.saved(formatDateTime(savedAt))}
              </>
            ) : null}
          </span>
        }
      />

      {error && (
        <Alert variant="error" title={t.settings.saveError}>
          {error}
        </Alert>
      )}

      <Card>
        <CardHeader className="pb-1">
          <CardTitle>{t.settings.sections.download.title}</CardTitle>
          <CardDescription>{t.settings.sections.download.description}</CardDescription>
        </CardHeader>
        <CardContent className="pt-2">
          <Row
            title={t.settings.rows.container.title}
            description={t.settings.rows.container.description}
          >
            <Select
              value={settings.defaultContainer}
              onValueChange={(value) => void patch({ defaultContainer: value })}
              disabled={saving}
            >
              <SelectTrigger className="w-[210px]">
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
          <Row
            title={t.settings.rows.quality.title}
            description={t.settings.rows.quality.description}
          >
            <Select
              value={settings.defaultQuality}
              onValueChange={(value) => void patch({ defaultQuality: value })}
              disabled={saving}
            >
              <SelectTrigger className="w-[210px]">
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
          <Row
            title={t.settings.rows.concurrency.title}
            description={t.settings.rows.concurrency.description}
          >
            <Select
              value={String(settings.maxConcurrent)}
              onValueChange={(value) => void patch({ maxConcurrent: Number(value) })}
              disabled={saving}
            >
              <SelectTrigger className="w-[210px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {CONCURRENCY.map((value) => (
                  <SelectItem key={value} value={String(value)}>
                    {t.settings.concurrency(value)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Row>
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-1">
          <CardTitle>{t.settings.sections.storage.title}</CardTitle>
          <CardDescription>{t.settings.sections.storage.description}</CardDescription>
        </CardHeader>
        <CardContent className="pt-2">
          <Row
            title={t.settings.rows.folder.title}
            description={t.settings.rows.folder.description}
          >
            <div className="flex max-w-[320px] items-center gap-2">
              <span
                className="truncate rounded-md border border-border bg-muted/50 px-2 py-1 font-mono text-meta"
                title={settings.downloadDir}
              >
                {settings.downloadDir}
              </span>
              <Button variant="outline" size="sm" onClick={chooseDirectory} disabled={saving}>
                <FolderOpen />
                {t.settings.rows.chooseFolder}
              </Button>
            </div>
          </Row>
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-1">
          <div className="flex items-center justify-between gap-3">
            <div>
              <CardTitle>{t.settings.sections.engine.title}</CardTitle>
              <CardDescription>{t.settings.sections.engine.description}</CardDescription>
            </div>
            <Button variant="outline" size="sm" onClick={recheckEngine} disabled={refreshing}>
              <RefreshCw className={refreshing ? "animate-spin" : undefined} />
              {t.settings.engine.recheck}
            </Button>
          </div>
        </CardHeader>
        <CardContent className="flex flex-col gap-2 pt-3">
          <EngineRow
            name="yt-dlp"
            path={engine?.ytDlpPath}
            version={engine?.ytDlpVersion}
            missingLabel={t.settings.engine.notFound}
          />
          <EngineRow
            name="FFmpeg"
            path={engine?.ffmpegPath}
            version={engine?.ffmpegVersion}
            missingLabel={t.settings.engine.ffmpegNotFound}
          />
          <EngineRow
            name="FFprobe"
            path={engine?.ffprobePath}
            version={engine?.ffprobeVersion}
            missingLabel={t.settings.engine.notFound}
          />
          {!engine?.ready && (
            <Alert variant="warning" title={t.settings.engine.notReadyTitle}>
              {t.settings.engine.notReadyBody}
            </Alert>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-1">
          <CardTitle>{t.settings.sections.application.title}</CardTitle>
          <CardDescription>{t.settings.sections.application.description}</CardDescription>
        </CardHeader>
        <CardContent className="pt-2">
          <Row
            title={t.settings.rows.notifications.title}
            description={t.settings.rows.notifications.description}
          >
            <Switch
              checked={settings.notifications}
              onCheckedChange={(checked) => void patch({ notifications: checked })}
              disabled={saving}
              aria-label={t.settings.rows.notifications.label}
            />
          </Row>
          <Separator />
          <Row
            title={t.settings.rows.licenses.title}
            description={t.settings.rows.licenses.description}
          >
            <Button variant="outline" size="sm" onClick={openLicenses}>
              <FolderOpen />
              {t.settings.rows.licenses.action}
            </Button>
          </Row>
          <Separator />
          <div className="flex flex-col gap-2 pt-3 text-meta leading-relaxed text-muted-foreground">
            <p className="flex items-start gap-1.5">
              <ShieldCheck className="mt-0.5 size-3.5 shrink-0 text-success" />
              {t.settings.about.privacy}
            </p>
            <p className="flex items-start gap-1.5">
              <Info className="mt-0.5 size-3.5 shrink-0" />
              {t.settings.about.legal}
            </p>
            <p className="text-caption text-faint">{t.settings.about.version}</p>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
