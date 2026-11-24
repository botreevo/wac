// The repository root, for the TypeScript that still needs a path to start from.
//
// It was the one export of harness/programs.ts anything still used. That file also held a TypeScript copy of how
// programs are found — `tools/wac/programs.wac` is the definition, which `MAP.md` and `programscompile_test.wac` read —
// and the copy had no callers left, so it went (2026-11-11), and with it the drift its own header warned about.

/** The repo root, from this file's location, so a caller's working directory does not matter. */
export const ROOT = decodeURIComponent(new URL("..", import.meta.url).pathname).replace(/\/$/, "");
