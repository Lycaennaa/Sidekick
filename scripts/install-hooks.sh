#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
git -C "$ROOT" config core.hooksPath .githooks
printf 'Git hooks enabled for this checkout.\n'