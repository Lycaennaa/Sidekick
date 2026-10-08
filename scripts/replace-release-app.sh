#!/bin/sh
set -eu

source_app=${1:?source app bundle is required}
destination=${2:?destination app bundle is required}
parent=${destination%/*}
if [ "$parent" = "$destination" ]; then parent=.; elif [ -z "$parent" ]; then parent=/; fi
name=${destination##*/}
lock="$parent/.$name.replace.lock"
if [ ! -d "$parent" ] || [ ! -d "$source_app" ]; then
    printf 'Source app or destination directory is missing.\n' >&2
    exit 1
fi

case "${3-}" in
    --locked)
        ;;
    '')
        case "$0" in
            /*) script_path=$0 ;;
            *) script_path="$PWD/$0" ;;
        esac
        if ! command -v lockf >/dev/null 2>&1; then
            printf 'The lockf utility is required for safe app replacement.\n' >&2
            exit 1
        fi
        if ! touch "$lock"; then
            printf 'Could not create the release replacement lock at %s.\n' "$lock" >&2
            exit 1
        fi
        exec lockf -k -t 0 "$lock" sh "$script_path" "$source_app" "$destination" --locked
        ;;
    *)
        printf 'Unexpected release replacement arguments.\n' >&2
        exit 1
        ;;
esac

staging="$parent/.$name.staging.$$"
backup="$parent/.$name.previous.$$"
committed=0
transaction_started=0
had_destination=0

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$committed" -eq 0 ] && [ "$transaction_started" -eq 1 ] && [ ! -e "$staging" ] && [ -e "$destination" ]; then
        if [ "$had_destination" -eq 0 ] || [ -e "$backup" ]; then committed=1; fi
    fi
    if [ "$committed" -eq 1 ]; then
        if [ -e "$backup" ] && ! rm -rf "$backup"; then
            printf 'New app installed; previous app remains at %s.\n' "$backup" >&2
            status=1
        else
            status=0
        fi
    elif [ "$status" -ne 0 ] && [ -e "$backup" ] && [ ! -e "$destination" ]; then
        if ! mv "$backup" "$destination"; then
            printf 'Could not restore the previous app bundle from %s.\n' "$backup" >&2
            status=1
        fi
    fi
    if [ -e "$staging" ] && ! rm -rf "$staging"; then
        status=1
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

for stale_stage in "$parent/.$name.staging."*; do
    [ -e "$stale_stage" ] || continue
    rm -rf "$stale_stage"
done
for stale_backup in "$parent/.$name.previous."*; do
    [ -e "$stale_backup" ] || continue
    if [ -e "$destination" ]; then
        if [ ! -d "$destination" ] || [ ! -d "$stale_backup" ]; then
            printf 'Cannot safely recover interrupted replacement at %s.\n' "$destination" >&2
            exit 1
        fi
        rm -rf "$stale_backup"
    else
        if [ ! -d "$stale_backup" ]; then
            printf 'Interrupted app backup is invalid: %s.\n' "$stale_backup" >&2
            exit 1
        fi
        mv "$stale_backup" "$destination"
    fi
done

if [ -e "$staging" ] || [ -e "$backup" ]; then
    printf 'A release staging path already exists.\n' >&2
    exit 1
fi

ditto "$source_app" "$staging"
transaction_started=1
if [ -e "$destination" ]; then
    had_destination=1
    mv "$destination" "$backup"
fi
if ! mv "$staging" "$destination"; then
    if [ -e "$backup" ] && ! mv "$backup" "$destination"; then
        printf 'Could not restore the previous app bundle from %s.\n' "$backup" >&2
    fi
    exit 1
fi
committed=1
if [ -e "$backup" ]; then
    rm -rf "$backup"
fi