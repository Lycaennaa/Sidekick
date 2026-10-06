#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
URL=https://gitlab.com/ClearURLs/rules/-/raw/master/data.min.json
OUTPUT=$ROOT/build/generated/Resources/data.min.json
MODE=${1:---if-missing}

case "$MODE" in
    --if-missing|--force) ;;
    *)
        printf 'usage: %s [--if-missing|--force]\n' "$0" >&2
        exit 2
        ;;
esac

validate_rules() {
    python3 - "$1" <<'PY'
import json
import sys
from pathlib import Path

try:
    document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid ClearURLs rules JSON: {error}")

providers = document.get("providers") if isinstance(document, dict) else None
if not isinstance(providers, dict) or not providers:
    raise SystemExit("ClearURLs rules must contain a non-empty providers object")
for name, provider in providers.items():
    if not isinstance(name, str) or not isinstance(provider, dict):
        raise SystemExit("ClearURLs provider entries must be named objects")
    if not isinstance(provider.get("urlPattern"), str):
        raise SystemExit(f"ClearURLs provider {name!r} has no string urlPattern")
PY
}

if [ "$MODE" = --if-missing ] && [ -s "$OUTPUT" ]; then
    if validate_rules "$OUTPUT"; then
        printf 'Using cached ClearURLs rules: '
        shasum -a 256 "$OUTPUT"
        exit 0
    fi
fi

mkdir -p "$(dirname -- "$OUTPUT")"
temporary=$(mktemp "$OUTPUT.tmp.XXXXXX")
cleanup() {
    if [ -n "$temporary" ]; then
        rm -f "$temporary"
    fi
}
trap cleanup EXIT HUP INT TERM

printf 'Fetching ClearURLs rules from %s\n' "$URL"
curl --fail --location --silent --show-error \
    --connect-timeout 15 --max-time 120 --max-filesize 33554432 \
    --proto '=https' --proto-redir '=https' \
    --retry 2 --retry-delay 1 \
    "$URL" --output "$temporary"
validate_rules "$temporary"
mv "$temporary" "$OUTPUT"
temporary=
printf 'Fetched ClearURLs rules SHA-256: '
shasum -a 256 "$OUTPUT"