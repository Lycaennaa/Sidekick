# Architecture

## Application

Sidekick is a macOS menu bar app. `AppDelegate` composes feature controllers and the status menu; feature-specific UI and orchestration live under `Sidekick/`. Clipboard, screenshot, microphone, volume, and Twitch code use AppKit, CoreAudio, ScreenCaptureKit, and the corresponding macOS APIs.

Pure transformations stay separate from platform I/O. Clipboard URL cleaning compiles a `ClearURLsRuleSet` from the bundled `data.min.json` resource, then cleans captured clipboard values locally. Screenshot results are copied to the pasteboard. Twitch credentials are stored in Keychain; preferences use `UserDefaults`.

## Build inputs

`project.yml` is the XcodeGen source of truth; `Sidekick.xcodeproj` is generated. Swift packages are pinned by the checked-in `Package.resolved` file. ClearURLs rules are fetched from the upstream mutable `master` branch during project preparation and included as a resource. Twitch OAuth resolves client ID from the app's UserDefaults override, then the app Info.plist; the build-time default is `none`.

## Tests

`SidekickTests/` contains unit and platform integration tests. The ClearURLs command-level success test uses a real named `NSPasteboard` and the default production rule loader. GitHub CI runs SwiftLint, tests, and a Release build on macOS.