#!/usr/bin/env python3
"""Measure the stripped-binary cost of the native Intl services and their data.

Builds the release `boomkat` target with full, small, numeric-only, and no Intl
profiles, measures optional root collation, and prints stripped binary deltas.
The full build writes a linker map with Intl and tzdb data symbol sizes.

macOS only: it relies on ld64's -map output and `strip -x`.
"""
import argparse
import copy
import json
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Data symbols worth itemizing: generated Intl tables, tzdb tables, and pools.
DATA_PATTERN = re.compile(r"(intl|INTL|tzdb|TZDB|tzdata)", re.IGNORECASE)


def build(work, name, features, map_file=None):
    project = json.loads((ROOT / "project.json").read_text())
    target = copy.deepcopy(project["targets"]["boomkat"])
    target["name"] = name
    target["features"] = [f for f in target.get("features", [])
                          if f not in {"INTL", "INTL_FULL", "INTL_COLLATOR"}] + features
    target["sources"] = [str(ROOT / p) for p in target["sources"]]
    links = ["-Wl,-dead_strip", "-Wl,-exported_symbols_list," + str(ROOT / "scripts/no_exports.exp")]
    if map_file:
        links.append("-Wl,-map," + str(map_file))
    target["link-args"] = links
    project["c-sources"] = [str(ROOT / p) for p in project.get("c-sources", [])]
    project["c-include-dirs"] = [str(ROOT / p) for p in project.get("c-include-dirs", [])]
    project["targets"] = {name: target}
    (work / "project.json").write_text(json.dumps(project, indent=2) + "\n")
    result = subprocess.run(["nice", "c3c", "build", name], cwd=work, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(f"build {name} failed")
    binary = work / "out" / name
    subprocess.run(["strip", "-x", str(binary)], check=True)
    return binary.stat().st_size


def data_symbols(map_file):
    sizes = {}
    in_symbols = False
    for line in map_file.read_text(errors="replace").splitlines():
        if line.startswith("# Symbols:"):
            in_symbols = True
            continue
        if not in_symbols or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        size = int(parts[1], 16)
        name = parts[2].split("] ", 1)[-1]
        if DATA_PATTERN.search(name) and not name.startswith("_boomkat.builtins.builtin_"):
            sizes[name] = sizes.get(name, 0) + size
    return sizes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path, help="also write the results here")
    parser.add_argument("--all-symbols", action="store_true", help="list code symbols too")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("intl_size.py uses ld64 map files and strip -x")
    work = Path(tempfile.mkdtemp(prefix="intl-size-"))
    try:
        map_file = work / "full.map"
        full = build(work, "full", ["INTL", "INTL_FULL", "INTL_COLLATOR"], map_file)
        small = build(work, "small", ["INTL"])
        small_collator = build(work, "small_collator", ["INTL", "INTL_COLLATOR"])
        no_date = build(work, "no_date", ["INTL", "NO_INTL_DATE"])
        no_intl = build(work, "no_intl", [])
        symbols = data_symbols(map_file)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"full binary            {full:9,}")
    print(f"small binary           {small:9,}")
    print(f"Intl full (vs none)    {full - no_intl:9,}")
    print(f"  root Collator        {small_collator - small:9,}")
    print(f"  full locale data     {full - small_collator:9,}")
    print(f"  English date service {small - no_date:9,}")
    print(f"  other services        {no_date - no_intl:8,}")
    print("\nlargest Intl/tzdb symbols (linker map):")
    for name, size in sorted(symbols.items(), key=lambda kv: -kv[1])[:40 if not args.all_symbols else None]:
        print(f"  {size:8,}  {name}")
    if args.json:
        args.json.write_text(json.dumps({"full": full, "small": small, "small_collator": small_collator, "collator_cost": small_collator - small,
                                         "no_intl_date": no_date, "no_intl": no_intl,
                                         "symbols": symbols}, indent=2) + "\n")


if __name__ == "__main__":
    main()
