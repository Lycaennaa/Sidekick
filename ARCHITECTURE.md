# Architecture

## Application

Sidekick is a macOS menu bar app. `AppDelegate` composes feature controllers and the status menu; feature-specific UI and orchestration live under `Sidekick/`. Clipboard, screenshot, microphone, volume, and Twitch code use AppKit, CoreAudio, ScreenCaptureKit, and the corresponding macOS APIs.

Pure transformations stay separate from platform I/O. Clipboard URL cleaning compiles a `ClearURLsRuleSet` from the bundled `data.min.json` resource, then cleans captured clipboard values locally. Screenshot results are copied to the pasteboard. Twitch credentials are stored in Keychain; preferences use `UserDefaults`.

The Discord installer defaults to the prebuilt [Equicord](https://github.com/Equicord/Equicord) release. Its explicit dev-build path shallow-clones Equicord `main`, enables UserpluginInstaller by default unless retained source explicitly overrides it, runs `pnpm install --frozen-lockfile --prefer-offline` and `pnpm build --dev`, then uses the same ASAR validator and reversible app patcher. The original Discord archive is saved as `_app.asar`, which Equicord's runtime requires; older Sidekick `.sidekick-original` backups are migrated explicitly. The clone, dependencies, and built archive remain in the user's Application Support folder for future edits; Sidekick does not package GPL code. The [Equicord patcher](https://github.com/Equicord/Equilotl) (GPL-3.0) is a high-level reference only; no source or assets were copied. Equicord is GPL-3.0-or-later. Discord must be quit; restore refuses to overwrite a changed archive. The 512 MiB limit bounds accepted artifact size, not transfer time or hard runtime.

## Build inputs

`project.yml` is the XcodeGen source of truth; generated `Sidekick.xcodeproj` data is ignored except for the checked-in SwiftPM `Package.resolved` lockfile. Swift packages are pinned by that lockfile. ClearURLs rules are fetched from the upstream mutable `master` branch during project preparation and included as a resource. Twitch OAuth resolves client ID from the app's UserDefaults override, then the app Info.plist; the build-time default is `none`.

## Tests

`SidekickTests/` contains unit and platform integration tests. The ClearURLs command-level success test uses a real named `NSPasteboard` and the default production rule loader. GitHub CI runs SwiftLint, tests, and a Release build on macOS.
