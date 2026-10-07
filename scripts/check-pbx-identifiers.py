#!/usr/bin/env python3
import re
import subprocess
import sys
from pathlib import Path


ASSIGNMENT = re.compile(
    r'^\s*(?P<key>[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]+\])?)\s*=\s*(?P<value>.*?);\s*$'
)
VARIABLE = re.compile(r'^"?\$\([A-Za-z_][A-Za-z0-9_]*\)"?$')
PRIVATE_PATH = re.compile(r'/(?:Users|private/var)/')

IDENTITY_SETTINGS = {
    "CODE_SIGN_IDENTITY",
    "DEVELOPMENT_TEAM",
    "ORGANIZATIONNAME",
    "PROVISIONING_PROFILE",
    "PROVISIONING_PROFILE_SPECIFIER",
}


def check_file(path):
    failures = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        return [(0, f"cannot read generated project: {error}")]

    for line_number, line in enumerate(lines, 1):
        if PRIVATE_PATH.search(line):
            failures.append((line_number, "contains a machine-specific absolute path"))

        match = ASSIGNMENT.match(line)
        if not match:
            continue

        key = match.group("key")
        value = match.group("value").strip()
        base_key = key.split("[", 1)[0]

        if base_key in {"PRODUCT_NAME", "PRODUCT_BUNDLE_IDENTIFIER"}:
            if not VARIABLE.fullmatch(value):
                failures.append(
                    (line_number, f"{base_key} must reference a build setting variable")
                )
        elif base_key in IDENTITY_SETTINGS:
            if value not in {"\"\"", "-"} and not VARIABLE.fullmatch(value):
                failures.append((line_number, f"{base_key} contains a local identity"))

    return failures


def main():
    root = Path(
        subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], text=True
        ).strip()
    )
    path = Path("Sidekick.xcodeproj/project.pbxproj")
    project = root / path
    if not project.is_file():
        print(f"generated project not found: {path}", file=sys.stderr)
        print(
            "Run xcodegen generate --spec project.yml before this check.",
            file=sys.stderr,
        )
        return 1

    failures = [
        (path, line_number, reason)
        for line_number, reason in check_file(project)
    ]

    if not failures:
        return 0

    print("project.pbxproj metadata check failed:", file=sys.stderr)
    for path, line_number, reason in failures:
        print(f"  {path}:{line_number}: {reason}", file=sys.stderr)
    print(
        "Move product/signing values to an xcconfig or xcodebuild command-line override.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())