#!/usr/bin/env python3
"""Check publishable files, not generated/ignored local artifacts. No network access."""

from pathlib import Path
import plistlib
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_SUFFIXES = {".apk", ".ipa", ".pcap", ".pcapng", ".bin", ".p12", ".p8", ".pem",
                      ".key", ".mobileprovision", ".shortcut", ".zip", ".log"}
FORBIDDEN_PARTS = {"xcuserdata", ".derivedData", ".build", "实机记录", "原始资料", "静态分析"}
REVIEWED_IMAGES = {"docs/images/a3-connected.png"}
PATTERNS = [re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
            re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),
            re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
            re.compile(r"/(?:Users|home)/[A-Za-z][^\s\"']*/")]


def main():
    listed = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT
    ).decode().split("\0")
    names = sorted(set(filter(None, listed)))
    errors = []
    for name in names:
        path = ROOT / name
        if path.is_symlink():
            errors.append(f"{name}: symlinks are not part of this source export")
            continue
        if path.suffix.lower() in FORBIDDEN_SUFFIXES or any(p in FORBIDDEN_PARTS for p in path.parts):
            errors.append(f"{name}: private/generated artifact type")
            continue
        if not path.is_file():
            errors.append(f"{name}: missing file")
            continue
        if name in REVIEWED_IMAGES:
            data = path.read_bytes()
            if not data.startswith(b"\x89PNG\r\n\x1a\n") or not data.endswith(b"\x00\x00\x00\x00IEND\xaeB`\x82"):
                errors.append(f"{name}: expected a reviewed PNG screenshot")
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            errors.append(f"{name}: unexpected binary file")
            continue
        for line_number, line in enumerate(content.splitlines(), 1):
            if any(pattern.search(line) for pattern in PATTERNS):
                errors.append(f"{name}:{line_number}: possible private material (value suppressed)")
        if path.suffix in {".plist", ".xcprivacy"}:
            try:
                plistlib.loads(path.read_bytes())
            except Exception as error:
                errors.append(f"{name}: invalid property list: {type(error).__name__}")
        if path.suffix == ".md":
            links = re.findall(r"\]\(([^)]+)\)", content)
            links += re.findall(r'(?:src|href)="([^"]+)"', content)
            for link in links:
                if "://" in link or link.startswith(("#", "mailto:")):
                    continue
                target = link.split("#", 1)[0]
                if target and not (path.parent / target).exists():
                    errors.append(f"{name}: broken relative link {target}")

    workflow = plistlib.loads((ROOT / "Shortcuts/connect.template.plist").read_bytes())
    descriptors = [a["WFWorkflowActionParameters"]["AppIntentDescriptor"]
                   for a in workflow["WFWorkflowActions"]
                   if "AppIntentDescriptor" in a.get("WFWorkflowActionParameters", {})]
    if len(descriptors) != 2 or any(d.get("TeamIdentifier") != "__TEAM_ID__" or
                                   d.get("BundleIdentifier") != "__BUNDLE_ID__" for d in descriptors):
        errors.append("Shortcut template must contain two app actions with placeholder identities")
    manifest = plistlib.loads((ROOT / "Resources/PrivacyInfo.xcprivacy").read_bytes())
    reasons = manifest.get("NSPrivacyAccessedAPITypes", [])
    if not any(r.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategorySystemBootTime"
               and "35F9.1" in r.get("NSPrivacyAccessedAPITypeReasons", []) for r in reasons):
        errors.append("Missing elapsed-timer API reason")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"PASS: {len(names)} publishable files; reviewed PNGs, plist, template, relative links and basic secret patterns checked.")
    print("This is a bounded publication check, not a complete credential scan or hardware test.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
