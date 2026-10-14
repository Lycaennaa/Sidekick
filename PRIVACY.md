# Privacy Notice

Last updated: 2026-03-06

Sidekick processes clipboard, screenshot, and microphone-activity data locally. It has no analytics or built-in GitHub release updater. Optional Twitch setup and notifications contact Twitch.

Source builds fetch the ClearURLs rules file from GitLab at build time and Swift package dependencies from their configured sources. The released app contains the fetched rules and does not contact GitLab to update them. Build-time requests do not include clipboard contents.

## Clipboard and screenshots

Sidekick does not intentionally persist raw clipboard text in its own database or files. The macOS pasteboard may retain copied content independently.

Clipboard preview artifacts are stored under:

`~/Library/Application Support/Sidekick/ClipboardPreview`

Artifacts are scheduled for cleanup after approximately 24 hours and are subject to storage limits. Cleanup failures may require manual removal.

Clipboard data may include copied text, image data, file URLs and bounded file contents, pasteboard type metadata, and the name and bundle identifier of the source application. Sidekick processes this data locally for previews, token counts, Markdown and URL cleaning, and image conversion. It does not send clipboard contents to the project developer or an analytics service.

When requested by the user, Sidekick captures a display or window and copies the selected image or pixel values to the macOS pasteboard. It does not save a separate screenshot file.

Excluding an application suppresses clipboard-toast presentation; it does not necessarily disable manual utilities such as image conversion to WebP or AVIF or Markdown cleaning.

## Microphone data

Sidekick reads whether an input device is active and displays the device name and, when available, the names of applications using it. It does not record, transmit, or store microphone audio. The indicator starts with the application and can be hidden or turned off.

## Twitch data

Twitch notifications are optional. When enabled, Sidekick stores the user-provided OAuth token in the macOS Keychain, sends it to Twitch for validation, requests followed-channel and stream information, downloads profile images from HTTPS URLs supplied by Twitch, and creates local notifications containing channel information.

The token requires the `user:read:follows` scope. Remove the token in Sidekick and revoke it through Twitch when it is no longer needed. macOS Notification Center may retain notification content or show it on the lock screen according to system settings.

Twitch-related hosts observed in the implementation are `api.twitch.tv`, `id.twitch.tv`, and `static-cdn.jtvnw.net`. Twitch controls the exact profile-image host returned by its API.

## Discord client modification

Prebuilt installation contacts `api.github.com` and downloads `desktop.asar` from GitHub releases for [Equicord](https://github.com/Equicord/Equicord) only after confirmation. Source builds are separately opt-in: Sidekick shallow-clones Equicord `main` and runs pnpm install/build, which downloads source dependencies from package registries. The checkout, `node_modules`, and built archive are retained at `~/Library/Application Support/Sidekick/EquicordSource` after installation and restore so the user can edit and rebuild. Build scripts are not sandboxed and may make their own network requests as the signed-in user. Equicord is GPL-3.0-or-later and is not bundled in Sidekick's distribution. The original Discord archive is stored as `_app.asar`, the path Equicord's runtime expects.

## Settings and permissions

Preferences are stored in `UserDefaults`; the Twitch OAuth token is stored in the Keychain. Sidekick does not store clipboard text in a database.

Sidekick’s main app runs without App Sandbox and has the signed-in user’s ordinary local-file access. The Finder Sync extension remains sandboxed with a temporary absolute-path read-only exception to resolve Finder targets. macOS privacy protections still apply. The app does not record microphone audio.

Finder file creation is user initiated. The Finder Sync extension sends the target folder to Sidekick through a local URL request. After the user confirms a filename, the app creates that zero-byte file with coordinated exclusive creation; an existing item is never replaced. Cancel creates no file. Sidekick does not send file contents or names to its own or third-party services. If the user chooses a network-mounted folder, the remote filesystem receives the requested filename as part of creating the file.

## Deletion

To remove Sidekick data:

1. Remove the Twitch token in Sidekick and revoke it through Twitch.
2. Delete `~/Library/Application Support/Sidekick/ClipboardPreview`.
3. Remove Sidekick preferences with `defaults delete com.lycaennaa.sidekick` while Sidekick is not running.
4. Remove the application.
