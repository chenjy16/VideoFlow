import {
  ClipboardPaste,
  Download,
  FolderOpen,
  Link2,
  Loader2,
  Search,
  Settings2,
} from "lucide-react";
import { useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";

import { EmptyState, ErrorState, LoadingState, PageHeader } from "@/components/common/States";
import { FormatPicker } from "@/components/download/FormatPicker";
import { MediaSummary } from "@/components/download/MediaSummary";
import { Alert } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { t } from "@/i18n";
import { api, toErrorMessage } from "@/lib/api";
import { formatBytes } from "@/lib/format";
import { useAppStore } from "@/store/app";
import type { CreateDownloadRequest, DownloadOption, MediaInfo } from "@/types";

/** Pick the initially selected format from the preferred-quality setting. */
function pickDefaultOption(options: DownloadOption[], quality: string): DownloadOption | null {
  if (quality !== "best") {
    const height = Number.parseInt(quality.replace("p", ""), 10);
    const matched = options.find(
      (option) => option.category === "video" && option.height === height,
    );
    if (matched) return matched;
  }
  return options.find((option) => option.category === "best") ?? options[0] ?? null;
}

function isSupportedUrl(raw: string): boolean {
  try {
    const parsed = new URL(raw.trim());
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
}

export function DownloadPage() {
  const navigate = useNavigate();
  const settings = useAppStore((state) => state.settings);
  const engine = useAppStore((state) => state.engine);
  const applyTask = useAppStore((state) => state.applyTask);

  const [url, setUrl] = useState("");
  const [media, setMedia] = useState<MediaInfo | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [inspecting, setInspecting] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const selected = useMemo(
    () => media?.options.find((option) => option.id === selectedId) ?? null,
    [media, selectedId],
  );

  const handleInspect = async () => {
    const trimmed = url.trim();
    if (!trimmed) {
      setError(t.download.errors.emptyUrl);
      return;
    }
    if (!isSupportedUrl(trimmed)) {
      setError(t.download.errors.invalidUrl);
      return;
    }

    setInspecting(true);
    setError(null);
    try {
      const info = await api.inspectUrl(trimmed);
      setMedia(info);
      const initial = pickDefaultOption(info.options, settings?.defaultQuality ?? "best");
      setSelectedId(initial?.id ?? null);
    } catch (err) {
      setMedia(null);
      setSelectedId(null);
      setError(toErrorMessage(err));
    } finally {
      setInspecting(false);
    }
  };

  const handlePaste = async () => {
    try {
      const text = await navigator.clipboard.readText();
      const value = text.trim();
      if (!value) {
        setError(t.download.errors.emptyClipboard);
        return;
      }
      setUrl(value);
      setError(null);
    } catch {
      setError(t.download.errors.clipboardBlocked);
    }
  };

  const handleDownload = async () => {
    if (!media || !selected) return;
    if (!settings) {
      setError(t.download.errors.settingsNotReady);
      return;
    }

    const request: CreateDownloadRequest = {
      url: media.webpageUrl,
      title: media.title,
      thumbnail: media.thumbnail,
      site: media.site,
      kind: selected.category === "audio_only" ? "audio" : "video",
      // The backend needs the real yt-dlp `-f` expression, never the UI option id.
      selector: selected.selector,
      formatLabel: selected.label,
      container: selected.container,
      outputDir: settings.downloadDir,
      mergeToMp4: selected.container === "mp4" && selected.requiresMerge,
      audioFormat: selected.audioFormat,
      expectedBytes: selected.estimatedBytes,
    };

    setSubmitting(true);
    setError(null);
    try {
      const task = await api.createDownload(request);
      applyTask(task);
      navigate("/tasks", { state: { createdId: task.id } });
    } catch (err) {
      setError(toErrorMessage(err));
    } finally {
      setSubmitting(false);
    }
  };

  const engineReady = engine?.ready ?? true;
  const busy = inspecting || submitting;

  return (
    <div className="flex flex-col gap-6">
      <PageHeader title={t.download.title} description={t.download.description} />

      {!engineReady && (
        <Alert variant="warning" title={t.download.engineWarning.title}>
          {t.download.engineWarning.before}{" "}
          <Link to="/settings" className="underline underline-offset-2">
            {t.download.engineWarning.link}
          </Link>
          {t.download.engineWarning.after}
        </Alert>
      )}

      {/* Primary workflow: paste → prepare. One row, one obvious action. */}
      <div className="flex items-center gap-2 rounded-lg border border-border bg-card p-1.5 pl-3 shadow-[0_1px_2px_rgba(16,24,40,0.04)] transition-colors focus-within:border-ring/60">
        <Link2 className="size-4 shrink-0 text-faint" aria-hidden />
        <Input
          value={url}
          onChange={(event) => setUrl(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !busy) {
              void handleInspect();
            }
          }}
          placeholder={t.download.urlPlaceholder}
          spellCheck={false}
          autoCapitalize="off"
          autoCorrect="off"
          aria-label={t.download.urlLabel}
          aria-invalid={Boolean(error) || undefined}
          className="h-7 flex-1 border-0 bg-transparent px-0 shadow-none focus-visible:ring-0"
        />
        <Button variant="ghost" size="sm" onClick={handlePaste} disabled={inspecting}>
          <ClipboardPaste />
          {t.download.paste}
        </Button>
        <Button size="sm" onClick={handleInspect} disabled={busy || !url.trim()}>
          {inspecting ? <Loader2 className="animate-spin" /> : <Search />}
          {inspecting ? t.download.preparing : t.download.prepare}
        </Button>
      </div>

      {error && (
        <ErrorState
          title={t.download.errorTitle}
          message={error}
          action={
            <div>
              <Button variant="outline" size="sm" onClick={() => setError(null)}>
                {t.download.dismissError}
              </Button>
            </div>
          }
        />
      )}

      {inspecting && <LoadingState rows={2} label={t.download.progress} />}

      {!inspecting && !media && !error && (
        <EmptyState
          icon={<Download className="size-5" />}
          title={t.download.empty.title}
          description={t.download.empty.description}
        />
      )}

      {!inspecting && media && (
        <div className="flex animate-enter flex-col gap-5">
          <MediaSummary media={media} />

          {media.options.length === 0 ? (
            <EmptyState
              title={t.download.noFormats.title}
              description={t.download.noFormats.description}
            />
          ) : (
            <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_272px]">
              <FormatPicker
                options={media.options}
                value={selectedId}
                onChange={(option) => setSelectedId(option.id)}
                disabled={submitting}
              />

              <aside className="sticky top-0 flex h-fit flex-col gap-4 rounded-lg border border-border bg-card p-4">
                <div className="min-w-0">
                  <p className="text-section font-semibold uppercase tracking-wide text-faint">
                    {t.download.selected.label}
                  </p>
                  <p className="mt-1.5 line-clamp-2 text-card-title font-semibold leading-snug">
                    {selected?.label ?? t.download.selected.none}
                  </p>
                  <p className="mt-1 line-clamp-2 text-meta text-muted-foreground">
                    {selected?.description ?? t.download.selected.hint}
                  </p>
                </div>

                <div className="flex items-center justify-between rounded-md bg-muted px-2.5 py-2 text-meta">
                  <span className="text-muted-foreground">{t.download.selected.estimatedSize}</span>
                  <span className="font-medium tabular-nums">
                    {formatBytes(selected?.estimatedBytes)}
                  </span>
                </div>

                <div className="flex min-w-0 flex-col gap-1">
                  <div className="flex items-center gap-1 text-meta text-faint">
                    <FolderOpen className="size-3" aria-hidden />
                    {t.download.selected.saveTo}
                  </div>
                  <p
                    className="break-all text-meta leading-snug text-muted-foreground"
                    title={settings?.downloadDir}
                  >
                    {settings?.downloadDir ?? "—"}
                  </p>
                  <Link
                    to="/settings"
                    className="mt-0.5 inline-flex items-center gap-1 text-meta text-primary hover:underline"
                  >
                    <Settings2 className="size-3" aria-hidden />
                    {t.download.selected.changeSettings}
                  </Link>
                </div>

                <Button
                  className="w-full"
                  onClick={handleDownload}
                  disabled={!selected || busy || !settings}
                >
                  {submitting ? <Loader2 className="animate-spin" /> : <Download />}
                  {submitting ? t.download.selected.starting : t.download.selected.start}
                </Button>
              </aside>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
