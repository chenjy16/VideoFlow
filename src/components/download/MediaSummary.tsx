import { Clock, Film, Globe, User } from "lucide-react";

import { formatDuration, prettySite } from "@/lib/format";
import type { MediaInfo } from "@/types";

/** 解析结果摘要 */
export function MediaSummary({ media }: { media: MediaInfo }) {
  const resolution = media.height ? `${media.width ?? "?"}×${media.height}` : null;

  return (
    <div className="flex gap-4 rounded-xl border border-border bg-card p-3">
      <div className="relative aspect-video w-[176px] shrink-0 overflow-hidden rounded-lg bg-muted">
        {media.thumbnail ? (
          // 缩略图来自远端 CDN，失败时退化为占位底色
          <img
            src={media.thumbnail}
            alt=""
            className="size-full object-cover"
            loading="lazy"
            referrerPolicy="no-referrer"
          />
        ) : (
          <div className="flex size-full items-center justify-center text-muted-foreground">
            <Film className="size-6" />
          </div>
        )}
        {media.duration ? (
          <span className="absolute bottom-1 right-1 rounded bg-black/70 px-1 py-0.5 text-[10px] font-medium text-white">
            {formatDuration(media.duration)}
          </span>
        ) : null}
      </div>

      <div className="flex min-w-0 flex-1 flex-col justify-center gap-1">
        <h2 className="line-clamp-2 text-[14px] font-semibold leading-snug">{media.title}</h2>
        <div className="mt-0.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-muted-foreground">
          <span className="inline-flex items-center gap-1">
            <Globe className="size-3" />
            {prettySite(media.site)}
          </span>
          {media.uploader && (
            <span className="inline-flex min-w-0 items-center gap-1">
              <User className="size-3 shrink-0" />
              <span className="max-w-[180px] truncate">{media.uploader}</span>
            </span>
          )}
          {media.duration ? (
            <span className="inline-flex items-center gap-1">
              <Clock className="size-3" />
              {formatDuration(media.duration)}
            </span>
          ) : null}
          {resolution && (
            <span className="inline-flex items-center gap-1">
              <Film className="size-3" />
              {resolution}
            </span>
          )}
        </div>
        <div className="mt-1 flex flex-wrap items-center gap-1.5 text-[10px] text-muted-foreground">
          <span className="rounded bg-muted px-1.5 py-0.5">
            共 {media.formats.length} 个可用格式
          </span>
          <span className="rounded bg-muted px-1.5 py-0.5">yt-dlp {media.engineVersion}</span>
        </div>
      </div>
    </div>
  );
}
