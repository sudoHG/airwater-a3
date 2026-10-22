#!/usr/bin/env python3
"""Generate shortcuts for the developer's own app identity; never run them."""

import argparse
from pathlib import Path
import plistlib
import re
import subprocess


def replace(value, bundle_id, team_id):
    if isinstance(value, dict):
        return {k: replace(v, bundle_id, team_id) for k, v in value.items()}
    if isinstance(value, list):
        return [replace(v, bundle_id, team_id) for v in value]
    if isinstance(value, str):
        return value.replace("__BUNDLE_ID__", bundle_id).replace("__TEAM_ID__", team_id)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--sign", action="store_true", help="Use Apple's local shortcuts sign tool")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.bundle_id):
        parser.error("Use the bundle identifier configured for your own app.")
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("Team ID must be the 10-character Apple development team identifier.")

    root = Path(__file__).resolve().parents[1]
    generated = root / ".build" / "shortcuts"
    generated.mkdir(parents=True, exist_ok=True)
    for template, display_name in [("connect", "连接 A3"), ("disconnect", "关闭 A3 热点")]:
        source = root / "Shortcuts" / f"{template}.template.plist"
        workflow = replace(plistlib.loads(source.read_bytes()), args.bundle_id, args.team_id)
        unsigned = generated / f"{template}.unsigned.shortcut"
        unsigned.write_bytes(plistlib.dumps(workflow, fmt=plistlib.FMT_BINARY, sort_keys=False))
        print(f"Generated {unsigned.relative_to(root)}")
        if args.sign:
            destination = root / "Resources" / f"{display_name}.shortcut"
            subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", str(unsigned),
                            "--output", str(destination)], check=True)
            print(f"Signed {destination.relative_to(root)}")
    if args.sign:
        print("Run make generate again, then build. Importing/running remains a user action.")
    else:
        print("Unsigned files cannot be imported directly. Use --sign or create the workflow on iPhone.")


if __name__ == "__main__":
    main()
