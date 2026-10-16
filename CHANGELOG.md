# Changelog

User-visible changes are listed here. No public release tag exists yet.

## Unreleased

### Added

- Select WebP or AVIF for clipboard conversions and screenshot output.
- Window-aware screenshot selection, aspect-ratio guides, and pixel inspection.
- Capture an individual window directly to the clipboard.
- Exclude fully occluded windows and system UI from window capture, and require Screen Recording access.
- GitHub Actions CI and a maintainer-dispatched release workflow for ZIP and DMG assets.
- Build-time ClearURLs rules fetching with bundled, offline runtime processing.
- Add a Finder context-menu command that opens Sidekick to create a zero-byte file after the user enters a name, without replacing existing items.

### Fixed

- Reuse captured clipboard representations for rollback and preserve newer artifact ownership during async restoration.
- Focus the filename field when the Finder prompt opens.
- Avoid unnecessary occlusion work for windows with non-overlapping frames during window capture.
- Avoid offering screenshot windows missing from a partial on-screen enumeration.
- Exclude Sidekick's fullscreen screenshot overlay from window capture.
- Reuse enumerated window objects and display geometry during window capture to avoid redundant system queries.

- Keep window capture active while retrying empty window inventories twice.