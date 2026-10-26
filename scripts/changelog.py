#!/usr/bin/env python3
"""Read and roll CHANGELOG.md sections (Keep a Changelog layout)."""

import argparse
import datetime
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
HEADING_RE = re.compile(r"^## \[([^\]]+)\].*$", re.MULTILINE)


def sections(text: str) -> dict[str, str]:
    """Map each `## [name]` heading to its body, stripped of surrounding blanks."""
    matches = list(HEADING_RE.finditer(text))
    return {
        m.group(1): text[m.end():(matches[i + 1].start() if i + 1 < len(matches) else len(text))].strip()
        for i, m in enumerate(matches)
    }


def section(version: str) -> str:
    body = sections(CHANGELOG.read_text(encoding="utf-8")).get(version)
    if not body:
        raise ValueError(f"CHANGELOG.md has no entries under [{version}]")
    return body


def commits_since_last_release() -> int:
    """Commits since the previous tag, plus the release commit about to be made."""
    last = subprocess.run(["git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*"],
                          cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    count = subprocess.run(["git", "rev-list", "--count", f"{last}..HEAD"],
                           cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    return int(count) + 1


def roll(version: str, date: str) -> None:
    """Move the Unreleased entries under a new dated heading for `version`."""
    text = CHANGELOG.read_text(encoding="utf-8")
    if version in sections(text):
        raise ValueError(f"CHANGELOG.md already has a [{version}] section")
    if not sections(text).get("Unreleased"):
        raise ValueError("CHANGELOG.md has nothing under [Unreleased] to release")
    text = re.sub(r"^## \[Unreleased\][^\n]*$", f"## [Unreleased]\n\n## [{version}] - {date} · {commits_since_last_release()} commits",
                  text, count=1, flags=re.MULTILINE)
    CHANGELOG.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["show", "roll"])
    parser.add_argument("version")
    args = parser.parse_args()
    version = args.version.removeprefix("v")
    try:
        if args.command == "show":
            print(section(version))
        else:
            roll(version, datetime.date.today().isoformat())
    except ValueError as exc:
        print(f"changelog: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
