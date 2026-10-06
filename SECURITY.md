# Security

## Security-sensitive behavior

Sidekick runs without App Sandbox and has the signed-in user’s normal access to clipboard data and referenced local files. Screenshot capture is user initiated. Twitch tokens are stored in Keychain and sent to Twitch when the optional notification feature is used. Source builds fetch a public ClearURLs data file from GitLab; the installed app uses the bundled file and does not request rule updates.

## Safe use

Download releases from this repository and verify the GitHub-provided asset digest before opening them. Keep sensitive material out of the clipboard while clipboard previews are enabled. Grant screen-capture permission only if you use screenshot tools. Enable Twitch notifications only if desired, and remove/revoke the OAuth token when no longer needed.

## Limitations

Release artifacts are ad-hoc signed, not Developer ID signed or notarized. Sidekick has no automatic updater; users must check this repository for updates. ClearURLs data is fetched from a mutable upstream `master` branch at build time.