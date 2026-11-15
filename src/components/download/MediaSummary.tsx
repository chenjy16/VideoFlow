import { Clock, Film, Globe, User } from "lucide-react";

import { t } from "@/i18n";
import { formatDuration, siteName } from "@/lib/format";
import type { MediaInfo } from "@/types";

/** What was resolved from the link: identity plus the counts that matter. */
export function MediaSummary({ media }: { media: MediaInfo }) {
  const resolution = media.height ? `${media.width ?? "?"}×${media.height}` : null;

  return (
    <div className="flex gap-4 rounded-lg border border-border bg-card p-3">
      <div className="relative aspect-video w-[176px] shrink-0 overflow-hidden rounded-md bg-muted">
        {media.thumbnail ? (
          // Thumbnails come from remote CDNs; fall back to a plain surface if they fail.
          <img
            src={media.thumbnail}
            alt=""
            className="size-full object-cover"
            loading="lazy"
            referrerPolicy="no-referrer"
          />
        ) : (
          <div className="flex size-full items-center justify-center text-faint">
            <Film className="size-6" aria-hidden />
          </div>
        )}
        {media.duration ? (
          <span className="absolute bottom-1 right-1 rounded bg-black/70 px-1 py-0.5 text-caption font-medium tabular-nums text-white">
            {formatDuration(media.duration)}
          </span>
        ) : null}
      </div>

      <div className="flex min-w-0 flex-1 flex-col justify-center gap-1.5">
        <h2 className="line-clamp-2 text-item-title font-semibold">{media.title}</h2>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-meta text-muted-foreground">
          <span className="inline-flex items-center gap-1">
            <Globe className="size-3" aria-hidden />
            {siteName(media.site) ?? t.common.unknownSite}
          </span>
          {media.uploader && (
            <span className="inline-flex min-w-0 items-center gap-1">
              <User className="size-3 shrink-0" aria-hidden />
              <span className="max-w-[180px] truncate">{media.uploader}</span>
            </span>
          )}
          {media.duration ? (
            <span className="inline-flex items-center gap-1 tabular-nums">
              <Clock className="size-3" aria-hidden />
              {formatDuration(media.duration)}
            </span>
          ) : null}
          {resolution && (
            <span className="inline-flex items-center gap-1 tabular-nums">
              <Film className="size-3" aria-hidden />
              {resolution}
            </span>
          )}
        </div>
        <div className="flex flex-wrap items-center gap-1.5 text-caption text-muted-foreground">
          <span className="rounded bg-muted px-1.5 py-0.5">
            {t.download.formats.count(media.formats.length)}
          </span>
          <span className="rounded bg-muted px-1.5 py-0.5 font-mono">
            {t.engine.version(media.engineVersion)}
          </span>
        </div>
      </div>
    </div>
  );
}
