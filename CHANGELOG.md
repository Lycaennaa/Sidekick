# Changelog

User-visible changes are listed here. No public release tag exists yet.

## Unreleased

### Added

- Select WebP or AVIF for clipboard conversions and screenshot output when the OS provides an AVIF encoder.
- Clipboard image toasts distinguish advertised types from encoded image formats.
- Window-aware screenshot selection, aspect-ratio guides, and pixel inspection.
- Exclude elevated, display-covering windows from full-display screenshots to avoid screen-wide overlays.
- Capture an individual window directly to the clipboard.
- Exclude fully occluded windows and system UI from window capture, and require Screen Recording access.
- GitHub Actions CI and a maintainer-dispatched release workflow for ZIP and DMG assets.
- Build-time ClearURLs rules fetching with bundled, offline runtime processing.
- Add a Finder context-menu command that opens Sidekick to create a zero-byte file after the user enters a name, without replacing existing items.
- Copying folders no longer triggers automatic conversion; pending captures retry after output-format changes, and unreadable images report an error.

- Added recursive macOS metadata cleanup for enrolled folders on local internal or external physical disks and FUSE mounts, including network-backed FUSE; mounted disk images and other non-FUSE virtual or network volumes are rejected.

### Fixed

- Use remount-stable source identities for FUSE volumes, migrating saved roots only when their UUID still matches the mounted volume.
- Hide AVIF output on macOS versions without an ImageIO AVIF encoder and use WebP as the effective output format.
- Keep cleanup folder enrollment responsive while revalidating the selected volume before adding it.
- Keep cleanup enrollment and cleanup decision prompts nonmodal while preserving the permanent-delete confirmation.

- Keep automatic clipboard image conversion running when its clipboard-content toast appears.
- Put converted WebP and AVIF image data on the clipboard alongside the output file reference.
- Keep automatically converted Sidekick screenshots file-backed on the clipboard.
- Combine regular clipboard-image and screenshot copy feedback with successful automatic conversion into one toast; suppress duplicate screenshot clipboard toasts.

- Prevent selection panels and elevated display-covering overlays from hiding all window-capture candidates, while preserving ordinary window occlusion and partial coverage on adjacent displays.
- Reuse captured clipboard representations for rollback and preserve newer artifact ownership during async restoration.
- Focus the filename field when the Finder prompt opens.
- Avoid unnecessary occlusion work for windows with non-overlapping frames during window capture.
- Avoid offering screenshot windows missing from a partial on-screen enumeration.
- Exclude Sidekick's fullscreen screenshot overlay from window capture.
- Reuse enumerated window objects and display geometry during window capture to avoid redundant system queries.

- Keep window capture active while retrying empty window inventories twice.
- Harden macOS cleanup against symlink-swapped paths, enforce stability for manual actions, preserve companion-file events, and correct cleanup settings feedback.
- Exclude the known macOS Cryptex mount literal from release privacy checks without relaxing other path checks.