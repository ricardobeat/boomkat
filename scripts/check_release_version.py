#!/usr/bin/env python3
"""Check the committed release version before building or publishing assets."""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
CLI_FILE = ROOT / "cli" / "boomkat.c3"
ABI_FILE = ROOT / "src" / "capi.c3"
VERSION_RE = re.compile(r"0\.0(?:\.\d+)?(?:-[0-9A-Za-z.-]+)?\Z")
CLI_RE = re.compile(r'^const String CLI_VERSION = "([^"]+)";', re.MULTILINE)
ABI_RE = re.compile(r'fn char\* bk_version\(\) @export\("bk_version"\) \{\s*return "([^"]+)";', re.MULTILINE)


def check(tag: str | None) -> None:
    version = VERSION_FILE.read_text(encoding="utf-8").strip()
    if not VERSION_RE.fullmatch(version):
        raise ValueError(f"VERSION must be a v0.0 release version, got {version!r}")
    match = CLI_RE.search(CLI_FILE.read_text(encoding="utf-8"))
    if match is None or match.group(1) != version:
        raise ValueError("CLI_VERSION in cli/boomkat.c3 must match VERSION")
    abi_match = ABI_RE.search(ABI_FILE.read_text(encoding="utf-8"))
    if abi_match is None or abi_match.group(1) != version:
        raise ValueError("bk_version in src/capi.c3 must match VERSION")
    if tag is not None and tag != f"v{version}":
        raise ValueError(f"tag {tag!r} does not match committed VERSION ({version})")
    print(f"release version: v{version}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="tag being released; must equal v<VERSION>")
    args = parser.parse_args()
    try:
        check(args.tag)
    except ValueError as exc:
        print(f"release version check failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
