# Security

## Security-sensitive behavior

Sidekick’s main app runs without App Sandbox and has the signed-in user’s ordinary access to local files. The Finder Sync extension remains sandboxed with a temporary absolute-path read-only exception to resolve Finder targets. The local request displays the target path, and the app creates no file until the user confirms. Screenshot capture is user initiated. Twitch tokens are stored in Keychain and sent to Twitch when the optional notification feature is used. Source builds fetch a public ClearURLs data file from GitLab; the installed app uses the bundled file and does not request rule updates.

The Finder Sync extension only offers its command inside configured monitored roots and forwards the target to Sidekick. The app creates the requested name only after user confirmation, using coordinated exclusive creation so existing items are never replaced; cancel creates no file.

[Equicord](https://github.com/Equicord/Equicord) is third-party code downloaded only after the user requests installation. It runs inside Discord with Discord's access to the signed-in user's data. Equicord is not affiliated with Discord or Sidekick.

The optional source build runs Git and pnpm dependency/build scripts with the user's permissions and without a sandbox. It downloads the shallow Equicord checkout and dependencies only after confirmation, keeps them in Application Support, and does not overwrite them on rebuild. Review the source and lockfile before building; upstream scripts may access local files or make network requests.

Source dev builds default-enable Equicord's UserpluginInstaller for profiles without an existing preference. Userplugins are unmoderated third-party code running inside Discord with access to the signed-in user's data; install only from developers you trust.

The app picker accepts custom `.app` bundles with `Contents/Resources/app.asar`, not only official Discord channels. Equicord executes inside the selected app with that process's permissions. Select custom targets only when you trust their origin and compatibility.

Replacing `app.asar` may invalidate Discord's code signature or prevent launch, and Discord updates may overwrite the patch. Sidekick refuses to restore its backup if the current archive changed, avoiding loss of a later Discord update.

Equicord resolves Discord's original package through `Contents/Resources/_app.asar/package.json`. New installs use that required filename. Older Sidekick installs are repaired by copying the saved archive to `_app.asar` while retaining the legacy backup; restoring Discord removes both copies after the original is in place.

The installer checks archive structure and limits downloads to GitHub-hosted release assets, but does not verify a separate upstream signature or digest for Equicord.

## Safe use

Download releases from this repository and verify the GitHub-provided asset digest before opening them. Keep sensitive material out of the clipboard while clipboard previews are enabled. Grant screen-capture permission only if you use screenshot tools. Enable Twitch notifications only if desired, and remove/revoke the OAuth token when no longer needed.

## Limitations

Release artifacts are ad-hoc signed, not Developer ID signed or notarized. Sidekick has no automatic updater; users must check this repository for updates. ClearURLs data is fetched from a mutable upstream `master` branch at build time.

Force Quit or a crash during an Equicord operation bypasses Sidekick's graceful cancellation. Git or pnpm may continue after Sidekick exits, and an interrupted app archive install may require manual recovery. Use normal Quit to cancel and wait for the operation to finish.
