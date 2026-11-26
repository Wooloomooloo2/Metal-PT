// Game title matching (spec §4.D): Steam ID first, else the normalised title via `game_aliases`, else a new game.

// Trademark-style signs, removed before Unicode normalisation (NFKC would turn ™ into "TM").
const MARKS = /[®™©℠]/gu;
// Apostrophes vanish rather than split words ("Baldur's" -> "baldurs").
const APOSTROPHES = /['’‘ʼ`´]/gu;

/**
 * Lowercase, punctuation and ® ™ removed, spaces collapsed: the `game_aliases.alias_norm` form.
 * Letters and digits of any script are kept (with their accents); everything else is dropped, and white space runs
 * become one space. Full-width forms fold to ASCII (NFKC).
 */
export function normalizeTitle(s: string): string {
  return s
    .replace(MARKS, "")
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, "")
    .replace(/\s+/gu, " ")
    .trim();
}

/**
 * A URL slug: lowercase ASCII letters and digits in runs joined by "-" (accents stripped, apostrophes dropped,
 * everything else a separator). Empty when nothing is left (a title in a non-Latin script): the caller picks a
 * fallback and makes slugs unique.
 */
export function slugify(s: string): string {
  return s
    .replace(MARKS, "")
    .replace(APOSTROPHES, "")
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}
