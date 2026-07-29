# Local patches to Highlightr

Vendored from https://github.com/raspu/Highlightr at 2.3.0
(05e7fcc63b33925cd0c1faaa205cdd5681e7bbef). Upstream layout kept
(`src/classes`, `src/assets`); `Example/` and repo furniture dropped.

## Why vendored

`Highlightr()` reads its resources (highlight.min.js + theme CSS) through
SwiftPM's generated `Bundle.module`. For `swift build` products — which is how
scripts/make_app.sh builds the shipped .app — that generated accessor checks
exactly two paths:

1. `Bundle.main.bundleURL/Highlightr_Highlightr.bundle` — the root of
   Belfry.app, where a signed bundle can't carry unsealed content, and where
   make_app.sh could never legally put it; and
2. the absolute `.build/…` path of the machine that built the release (a GitHub
   Actions runner), which doesn't exist anywhere else.

Both miss, and the accessor's `guard` calls `fatalError` — so the packaged app
crashed outright the first time the file pane tried to syntax-highlight a
preview (double-click/Quick Look on any text file). Dev builds never saw it
because a bare `.build/…/Belfry` binary's `bundleURL` *is* the build directory,
where the bundle sits.

## The patch

`src/classes/Highlightr.swift`: `init?` no longer touches `Bundle.module`
first. A `resourceBundle` finder probes, in order, without trapping:

- `Bundle.main.resourceURL` — Contents/Resources of the assembled .app
  (make_app.sh copies the bundle there), and the app-root Resources of the
  Xcode-built iOS app;
- `Bundle(for: Highlightr.self).resourceURL` — framework embedding;
- `Bundle.main.bundleURL` — bare `swift build` binaries in dev.

Only if all three miss does it fall back to `Bundle.module` (correct under
Xcode builds, and by then a trap means the resources genuinely aren't shipped).
