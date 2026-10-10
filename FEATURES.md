# Features

Sidekick runs in the macOS menu bar and requires macOS 15 or later.

## Clipboard

- Show copied text, source app, and character, word, and token counts in clipboard toasts.
- Preview copied images and files; open copied images with the selected application.
- Convert a clipboard image to WebP at 75% quality.
- Remove Markdown formatting or known tracking parameters from the clipboard.
- Keep YouTube playlist parameters while cleaning URLs.
- Pause clipboard toasts, change their display duration, and exclude apps from toast presentation.

## Screenshots

- Capture a display and copy it as PNG or WebP, with cursor display options.
- Select a region or window, use aspect-ratio guides, and inspect pixel color values and selection dimensions.

## Audio and volume

- Show microphone activity, device name, and available app/input-gain details without recording audio.
- Mute supported output devices temporarily or on a schedule, then restore volume early or cancel the schedule.

## Twitch

- Optionally receive notifications when followed channels go live. Sidekick does not open or play streams.
- Enter a Twitch OAuth token with the `user:read:follows` scope, or set a public client ID in Tools for built-in sign-in.
- Manage notifications and send a test notification from the Tools window.

## Discord Client Mod Injection

- The Tools dropdown lists installed Discord, PTB, Canary, and Development apps. “Choose Other” accepts any macOS app bundle containing `Contents/Resources/app.asar`. The default install uses the prebuilt [Equicord](https://github.com/Equicord/Equicord) release. A separate **Install Dev Version from Source** action shallow-clones Equicord, runs `pnpm build --dev`, and retains source/dependencies for edits and rebuilds. Dev builds default-enable UserpluginInstaller for new profiles; it installs unmoderated third-party plugins. Both modes can restore the selected app's original archive; client mods may violate Discord's terms, invalidate the app signature, or affect an account.

[ClearURLs rules](https://gitlab.com/ClearURLs/rules) are fetched at build time and bundled with the app. The installed app does not fetch rule updates. See [PRIVACY.md](PRIVACY.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
