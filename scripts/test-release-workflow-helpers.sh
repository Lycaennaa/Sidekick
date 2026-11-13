#!/usr/bin/env bash
set -euo pipefail

repository_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
test_root="$repository_root/.test-tmp"
mkdir -p "$test_root"
test_dir="$(mktemp -d "$test_root/release-workflow.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
trap 'exit 1' HUP INT TERM

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

bin="$test_dir/bin"
mkdir -p "$bin"
cat > "$bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$GH_CALLS"
if [[ "$*" == *"--method POST"* ]]; then
    : > "$GH_TAG_CREATED"
    if [[ "${GH_POST_FAIL:-false}" == true ]]; then
        printf '%s\n' 'gh: transport failed after request submission' >&2
        exit 1
    fi
    exit 0
fi

get_count=0
if [[ -f "$GH_GET_COUNT" ]]; then IFS= read -r get_count < "$GH_GET_COUNT"; fi
get_count=$((get_count + 1))
printf '%s\n' "$get_count" > "$GH_GET_COUNT"

case "$GH_MODE" in
    transient-404)
        if [[ "$get_count" == 1 ]]; then
            printf '%s\n' 'gh: Not Found (HTTP 404)' >&2
            exit 1
        fi
        ;;
    persistent-404)
        printf '%s\n' 'gh: Not Found (HTTP 404)' >&2
        exit 1
        ;;
    forbidden)
        printf '%s\n' 'gh: Forbidden (HTTP 403)' >&2
        exit 1
        ;;
    after-post)
        if [[ ! -f "$GH_TAG_CREATED" ]]; then
            printf '%s\n' 'gh: Not Found (HTTP 404)' >&2
            exit 1
        fi
        ;;
esac
printf '%s\n' "$GH_OUTPUT"
GH
cat > "$bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$GH_SLEEP_CALLS"
SLEEP
chmod +x "$bin/gh" "$bin/sleep"
PATH="$bin:$PATH"
export PATH

source "$repository_root/scripts/release-workflow-helpers.sh"

reset_calls() {
    rm -f "$GH_CALLS" "$GH_GET_COUNT" "$GH_TAG_CREATED" "$GH_SLEEP_CALLS"
    : > "$GH_CALLS"
    : > "$GH_SLEEP_CALLS"
    GH_MODE=success
    GH_OUTPUT='sha256:expected'
    GH_POST_FAIL=false
    export GH_MODE GH_OUTPUT GH_POST_FAIL
}

GH_CALLS="$test_dir/gh-calls"
GH_GET_COUNT="$test_dir/gh-get-count"
GH_SLEEP_CALLS="$test_dir/sleep-calls"
GH_TAG_CREATED="$test_dir/tag-created"
export GH_CALLS GH_GET_COUNT GH_SLEEP_CALLS GH_TAG_CREATED

reset_calls
GH_MODE=transient-404
GH_OUTPUT='sha256:expected'
export GH_MODE GH_OUTPUT
result="$(release_api_get_retry repos/example/repo/releases/tags/v1.2.3 --jq .digest)"
[[ "$result" == 'sha256:expected' ]] || fail 'Transient 404 did not return the successful API result.'
[[ "$(<"$GH_GET_COUNT")" == 2 ]] || fail 'Transient 404 did not retry exactly once.'
[[ "$(<"$GH_SLEEP_CALLS")" == 1 ]] || fail 'Transient 404 did not use the bounded backoff.'

reset_calls
GH_MODE=persistent-404
export GH_MODE
if release_api_get_retry repos/example/repo/releases/tags/v1.2.3 --jq .digest 2>"$test_dir/persistent-error"; then
    fail 'Persistent 404 unexpectedly succeeded.'
else
    status=$?
    [[ "$status" == 44 ]] || fail 'Persistent 404 did not use its distinct not-found status.'
fi
[[ "$(<"$GH_GET_COUNT")" == 5 ]] || fail 'Persistent 404 did not stop after five attempts.'
[[ "$(wc -l < "$GH_SLEEP_CALLS" | tr -d ' ')" == 4 ]] || fail 'Persistent 404 used an unexpected retry count.'
grep -Fq 'still returned 404 after 5 attempts' "$test_dir/persistent-error" || fail 'Persistent 404 did not report a clear failure.'

reset_calls
GH_MODE=forbidden
export GH_MODE
if release_api_get_retry repos/example/repo/releases/tags/v1.2.3 --jq .digest 2>"$test_dir/forbidden-error"; then
    fail 'A non-404 API error unexpectedly succeeded.'
fi
[[ "$(<"$GH_GET_COUNT")" == 1 ]] || fail 'A non-404 API error was retried.'
[[ ! -s "$GH_SLEEP_CALLS" ]] || fail 'A non-404 API error triggered a retry delay.'

reset_calls
GH_MODE=success
GH_OUTPUT='commit-expected'
export GH_MODE GH_OUTPUT
release_ensure_tag example/repo v1.2.3 commit-expected true || fail 'Matching immutable tag was rejected.'
grep -Fq -- '--method POST' "$GH_CALLS" && fail 'Matching immutable tag was rewritten.'

reset_calls
GH_MODE=success
GH_OUTPUT='commit-other'
export GH_MODE GH_OUTPUT
if release_ensure_tag example/repo v1.2.3 commit-expected true 2>"$test_dir/tag-mismatch-error"; then
    fail 'A tag pointing to a different commit was accepted.'
fi
grep -Fq -- '--method POST' "$GH_CALLS" && fail 'A mismatched immutable tag was rewritten.'

reset_calls
GH_MODE=after-post
GH_OUTPUT='commit-expected'
export GH_MODE GH_OUTPUT
release_ensure_tag example/repo v1.2.3 commit-expected false || fail 'New tag creation and verification failed.'
grep -Fq -- '--method POST' "$GH_CALLS" || fail 'Missing tag was not created.'
[[ "$(<"$GH_GET_COUNT")" == 1 ]] || fail 'New tag was not verified after creation.'

reset_calls
GH_MODE=after-post
GH_OUTPUT='commit-expected'
GH_POST_FAIL=true
export GH_MODE GH_OUTPUT GH_POST_FAIL
release_ensure_tag example/repo v1.2.3 commit-expected false || fail 'A lost tag-creation response was not recovered.'
[[ "$(<"$GH_GET_COUNT")" == 1 ]] || fail 'A lost tag-creation response was not checked against the remote ref.'

echo 'release workflow helper tests passed'
