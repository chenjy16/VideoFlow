/**
 * English UI dictionary — the only shipping locale.
 *
 * Everything the user can read lives here instead of being scattered across
 * components, so adding another locale later is just another file plus one line
 * in `src/i18n/index.ts`. No i18n runtime / framework is involved: the object is
 * typed, so a missing key is a compile error.
 *
 * Conventions:
 * - Sentence case for labels, full sentences for descriptions, no trailing period
 *   on buttons.
 * - Counted nouns go through a helper so singular/plural stays grammatical.
 */

const plural = (count: number, singular: string, pluralForm: string) =>
  `${count} ${count === 1 ? singular : pluralForm}`;

export const en = {
  app: {
    name: "VideoFlow",
  },

  nav: {
    download: "Download",
    tasks: "Tasks",
    history: "History",
    settings: "Settings",
    /** Accessible name for the count badge: queued + running tasks. */
    badge: (count: number) => plural(count, "open task", "open tasks"),
  },

  engine: {
    ready: "Engine Ready",
    unavailable: "Engine Unavailable",
    version: (version: string) => `yt-dlp ${version}`,
    notDetected: "not detected",
  },

  common: {
    refresh: "Refresh",
    retry: "Retry",
    cancel: "Cancel",
    remove: "Remove",
    reload: "Reload",
    dismiss: "Dismiss",
    unknownError: "Something went wrong.",
    unknownSite: "Unknown site",
    loading: "Loading…",
  },

  status: {
    waiting: "Queued",
    extracting: "Preparing",
    downloading: "Downloading",
    merging: "Merging",
    completed: "Completed",
    failed: "Failed",
    cancelled: "Cancelled",
    interrupted: "Interrupted",
  },

  download: {
    title: "Download",
    description: "Paste a video link to see the formats this video actually offers.",
    urlLabel: "Video link",
    urlPlaceholder: "https://...",
    paste: "Paste",
    prepare: "Prepare",
    preparing: "Preparing",
    progress: "Asking yt-dlp which formats are available…",
    errorTitle: "Couldn't prepare this link",
    dismissError: "Dismiss",

    errors: {
      emptyUrl: "Paste a video link first.",
      invalidUrl: "That doesn't look like a link. Only http and https addresses are supported.",
      emptyClipboard: "The clipboard is empty.",
      clipboardBlocked: "Can't read the clipboard. Press ⌘V in the field instead.",
      settingsNotReady: "Settings are still loading. Try again in a moment.",
    },

    engineWarning: {
      title: "Download engine unavailable",
      before: "yt-dlp wasn't found. Check the engine status in",
      link: "Settings",
      after: ".",
    },

    empty: {
      title: "Ready when you are",
      description:
        "Works with YouTube, Bilibili, X and any other site yt-dlp supports. Only formats that actually exist for this video are listed.",
    },

    noFormats: {
      title: "No downloadable formats",
      description: "This video may be region-locked or no longer available. Try another link.",
    },

    selected: {
      label: "Selected",
      none: "No format selected",
      hint: "Pick a format on the left",
      estimatedSize: "Estimated size",
      saveTo: "Save to",
      changeSettings: "Download settings",
      start: "Start download",
      starting: "Adding to Queue",
    },

    formats: {
      recommended: "Recommended",
      recommendedHint: "Best picture and audio, picked for you",
      video: "Video",
      videoHint: "Includes audio, plays right away",
      videoOnly: "Video only",
      videoOnlyHint: "No audio, for editing",
      audioOnly: "Audio",
      audioOnlyHint: "Saved as an audio file",
      mergeBadge: "Merges",
      count: (count: number) => `${plural(count, "format", "formats")} available`,
    },
  },

  tasks: {
    title: "Tasks",
    summary: {
      activeAndQueued: (active: number, queued: number) =>
        `${plural(active, "active task", "active tasks")} · ${plural(queued, "task", "tasks")} queued`,
      active: (active: number) => plural(active, "active task", "active tasks"),
      queued: (queued: number) => `${plural(queued, "task", "tasks")} queued`,
      idle: "Queue is idle",
    },
    notice: {
      title: "Added to Queue",
      body: "The task is queued. Live progress shows up below.",
      dismiss: "Got it",
    },
    loadError: "Couldn't load tasks",
    loading: "Reading tasks…",
    empty: {
      title: "No downloads yet",
      description: "Paste a link on the Download page and pick a format.",
      action: "Go to Download",
    },
    sections: {
      active: "In progress",
      attention: "Needs attention",
      recent: "Completed recently",
      viewAll: "View all history",
    },
    idle: {
      title: "Queue is clear",
      description: "Every task has finished. Add another download whenever you like.",
      action: "Download something new",
    },
    card: {
      noThumbnail: "No thumbnail",
      waiting: "Waiting to download",
      preparing: "Preparing the link…",
      merging: "Merging audio and video…",
      eta: (remaining: string) => `${remaining} left`,
      fileReady: "File is ready",
      actions: {
        cancel: "Cancel",
        retry: "Retry",
        open: "Open",
        reveal: "Reveal in Finder",
        downloadAgain: "Download again",
        remove: "Remove from list",
      },
      removeDialog: {
        title: "Remove this download?",
        description:
          "Only the entry is removed. Downloaded files stay where they are. This can't be undone.",
        confirm: "Remove",
      },
    },
  },

  history: {
    title: "History",
    description: "Finished downloads. Removing an entry never deletes the file.",
    searchPlaceholder: "Search titles and links",
    searchLabel: "Search history",
    clearSearch: "Clear search",
    count: (count: number) => `${plural(count, "entry", "entries")}`,
    all: "All",
    loadError: "Couldn't load history",
    loading: "Reading history…",
    empty: {
      searchTitle: "No matching entries",
      searchDescription: "Try a different keyword, or clear the search.",
      title: "No history yet",
      description: "Completed, failed and cancelled downloads are archived here.",
    },
    noMatch: {
      title: "Nothing matches this filter",
      description: "Try a different status.",
    },
  },

  settings: {
    title: "Settings",
    description: "Changes save automatically and apply to new downloads.",
    loadingDescription: "Reading your local configuration…",
    loading: "Loading settings…",
    saving: "Saving…",
    saved: (when: string) => `Saved ${when}`,
    saveError: "Couldn't save settings",

    sections: {
      download: {
        title: "Download",
        description: "Defaults for new downloads. You can override them on the Download page.",
      },
      storage: {
        title: "Storage",
        description: "Where finished files are written.",
      },
      engine: {
        title: "Engine",
        description: "VideoFlow relies on yt-dlp and FFmpeg to prepare and merge files.",
      },
      application: {
        title: "Application",
        description: "Notifications, licenses and privacy.",
      },
    },

    rows: {
      folder: {
        title: "Download folder",
        description: "Every file goes here unless you pick another folder per download.",
      },
      chooseFolder: "Choose…",
      folderPickerTitle: "Choose download folder",
      container: {
        title: "Container",
        description: "How audio and video are packaged when they get merged.",
      },
      quality: {
        title: "Preferred quality",
        description: "Pre-selected after preparing. Falls back to the best available.",
      },
      concurrency: {
        title: "Concurrent downloads",
        description: "How many tasks run at once. Higher values use more bandwidth.",
      },
      notifications: {
        title: "Notify when finished",
        description: "Sends a system notification after merging or converting.",
        label: "Notify when a download completes",
      },
      licenses: {
        title: "Third-party licenses",
        description:
          "FFmpeg, LAME and libopus are LGPL and BSD components. Full licenses and a source offer ship with the app.",
        action: "View",
      },
    },

    containers: {
      mp4: "MP4 (most compatible)",
      mkv: "MKV (original codecs)",
      original: "Original (no remux)",
    },

    qualities: {
      best: "Best available",
    },

    concurrency: (count: number) => plural(count, "task", "tasks"),

    engine: {
      recheck: "Recheck",
      notFound: "Not found",
      ffmpegNotFound: "Not found — merging and audio conversion unavailable",
      notReadyTitle: "Engine not ready",
      notReadyBody:
        "Without yt-dlp nothing can be prepared or downloaded. The released app bundles its engine — reinstall if it's missing. In development you can point VIDEOFLOW_YTDLP_PATH at a custom binary.",
    },

    about: {
      title: "About",
      version: "VideoFlow 0.1.0 · Runs entirely on this Mac, collects nothing",
      privacy:
        "History lives in a local SQLite database and never leaves this Mac. Cookies and credentials are filtered out of logs.",
      legal:
        "No DRM or paywall bypassing. Only download content you have the right to keep, and respect each site's terms of service.",
    },
  },
};

export type Dictionary = typeof en;
