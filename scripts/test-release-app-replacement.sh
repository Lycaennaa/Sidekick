#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
helper="$repository_root/scripts/replace-release-app.sh"
test_root="$repository_root/.kilo-tmp/release-app-replacement.$$"
real_mv=$(command -v mv)

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

make_app() {
    mkdir -p "$1/Contents"
    printf '%s\n' "$2" > "$1/Contents/version"
}

read_version() {
    IFS= read -r version < "$1/Contents/version"
    printf '%s' "$version"
}

mkdir -p "$test_root/success/Applications" "$test_root/failure/Applications" "$test_root/interrupted/Applications" "$test_root/postcommit/Applications" "$test_root/precommit-kill/Applications" "$test_root/postcommit-kill/Applications" "$test_root/locked/Applications"
make_app "$test_root/success/Sidekick.app" new
make_app "$test_root/success/Applications/Sidekick.app" old
sh "$helper" "$test_root/success/Sidekick.app" "$test_root/success/Applications/Sidekick.app"
[ "$(read_version "$test_root/success/Applications/Sidekick.app")" = new ] || fail 'Successful replacement did not install the new app.'

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/mv" <<'WRAPPER'
#!/bin/sh
count=0
if [ -f "$SIDEKICK_MOVE_COUNT" ]; then IFS= read -r count < "$SIDEKICK_MOVE_COUNT"; fi
count=$((count + 1))
printf '%s\n' "$count" > "$SIDEKICK_MOVE_COUNT"
if [ "$count" -eq "$SIDEKICK_KILL_ON_MOVE" ]; then
    "$SIDEKICK_REAL_MV" "$@"
    status=$?
    kill -KILL "$PPID"
    exit "$status"
fi
if [ "$count" -eq "$SIDEKICK_SIGNAL_AFTER_MOVE" ]; then
    "$SIDEKICK_REAL_MV" "$@"
    status=$?
    kill -TERM "$PPID"
    exit "$status"
fi
if [ "$count" -eq "$SIDEKICK_SIGNAL_ON_MOVE" ]; then
    kill -TERM "$PPID"
    exit 73
fi
if [ "$count" -eq "$SIDEKICK_FAIL_ON_MOVE" ]; then exit 73; fi
exec "$SIDEKICK_REAL_MV" "$@"
WRAPPER
chmod +x "$fake_bin/mv"

make_app "$test_root/failure/Sidekick.app" new
make_app "$test_root/failure/Applications/Sidekick.app" old
printf '0\n' > "$test_root/failure/move-count"
if PATH="$fake_bin:/usr/bin:/bin" \
    SIDEKICK_MOVE_COUNT="$test_root/failure/move-count" \
    SIDEKICK_REAL_MV="$real_mv" \
    SIDEKICK_FAIL_ON_MOVE=2 \
    SIDEKICK_SIGNAL_ON_MOVE=0 \
    SIDEKICK_SIGNAL_AFTER_MOVE=0 \
    SIDEKICK_KILL_ON_MOVE=0 \
    sh "$helper" "$test_root/failure/Sidekick.app" "$test_root/failure/Applications/Sidekick.app"; then
    fail 'Replacement unexpectedly succeeded after the staged move failed.'
fi
[ "$(read_version "$test_root/failure/Applications/Sidekick.app")" = old ] || fail 'Failed replacement did not restore the old app.'

make_app "$test_root/interrupted/Sidekick.app" new
make_app "$test_root/interrupted/Applications/Sidekick.app" old
printf '0\n' > "$test_root/interrupted/move-count"
if PATH="$fake_bin:/usr/bin:/bin" \
    SIDEKICK_MOVE_COUNT="$test_root/interrupted/move-count" \
    SIDEKICK_REAL_MV="$real_mv" \
    SIDEKICK_FAIL_ON_MOVE=0 \
    SIDEKICK_SIGNAL_ON_MOVE=2 \
    SIDEKICK_SIGNAL_AFTER_MOVE=0 \
    SIDEKICK_KILL_ON_MOVE=0 \
    sh "$helper" "$test_root/interrupted/Sidekick.app" "$test_root/interrupted/Applications/Sidekick.app"; then
    fail 'Replacement unexpectedly survived a termination during the move.'
fi
[ "$(read_version "$test_root/interrupted/Applications/Sidekick.app")" = old ] || fail 'Interrupted replacement did not restore the old app.'

