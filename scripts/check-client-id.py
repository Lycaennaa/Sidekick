#!/usr/bin/env python3
import plistlib
import sys
from pathlib import Path


INFO_PLIST = Path("build/generated/SidekickInfo.plist")


def main():
    try:
        with INFO_PLIST.open("rb") as source:
            client_id = plistlib.load(source).get("TwitchOAuthClientID")
    except (OSError, plistlib.InvalidFileException) as error:
        print(f"could not read generated app Info.plist: {error}", file=sys.stderr)
        return 1
    if client_id != "none":
        print("build-time Twitch client ID must currently be none", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())