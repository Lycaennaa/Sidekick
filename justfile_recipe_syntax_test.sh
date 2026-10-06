#!/bin/sh
set -eu

justfile=${1:-justfile}
recipes=$(just --justfile "$justfile" --summary)
for recipe in $recipes; do
    commands=$(just --justfile "$justfile" --dry-run "$recipe")
    if ! printf '%s\n' "$commands" | sh -n; then
        printf '%s: shell syntax check failed\n' "$recipe" >&2
        exit 1
    fi
done