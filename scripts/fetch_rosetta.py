#!/usr/bin/env python3
"""Fetch a Rosetta Code task's JavaScript sample verbatim.

The sample files under test/rosetta-verbatim/ must stay byte-identical to the
wiki so the suite tests third-party code we did not write. Re-run this script
to confirm a sample has not drifted (or that the wiki has not changed under us):

    python3 scripts/fetch_rosetta.py --check test/rosetta-verbatim

Each sample carries a provenance header naming the task and the block index it
came from; --check strips that header before comparing.
"""
import argparse, pathlib, re, sys, urllib.request

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36"
HDR = "// Verbatim from https://rosettacode.org/wiki/{task} (JavaScript block {idx})\n// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.\n"

def wiki(task):
    url = f"https://rosettacode.org/wiki/{task}?action=raw"
    return urllib.request.urlopen(
        urllib.request.Request(url, headers={"User-Agent": UA})).read().decode("utf-8", "replace")

def blocks(text):
    m = re.search(r'^==\{\{header\|JavaScript\}\}==(.*?)(?=^==\{\{header\|(?!JavaScript))',
                  text, re.S | re.M)
    if not m:
        return []
    return [b.strip() for b in re.findall(
        r'<syntaxhighlight lang="?(?:javascript|js)"?>(.*?)</syntaxhighlight>', m.group(1), re.S)]

def body(path):
    """Sample text with the two-line provenance header removed."""
    lines = path.read_text().splitlines(keepends=True)
    return "".join(lines[2:]) if len(lines) > 2 and lines[0].startswith("// Verbatim from") else "".join(lines)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--task"); ap.add_argument("--idx", type=int, default=0)
    ap.add_argument("--out"); ap.add_argument("--check", metavar="DIR")
    a = ap.parse_args()

    if a.check:
        bad = 0
        for f in sorted(pathlib.Path(a.check).glob("*.js")):
            if f.name.endswith(".check.js") or f.name.startswith("_"):
                continue
            head = f.read_text().splitlines()[:1]
            m = re.match(r'// Verbatim from https://rosettacode\.org/wiki/(\S+) \(JavaScript block (\d+)\)', head[0] if head else "")
            if not m:
                print(f"SKIP {f.name}: no provenance header"); continue
            task, idx = m.group(1), int(m.group(2))
            bs = blocks(wiki(task))
            if idx >= len(bs):
                print(f"DRIFT {f.name}: block {idx} no longer exists ({len(bs)} blocks)"); bad += 1; continue
            if bs[idx].strip() != body(f).strip():
                print(f"DRIFT {f.name}: wiki text differs from local copy", flush=True); bad += 1
            else:
                print(f"  ok {f.name}", flush=True)
        return 1 if bad else 0

    bs = blocks(wiki(a.task))
    if a.idx >= len(bs):
        print(f"error: {a.task} has {len(bs)} JS block(s)", file=sys.stderr); return 1
    text = HDR.format(task=a.task, idx=a.idx) + bs[a.idx] + "\n"
    if a.out:
        pathlib.Path(a.out).write_text(text)
        print(f"wrote {a.out} ({len(bs[a.idx].splitlines())} lines)")
    else:
        sys.stdout.write(text)
    return 0

sys.exit(main())
