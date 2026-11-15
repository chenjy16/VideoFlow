import { en, type Dictionary } from "@/i18n/en";

export type { Dictionary };

/**
 * Locale registry.
 *
 * Only English ships today. To add a language: create `src/i18n/xx.ts` with the
 * same shape (`Dictionary` enforces it), register it here, then let `locale`
 * follow the user's preference. UI code always reads `t`, never a dictionary
 * directly, so switching locales later doesn't touch components.
 */
const DICTIONARIES: Record<string, Dictionary> = { en };

export const SUPPORTED_LOCALES = Object.keys(DICTIONARIES);

export const locale = "en";

/** User-facing strings for the active locale. */
export const t: Dictionary = DICTIONARIES[locale] ?? en;
