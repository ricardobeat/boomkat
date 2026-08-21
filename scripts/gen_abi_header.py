#!/usr/bin/env python3
# Regenerate the machine-checked pieces of the C ABI from the single source
# in src/embed/abi.c3:
#
#   1. The enum blocks of include/boomkat.h, delimited by
#      /* BEGIN GENERATED <name> ... */ and /* END GENERATED <name> */.
#   2. The linker export lists for the shared library, derived from the
#      header's BK_API declarations:
#      out/boomkat.exports (Mach-O -exported_symbols_list) and
#      out/boomkat.map (ELF --version-script).
#
# Modes:
#   (default)  rewrite the header blocks in place and write the export lists
#   --lists    write only the export lists (used by the `shared` make rule)
#   --check    rewrite nothing; fail if the header is stale or the header's
#              BK_API set disagrees with capi.c3's @export set
#
# `make check-abi` runs --check; CI runs `make check-abi`.

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ABI_C3 = ROOT / "src" / "embed" / "abi.c3"
HEADER = ROOT / "include" / "boomkat.h"
CAPI = ROOT / "src" / "capi.c3"
OUT = ROOT / "out"

# abi block name -> C enum typedef name
BLOCKS = {
    "status": "bk_status",
    "type": "bk_type",
    "errkind": "bk_error_kind",
}

CONST_RE = re.compile(r"^const\s+int\s+(BK_\w+)\s*=\s*(-?\d+)\s*;\s*(?://\s*(.*))?$")
MARKER_RE = re.compile(r"^//\s*\[abi:(\w+)\]\s*$")


def parse_manifest():
    """block name -> [(name, value, comment)] in declaration order."""
    blocks = {}
    current = None
    for line in ABI_C3.read_text().splitlines():
        m = MARKER_RE.match(line)
        if m:
            current = m.group(1)
            if current not in BLOCKS:
                sys.exit(f"{ABI_C3}: unknown abi block '{current}'")
            blocks[current] = []
            continue
        m = CONST_RE.match(line)
        if m:
            if current is None:
                sys.exit(f"{ABI_C3}: constant outside any [abi:...] block: {line}")
            blocks[current].append((m.group(1), int(m.group(2)), m.group(3) or ""))
    for name in BLOCKS:
        if not blocks.get(name):
            sys.exit(f"{ABI_C3}: no [abi:{name}] block found")
    return blocks


def render_enum(typedef, entries):
    name_w = max(len(n) for n, _, _ in entries)
    val_w = max(len(str(v)) for _, v, _ in entries)
    lines = ["typedef enum {"]
    for i, (name, val, comment) in enumerate(entries):
        sep = "," if i < len(entries) - 1 else " "
        line = f"    {name:<{name_w}} = {val:>{val_w}}{sep}"
        if comment:
            line += f"  /* {comment} */"
        lines.append(line.rstrip())
    lines.append(f"}} {typedef};")
    return "\n".join(lines)


def regenerate_header(blocks, text):
    for block, typedef in BLOCKS.items():
        begin = f"/* BEGIN GENERATED {block} (scripts/gen_abi_header.py) */"
        end = f"/* END GENERATED {block} */"
        pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.S)
        if not pattern.search(text):
            sys.exit(f"{HEADER}: no GENERATED markers for block '{block}'")
        replacement = f"{begin}\n{render_enum(typedef, blocks[block])}\n{end}"
        text = pattern.sub(replacement, text)
    return text


def header_symbols(text):
    """Exported function names: the identifier before '(' in each BK_API decl."""
    code = "\n".join(l for l in text.splitlines() if not l.startswith("#"))
    return sorted(set(re.findall(r"BK_API\b[^;()]*?\b(\w+)\s*\(", code)))


def capi_exports():
    return sorted(set(re.findall(r'@export\("(\w+)"\)', CAPI.read_text())))


def write_lists(symbols):
    OUT.mkdir(exist_ok=True)
    (OUT / "boomkat.exports").write_text("".join(f"_{s}\n" for s in symbols))
    lines = ["BOOMKAT_1.0 {", "    global:"]
    lines += [f"        {s};" for s in symbols]
    lines += ["    local:", "        *;", "};", ""]
    (OUT / "boomkat.map").write_text("\n".join(lines))


def main():
    check = "--check" in sys.argv
    lists_only = "--lists" in sys.argv

    text = HEADER.read_text()
    symbols = header_symbols(text)
    if not symbols:
        sys.exit(f"{HEADER}: no BK_API declarations found")

    exports = capi_exports()
    if exports != symbols:
        only_h = sorted(set(symbols) - set(exports))
        only_c = sorted(set(exports) - set(symbols))
        sys.exit(
            "header BK_API set and capi.c3 @export set disagree\n"
            f"  header only: {only_h}\n  capi only:  {only_c}"
        )

    if lists_only:
        write_lists(symbols)
        return

    blocks = parse_manifest()
    regenerated = regenerate_header(blocks, text)

    if check:
        if regenerated != text:
            sys.exit(
                f"{HEADER} is stale: run scripts/gen_abi_header.py and commit the result"
            )
        print("check-abi: header matches src/embed/abi.c3")
        return

    if regenerated != text:
        HEADER.write_text(regenerated)
        print(f"updated {HEADER}")
    write_lists(symbols)


if __name__ == "__main__":
    main()
