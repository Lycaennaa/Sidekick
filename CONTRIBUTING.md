# Contributing

## Changes

1. Open or update a GitHub Issue for a bug or proposed change.
2. Keep changes focused and include tests for behavior changes.
3. Run `just check`; run `just ci` before requesting review.
4. Update user and developer documentation when behavior or commands change.
5. Open a pull request with the reason for the change, observable behavior, and validation results.

`project.yml` is the Xcode project source of truth. `Sidekick.xcodeproj/project.pbxproj` is generated and ignored; run `just generate-project` before opening or building locally. Do not hand-edit the generated file.

## AI-use disclosure

Every pull request must state whether AI was used. If used, list each tool and model, what it assisted with, and the reasoning level when known. If no AI was used, state “None.”

## Twitch client ID

The app checks the ID saved in Tools first, then `TwitchOAuthClientID` in the app Info.plist. The build-time default in `project.yml` is `none`; no Git hooks or release workflow inject or rewrite client IDs.

Never commit Twitch access tokens, signing certificates/private keys, or machine-specific build settings.