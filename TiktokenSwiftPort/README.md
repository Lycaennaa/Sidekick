# TiktokenSwiftPort

Standalone Swift port of tiktoken's `o200k_base` ordinary encoder.

`O200kBase` bundles the official `o200k_base.tiktoken` mergeable vocabulary, applies
tiktoken's Unicode split pattern, and performs the Rust BPE merge algorithm. `encode(_:)`
and `countTokens(in:)` cover text-to-token IDs/counts. `tokens(in:)` also exposes each
token's source byte range, bytes, and valid UTF-8 text when available.

The port intentionally has no decoder and does not recognize special-token strings;
they are encoded as ordinary text, matching tiktoken's `encode_ordinary` behavior.
The vocabulary is bundled and never downloaded at runtime. The parity test covers 303
vectors generated with tiktoken 0.14.0's `encode_ordinary`, including code and Markdown.

The vocabulary and algorithm are derived from OpenAI's tiktoken project:
https://github.com/openai/tiktoken