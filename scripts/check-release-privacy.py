#!/usr/bin/env python3
import getpass
import re
import sys
from pathlib import Path


FLAGGED_DATA = {
    "machine path": re.compile(rb"/Users/|/private/var/|/Volumes/"),
    "private key": re.compile(rb"-----BEGIN (?:RSA|EC|OPENSSH|PRIVATE) KEY-----"),
    "GitHub token": re.compile(rb"(?:ghp_|github_pat_)[A-Za-z0-9_]+"),
    "AWS access key": re.compile(rb"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
}


def scan(app, repository_root):
    patterns = dict(FLAGGED_DATA)
    patterns["repository path"] = re.compile(
        re.escape(repository_root.resolve().as_posix().encode())
    )
    home = Path.home().as_posix().encode()
    if len(home) > len("/Users/"):
        patterns["home path"] = re.compile(re.escape(home))
    username = getpass.getuser().encode()
    if len(username) >= 3:
        patterns["user name"] = re.compile(rb"\b" + re.escape(username) + rb"\b")

    failures = []
    for path in sorted(item for item in app.rglob("*") if item.is_file()):
        data = path.read_bytes()
        for name, pattern in patterns.items():
            if pattern.search(data):
                failures.append((path.relative_to(app), name))
    return failures


def main():
    if len(sys.argv) != 3:
        print("usage: check-release-privacy.py APP_PATH REPOSITORY_ROOT", file=sys.stderr)
        return 2

    app = Path(sys.argv[1])
    repository_root = Path(sys.argv[2])
    if not app.is_dir():
        print(f"app bundle not found: {app}", file=sys.stderr)
        return 2

    failures = scan(app, repository_root)
    if not failures:
        return 0

    print("release privacy check failed:", file=sys.stderr)
    for relative_path, name in failures:
        print(f"  {relative_path}: {name}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())