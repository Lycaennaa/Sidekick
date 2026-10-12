# Changelog

User-visible changes are listed here. No public release tag exists yet.

## Unreleased

### Added

- Select WebP or AVIF for clipboard conversions and screenshot output.
- Window-aware screenshot selection, aspect-ratio guides, and pixel inspection.
- GitHub Actions CI and a maintainer-dispatched release workflow for ZIP and DMG assets.
- Build-time ClearURLs rules fetching with bundled, offline runtime processing.

### Fixed

- Reuse captured clipboard representations for rollback and preserve newer artifact ownership during async restoration.