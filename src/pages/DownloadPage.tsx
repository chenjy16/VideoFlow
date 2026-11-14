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
import { api, toErrorMessage } from "@/lib/api";
import { formatBytes } from "@/lib/format";
import { useAppStore } from "@/store/app";
import type { CreateDownloadRequest, DownloadOption, MediaInfo } from "@/types";

/** 根据设置里的默认清晰度挑选初始格式 */
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
      setError("请先粘贴视频链接");
      return;
    }
    if (!isSupportedUrl(trimmed)) {
      setError("链接格式不正确，仅支持 http/https 地址");
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
        setError("剪贴板中没有文本内容");
        return;
      }
      setUrl(value);
      setError(null);
    } catch {
      setError("无法读取剪贴板，请在输入框中按 ⌘V 粘贴");
    }
  };

  const handleDownload = async () => {
    if (!media || !selected) return;
    if (!settings) {
      setError("尚未加载设置，请稍后重试");
      return;
    }

    const request: CreateDownloadRequest = {
      url: media.webpageUrl,
      title: media.title,
      thumbnail: media.thumbnail,
      site: media.site,
      kind: selected.category === "audio_only" ? "audio" : "video",
      // 传给后端的必须是 yt-dlp 的真实 -f 表达式，而不是 UI 选项 id
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

  return (
    <div className="flex flex-col gap-5">
      <PageHeader title="下载" description="粘贴视频链接，解析真实可用的格式后开始下载。" />

      {!engineReady && (
        <Alert variant="warning" title="下载引擎不可用">
          未检测到可用的 yt-dlp，请前往
          <Link to="/settings" className="mx-1 underline underline-offset-2">
            设置
          </Link>
          查看引擎状态。
        </Alert>
      )}

      <div className="flex items-center gap-2 rounded-xl border border-border bg-card p-1.5 pl-3 shadow-sm focus-within:border-ring/60">
        <Link2 className="size-4 shrink-0 text-muted-foreground" />
        <Input
          value={url}
          onChange={(event) => setUrl(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !inspecting && !submitting) {
              void handleInspect();
            }
          }}
          placeholder="https://..."
          spellCheck={false}
          autoCapitalize="off"
          autoCorrect="off"
          className="h-9 flex-1 border-0 bg-transparent px-0 shadow-none focus-visible:ring-0"
          aria-label="视频链接"
        />
        <Button variant="ghost" size="sm" onClick={handlePaste} disabled={inspecting}>
          <ClipboardPaste />
          粘贴
        </Button>
        <Button size="sm" onClick={handleInspect} disabled={inspecting || !url.trim()}>
          {inspecting ? <Loader2 className="animate-spin" /> : <Search />}
          {inspecting ? "解析中" : "解析"}
        </Button>
      </div>

      {error && (
        <ErrorState
          title="解析或创建任务失败"
          message={error}
          action={
            <div>
              <Button variant="outline" size="sm" onClick={() => setError(null)}>
                关闭提示
              </Button>
            </div>
          }
        />
      )}

      {inspecting && <LoadingState rows={2} label="正在调用 yt-dlp 解析链接，请稍候…" />}

      {!inspecting && !media && !error && (
        <EmptyState
          icon={<Download className="size-5" />}
          title="准备开始下载"
          description="支持 YouTube、Bilibili、X 等 yt-dlp 可解析的站点。解析结果只展示该视频真实存在的格式。"
        />
      )}

      {!inspecting && media && (
        <div className="flex animate-enter flex-col gap-4">
          <MediaSummary media={media} />

          {media.options.length === 0 ? (
            <EmptyState
              title="没有可下载的格式"
              description="该视频可能受地区限制或已失效，可以换一个链接再试。"
            />
          ) : (
            <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_268px]">
              <FormatPicker
                options={media.options}
                value={selectedId}
                onChange={(option) => setSelectedId(option.id)}
                disabled={submitting}
              />

              <aside className="sticky top-0 flex h-fit flex-col gap-3 rounded-xl border border-border bg-card p-4">
                <div>
                  <p className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
                    已选择
                  </p>
                  <p className="mt-1 text-[13px] font-semibold leading-snug">
                    {selected?.label ?? "未选择格式"}
                  </p>
                  <p className="mt-0.5 text-[11px] text-muted-foreground">
                    {selected?.description ?? "请在左侧选择格式"}
                  </p>
                </div>

                <div className="flex items-center justify-between rounded-md bg-muted/70 px-2.5 py-2 text-[11px]">
                  <span className="text-muted-foreground">预计大小</span>
                  <span className="font-medium tabular-nums">
                    {formatBytes(selected?.estimatedBytes)}
                  </span>
                </div>

                <div className="flex flex-col gap-1">
                  <div className="flex items-center gap-1 text-[11px] text-muted-foreground">
                    <FolderOpen className="size-3" />
                    保存到
                  </div>
                  <p className="break-all text-[11px] leading-snug" title={settings?.downloadDir}>
                    {settings?.downloadDir ?? "—"}
                  </p>
                  <Link
                    to="/settings"
                    className="mt-0.5 inline-flex items-center gap-1 text-[11px] text-primary hover:underline"
                  >
                    <Settings2 className="size-3" />
                    修改下载设置
                  </Link>
                </div>

                <Button
                  className="w-full"
                  onClick={handleDownload}
                  disabled={!selected || submitting || !settings}
                >
                  {submitting ? <Loader2 className="animate-spin" /> : <Download />}
                  {submitting ? "正在创建任务" : "开始下载"}
                </Button>
              </aside>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