make_app "$test_root/postcommit/Sidekick.app" new
make_app "$test_root/postcommit/Applications/Sidekick.app" old
printf '0\n' > "$test_root/postcommit/move-count"
if ! PATH="$fake_bin:/usr/bin:/bin" \
    SIDEKICK_MOVE_COUNT="$test_root/postcommit/move-count" \
    SIDEKICK_REAL_MV="$real_mv" \
    SIDEKICK_FAIL_ON_MOVE=0 \
    SIDEKICK_SIGNAL_ON_MOVE=0 \
    SIDEKICK_SIGNAL_AFTER_MOVE=2 \
    SIDEKICK_KILL_ON_MOVE=0 \
    sh "$helper" "$test_root/postcommit/Sidekick.app" "$test_root/postcommit/Applications/Sidekick.app"; then
    fail 'Post-commit TERM did not finish cleanup successfully.'
fi
[ "$(read_version "$test_root/postcommit/Applications/Sidekick.app")" = new ] || fail 'Post-commit TERM removed the installed app.'
for leftover in "$test_root/postcommit/Applications"/.Sidekick.app.previous.* "$test_root/postcommit/Applications"/.Sidekick.app.staging.*; do
    [ ! -e "$leftover" ] || fail "Post-commit TERM left a staging bundle at $leftover."
done

make_app "$test_root/precommit-kill/Sidekick.app" new
make_app "$test_root/precommit-kill/Applications/Sidekick.app" old
printf '0\n' > "$test_root/precommit-kill/move-count"
if PATH="$fake_bin:/usr/bin:/bin" \
    SIDEKICK_MOVE_COUNT="$test_root/precommit-kill/move-count" \
    SIDEKICK_REAL_MV="$real_mv" \
    SIDEKICK_FAIL_ON_MOVE=0 \
    SIDEKICK_SIGNAL_ON_MOVE=0 \
    SIDEKICK_SIGNAL_AFTER_MOVE=0 \
    SIDEKICK_KILL_ON_MOVE=1 \
    sh "$helper" "$test_root/precommit-kill/Sidekick.app" "$test_root/precommit-kill/Applications/Sidekick.app"; then
    fail 'Replacement unexpectedly survived SIGKILL before commit.'
fi
[ ! -e "$test_root/precommit-kill/Applications/Sidekick.app" ] || fail 'Pre-commit SIGKILL left an uncommitted destination.'
sh "$helper" "$test_root/precommit-kill/Sidekick.app" "$test_root/precommit-kill/Applications/Sidekick.app"
[ "$(read_version "$test_root/precommit-kill/Applications/Sidekick.app")" = new ] || fail 'Next run did not recover the previous app before replacement.'

make_app "$test_root/postcommit-kill/Sidekick.app" next
make_app "$test_root/postcommit-kill/Initial.app" new
make_app "$test_root/postcommit-kill/Applications/Sidekick.app" old
printf '0\n' > "$test_root/postcommit-kill/move-count"
if PATH="$fake_bin:/usr/bin:/bin" \
    SIDEKICK_MOVE_COUNT="$test_root/postcommit-kill/move-count" \
    SIDEKICK_REAL_MV="$real_mv" \
    SIDEKICK_FAIL_ON_MOVE=0 \
    SIDEKICK_SIGNAL_ON_MOVE=0 \
    SIDEKICK_SIGNAL_AFTER_MOVE=0 \
    SIDEKICK_KILL_ON_MOVE=2 \
    sh "$helper" "$test_root/postcommit-kill/Initial.app" "$test_root/postcommit-kill/Applications/Sidekick.app"; then
    fail 'Replacement unexpectedly survived SIGKILL after commit.'
fi
[ "$(read_version "$test_root/postcommit-kill/Applications/Sidekick.app")" = new ] || fail 'Post-commit SIGKILL removed the new destination.'
sh "$helper" "$test_root/postcommit-kill/Sidekick.app" "$test_root/postcommit-kill/Applications/Sidekick.app"
[ "$(read_version "$test_root/postcommit-kill/Applications/Sidekick.app")" = next ] || fail 'Next run did not clean the stale backup and install the new app.'

make_app "$test_root/locked/Sidekick.app" new
make_app "$test_root/locked/Applications/Sidekick.app" old
lock_path="$test_root/locked/Applications/.Sidekick.app.replace.lock"
touch "$lock_path"
python3 - "$lock_path" "$helper" "$test_root/locked/Sidekick.app" "$test_root/locked/Applications/Sidekick.app" <<'PY'
import fcntl
import subprocess
import sys
from pathlib import Path

lock_path, helper, source, destination = sys.argv[1:]
with open(lock_path, "a", encoding="utf-8") as lock_file:
    fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    result = subprocess.run(
        ["sh", helper, source, destination],
        capture_output=True,
        text=True,
        timeout=5,
    )
if result.returncode == 0:
    raise SystemExit("Replacement reported success while another process held the lock.")
if Path(destination, "Contents/version").read_text(encoding="utf-8").strip() != "old":
    raise SystemExit("Lock contention changed the destination app.")
PY