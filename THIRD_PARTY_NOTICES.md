# Third-Party Notices

This file lists third-party code and data included in Sidekick, plus optional runtime downloads.
Required local license and notice text for included components is provided beside the component or under
`LICENSES/`.

## TiktokenSwiftPort

- Component: Swift port of tiktoken `o200k_base`
- Included in: `TiktokenSwiftPort/`
- Upstream reference: tiktoken 0.14.0
- Source: https://github.com/openai/tiktoken/tree/0.14.0
- License: MIT
- Copyright: OpenAI and Shantanu Jain
- License text: `TiktokenSwiftPort/LICENSE`
- License URL: https://github.com/openai/tiktoken/blob/0.14.0/LICENSE

## libwebp-Xcode wrapper

- Version: 1.5.0
- Revision: 0d60654eeefd5d7d2bef3835804892c40225e8b2
- Source: https://github.com/SDWebImage/libwebp-Xcode/tree/0d60654eeefd5d7d2bef3835804892c40225e8b2
- Wrapper license: No separate license file was present at this revision.
- Underlying library: libwebp
- Underlying revision: a4d7a715337ded4451fec90ff8ce79728e04126c
- Underlying license: BSD-3-Clause-style
- License text: `LICENSES/libwebp-COPYING`
- License URL: https://github.com/webmproject/libwebp/blob/a4d7a715337ded4451fec90ff8ce79728e04126c/COPYING
- Used for: WebP encoding

## swift-markdown

- Version: 0.8.0
- Revision: 3c6f9523da3a1ec2fd829673e472d95b8097a3b8
- Source: https://github.com/swiftlang/swift-markdown/tree/3c6f9523da3a1ec2fd829673e472d95b8097a3b8
- License: Apache License 2.0
- License text: `LICENSES/swift-markdown-LICENSE.txt`
- Notice text: `LICENSES/swift-markdown-NOTICE.txt`
- License URL: https://github.com/swiftlang/swift-markdown/blob/3c6f9523da3a1ec2fd829673e472d95b8097a3b8/LICENSE.txt
- Notice URL: https://github.com/swiftlang/swift-markdown/blob/3c6f9523da3a1ec2fd829673e472d95b8097a3b8/NOTICE.txt

## swift-cmark

- Version: 0.8.0
- Revision: 924936d0427cb25a61169739a7660230bffa6ea6
- Source: https://github.com/swiftlang/swift-cmark/tree/924936d0427cb25a61169739a7660230bffa6ea6
- License: Multiple licenses; see `COPYING`
- License text: `LICENSES/swift-cmark-COPYING`
- License URL: https://github.com/swiftlang/swift-cmark/blob/924936d0427cb25a61169739a7660230bffa6ea6/COPYING

## ClearURLs rules data

- Included in: the app bundle as `data.min.json`, generated during build.
- Source: https://gitlab.com/ClearURLs/rules/-/raw/master/data.min.json
- Fetch timing: build time only; the app does not request rule updates at runtime.
- Upstream revision: the script fetches the mutable `master` branch. The fetched file’s SHA-256 is printed during the build; rebuilds may contain different rules without source changes.
- License: LGPL-3.0
- License text: `LICENSES/ClearURLs-LICENSE`
- License URL: https://gitlab.com/ClearURLs/rules/-/blob/master/LICENSE

## Streamlink Twitch GUI source reference

Sidekick's Twitch-related implementation was informed by review of Streamlink Twitch GUI source code and adapted/reimplemented for Sidekick. No Streamlink files or assets are included verbatim. This project is not affiliated with or endorsed by Streamlink.

- Source: https://github.com/streamlink/streamlink-twitch-gui/tree/master
- Reference revision: 36684ebfbeca2bfee2dfab2e77546f56a73747a3
- License: MIT
- License text: `LICENSES/streamlink-twitch-gui-LICENSE`
- License URL: https://github.com/streamlink/streamlink-twitch-gui/blob/ae4acc3afbfd7f9f400423bab26c53ddb12c760f/LICENSE
- Relationship: Source-informed implementation/reference only.

## Capso window-capture source reference

Sidekick's window selection and capture behavior was implemented independently, using Capso as a clean-room behavioral reference. No Capso source code or assets are included, and Capso is not a Sidekick dependency.

- Project: [Capso](https://github.com/lzhgus/Capso)
- Reference revision: `6a6b5634c603be0db1ad66e82b6cec4f119296cf`
- License: Business Source License 1.1
- Copyright: © 2026 lzhgus
- License URL: https://github.com/lzhgus/Capso/blob/6a6b5634c603be0db1ad66e82b6cec4f119296cf/LICENSE

## Equilotl source reference

- Reviewed revision: `1a3d96276611c81b99e76428427e730c25aee119`
- Project: [Equilotl](https://github.com/Equicord/Equilotl)
- License: GPL-3.0
- License URL: https://github.com/Equicord/Equilotl/blob/1a3d96276611c81b99e76428427e730c25aee119/LICENSE
- Relationship: High-level install/restore behavior reference only. No Equilotl code or assets are included or copied. Equilotl injects Equicord into discord.

## Equicord optional runtime release and source build

- Project: [Equicord](https://github.com/Equicord/Equicord)
- License: GPL-3.0-or-later
- License URL: https://github.com/Equicord/Equicord/blob/main/LICENSE
- Distribution: Not included in Sidekick builds. After explicit user confirmation, Sidekick downloads the prebuilt release or shallow-clones source and builds `dist/desktop.asar`. The source checkout and dependencies remain in the user's Application Support folder.
