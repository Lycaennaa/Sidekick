#!/usr/bin/env python3
import json
import sys
from pathlib import Path


LOCKFILES = (
    Path("Sidekick.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
)


def normalized_pins(path):
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {path}: {error}") from error

    pins = []
    for pin in document.get("pins", []):
        state = pin.get("state", {})
        pins.append(
            (
                pin.get("identity"),
                pin.get("location"),
                state.get("revision"),
                state.get("version"),
            )
        )
    return tuple(sorted(pins))


def main():
    missing = [str(path) for path in LOCKFILES if not path.is_file()]
    if missing:
        print("missing Swift package lockfile(s):", ", ".join(missing), file=sys.stderr)
        return 1
    try:
        for path in LOCKFILES:
            normalized_pins(path)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Swift package lockfile is valid ({LOCKFILES[0]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())