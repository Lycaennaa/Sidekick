# Features

Sidekick runs in the macOS menu bar and requires macOS 15 or later.

## Finder

- Create an empty file by right-clicking a folder or Finder background. Sidekick prompts for a filename and creates it in the target folder; cancel creates nothing.

## Clipboard

- Show copied text, source app, and character, word, and token counts in clipboard toasts.
- Preview copied images and files; open copied images with the selected application.
- Convert a clipboard image to the selected WebP or AVIF format.
- Automatically convert new clipboard images to the selected format when enabled.
- Remove Markdown formatting or known tracking parameters from the clipboard.
- Keep YouTube playlist parameters while cleaning URLs.
- Pause clipboard toasts, change their display duration, and exclude apps from toast presentation.

## Screenshots

- Capture a display, save it as WebP or AVIF, and copy it as PNG or the selected format.
- Capture an individual window directly to the clipboard, or select a region; use aspect-ratio guides and inspect pixel colors and selection dimensions. Full-display captures omit windows above the normal layer that cover the selected display; color-table and normal-layer effects are unaffected.

## Audio and volume

- Show microphone activity, device name, and available app/input-gain details without recording audio.
- Mute supported output devices temporarily or on a schedule, then restore volume early or cancel the schedule.

## Twitch

- Optionally receive notifications when followed channels go live. Sidekick does not open or play streams.
- Enter a Twitch OAuth token with the `user:read:follows` scope, or set a public client ID in Tools for built-in sign-in.
- Manage notifications and send a test notification from the Tools window.

## Discord Client Mod Injection

- The Tools dropdown lists installed Discord, PTB, Canary, and Development apps. “Choose Other” accepts any macOS app bundle containing `Contents/Resources/app.asar`. The default install uses the prebuilt [Equicord](https://github.com/Equicord/Equicord) release. A separate **Install Dev Version from Source** action shallow-clones Equicord, runs `pnpm build --dev`, and retains source/dependencies for edits and rebuilds. Dev builds default-enable UserpluginInstaller for new profiles; it installs unmoderated third-party plugins. Both modes can restore the selected app's original archive; client mods may violate Discord's terms, invalidate the app signature, or affect an account.

## macOS metadata cleanup

- Enroll folders and external drives for recursive cleanup of `.DS_Store`, verified AppleDouble `._*` sidecars, and exact `.AppleDouble` / `__MACOSX` directories.
- Scans and monitors enrolled roots while Sidekick is open, skips symlinks, recognized package folders, and nested volumes, and waits for 30 seconds without observed size or modification-time changes before acting. Confirmed manual removals are skipped unless monitoring has observed the full quiet period.
- Folder roots remain bound to their original volume; a different volume mounted at the same path stays inactive until explicitly enrolled.
- Cleanup runs locally; ZIP files are not rewritten. Trash and permanent removal stay anchored to opened directories so symlink swaps cannot redirect actions outside the selected root. Preview and removal modes are configurable, with permanent deletion as the automatic default; Trash failures are reported without permanent fallback.
- Sends completion notifications and stores up to 50 run summaries in local history.

[ClearURLs rules](https://gitlab.com/ClearURLs/rules) are fetched at build time and bundled with the app. The installed app does not fetch rule updates. See [PRIVACY.md](PRIVACY.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
