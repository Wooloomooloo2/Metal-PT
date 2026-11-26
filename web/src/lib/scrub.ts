// Server-side privacy re-scrub (spec §4.C.5) of every text field the site stores. A port of `Privacy.scrubPaths`
// (Sources/MPTCore/Bench/Privacy.swift) plus host-name patterns: the app scrubs this Mac's own host names, which
// the server cannot know, so here the common macOS naming forms are caught instead ("Mark's MacBook Pro",
// "Marks-MacBook-Pro-2.local", "anything.local").

/** `…/drive_c/users/<name>` (or a relative `drive_c/users/<name>`) -> `…/drive_c/users/~`. */
const WINE_PREFIX = /((?<![A-Za-z0-9_])drive_c\/users\/)[^/]+/gi;
/** `/Users/<name>` (any case), but not the `users/<name>` folder inside a Wine prefix. */
const HOME = /(?<!drive_c)\/users\/[^/]+/gi;
/** Wine `X:\Users\<name>` -> `X:\Users\~`. */
const WINE_HOME = /([A-Za-z]):\\[Uu][Ss][Ee][Rr][Ss]\\[^\\]+/g;

/** Home paths only, exactly as the app's `Privacy.scrubPaths`. */
export function scrubPaths(text: string): string {
  return text.replace(WINE_PREFIX, "$1~").replace(HOME, "~").replace(WINE_HOME, "$1:\\Users\\~");
}

const MODELS = String.raw`(?:MacBook(?:[ -](?:Pro|Air))?|iMac(?:[ -]Pro)?|Mac[ -]mini|Mac[ -]Studio|Mac[ -]Pro)`;
/** The computer name: "Mark's MacBook Pro", "Jo’s Mac mini (2)". */
const COMPUTER_NAME = new RegExp(String.raw`[\p{L}\p{N}._-]+['’]s ${MODELS}(?: \(\d+\))?`, "giu");
/** The local host name: "Marks-MacBook-Pro", "Marks-MacBook-Pro-2", with or without ".local". */
const LOCAL_HOST_NAME = new RegExp(
  String.raw`(?<![\p{L}\p{N}-])[\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*?-${MODELS.replace(/\[ -\]/g, "-")}(?:-\d+)?(?:\.local)?(?![\p{L}\p{N}-])`,
  "giu",
);
/** Any Bonjour name: "studio.local". */
const DOT_LOCAL = /(?<![\p{L}\p{N}.-])[\p{L}\p{N}-]+\.local(?![\p{L}\p{N}-])/giu;

export const HOST = "<host>";

/** Home paths plus host-name patterns (replaced by `<host>`). For every free-text field. */
export function scrub(text: string): string {
  return scrubPaths(text).replace(COMPUTER_NAME, HOST).replace(LOCAL_HOST_NAME, HOST).replace(DOT_LOCAL, HOST);
}
