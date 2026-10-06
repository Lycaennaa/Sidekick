# Setup

## Install a release

1. Download the ZIP or DMG asset from this repository’s GitHub Releases.
2. Verify its digest against the SHA-256 digest GitHub displays for that asset. For example:

   ```sh
   shasum -a 256 "$HOME/Downloads"/Sidekick-*.zip
   ```

3. Open the DMG and move Sidekick to Applications, or unzip the ZIP and move `Sidekick.app` to Applications.
4. Open Sidekick from Applications.

Releases are ad-hoc signed and not notarized. macOS may warn or block launch. Verify the asset before opening it; do not disable Gatekeeper. If macOS will not allow the app to open, wait for a Developer ID-signed and notarized release.

## Permissions and features

- Approve Screen Recording when macOS requests it to use screenshot capture.
- Clipboard toasts, URL cleaning, Markdown cleaning, WebP conversion, and screenshot processing run locally. Screenshot results are copied to the pasteboard.
- Microphone status reports activity and device/app names; Sidekick does not record audio.
- Twitch notifications are optional. In Tools, save a public Twitch client ID for built-in sign-in or enter a token with `user:read:follows`. Tokens are stored in macOS Keychain and can be removed in Tools.

See [FEATURES.md](FEATURES.md) for the full capability list and [PRIVACY.md](PRIVACY.md) for data handling.