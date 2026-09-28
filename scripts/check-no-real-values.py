#!/usr/bin/env python3
import re
import subprocess
import sys

PATTERNS = {
    "tailnet name": re.compile(r"\btail[0-9a-f]{6,}\b"),
    "Tailscale machine name": re.compile(r"\b[a-z0-9]+-[a-z0-9]{7}\.tail[0-9a-z]+\.ts\.net\b"),
    "tailnet address": re.compile(r"\b100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}\b"),
    "pairing code": re.compile(r"code=([A-Za-z0-9_-]{12,})"),
}
MADE_UP = {"example-code-123"}
MADE_UP_ADDRESS = re.compile(r"^100\.64\.0\.\d{1,3}$")


def tracked_files():
    listed = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout
    return [name for name in listed.splitlines() if not name.endswith((".png", ".jpg", ".ipa", ".json"))]


def problems():
    found = []
    for name in tracked_files():
        try:
            text = open(name, encoding="utf-8").read()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for kind, pattern in PATTERNS.items():
                for match in pattern.finditer(line):
                    value = match.group(1) if match.groups() else match.group(0)
                    if value in MADE_UP or MADE_UP_ADDRESS.match(value):
                        continue
                    found.append(f"{name}:{number}: looks like a real {kind} ({value[:6]}...)")
    return found


if __name__ == "__main__":
    issues = problems()
    for issue in issues:
        print(issue)
    if issues:
        print("Use made-up values in the repo: example-code-123, tail0example, 100.64.0.x")
    sys.exit(1 if issues else 0)
