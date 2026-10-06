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

- Capture a display and copy it to the pasteboard, with cursor display options.
- Select a region or window, use aspect-ratio guides, and inspect pixel color values and selection dimensions.

## Audio and volume

- Show microphone activity, device name, and available app/input-gain details without recording audio.
- Mute supported output devices temporarily or on a schedule, then restore volume early or cancel the schedule.

## Twitch

- Optionally receive notifications when followed channels go live. Sidekick does not open or play streams.
- Enter a Twitch OAuth token with the `user:read:follows` scope, or set a public client ID in Tools for built-in sign-in.
- Manage notifications and send a test notification from the Tools window.

[ClearURLs rules](https://gitlab.com/ClearURLs/rules) are fetched at build time and bundled with the app. The installed app does not fetch rule updates. See [PRIVACY.md](PRIVACY.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
