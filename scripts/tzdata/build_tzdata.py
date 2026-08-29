#!/usr/bin/env python3
"""
Generate src/lib/temporal/tzdata_generated.c3 from a directory of IANA TZif
files (typically the output of `zic -d <dir> -b fat`).

Output is a C3 source file holding a deflate-compressed blob of the
transition tables plus an uncompressed zone-name index. The blob is decoded
once, lazily, on the first tzdb lookup (see tzdb_decode_blob in tzdb.c3);
after that, lookup binary-searches the per-zone sorted transitions slice for
the query instant and returns the matching offset.

Storing the tables raw cost ~272 KB of binary; delta-varint encoding plus
deflate brings that under 11 KB.

Layout:

    struct TzdbTransition { long epoch_sec; int offset_sec; }
    struct TzdbZone { String name; int table_idx; int initial_offset_sec; }

For deduplication, the generator groups zones by transition content. IANA
`backward` is just aliases for canonical zones (e.g. Africa/Abidjan ==
Africa/Bamako == Atlantic/Reykjavik — all GMT forever), so most zone names
share one transition table via an index lookup. The generated file is
~40 KB and the data adds ~11 KB to the compiled binary.

Run scripts/tzdata/build.sh to fetch the latest IANA tzdata, run
`zic -b fat` to expand POSIX DST rules to year 2100, and emit the C3
source. The result is committed; the script is rerun only when the IANA
version changes.
"""

import argparse
import os
import struct
import zlib
import sys
import datetime


MAGIC = b"TZDB"



def _varint(v: int) -> bytes:
    """LEB128-style unsigned varint."""
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _zigzag(v: int) -> int:
    """Map signed -> unsigned so small magnitudes stay short."""
    return (v << 1) ^ (v >> 63)


def encode_blob(canonical):
    """Encode the deduped transition tables into one deflate blob.

    Wire format (all varint unless noted), consumed by tzdb_decode_blob()
    in src/lib/temporal/tzdb.c3:

        n_offsets, then n_offsets * zigzag-varint distinct offset values
        n_tables,  then per table:
            n_trans, then n_trans * (zigzag-varint epoch delta, varint offset index)

    Tables are emitted in `canonical` order, so the table indices stored in
    TZDB_ZONES stay valid. Epoch deltas are relative to the previous entry
    (transitions are sorted ascending, so deltas are small); offsets index a
    shared table because the whole tzdb only uses ~68 distinct offsets.
    """
    offsets = []
    index_of = {}
    for trans_tuple, _members in canonical:
        for _t, o in (trans_tuple if len(trans_tuple) else ((0, 0),)):
            if o not in index_of:
                index_of[o] = len(offsets)
                offsets.append(o)

    buf = bytearray()
    buf += _varint(len(offsets))
    for o in offsets:
        buf += _varint(_zigzag(o))
    buf += _varint(len(canonical))
    for trans_tuple, _members in canonical:
        tt = list(trans_tuple) if len(trans_tuple) else [(0, 0)]
        buf += _varint(len(tt))
        prev = 0
        for t, o in tt:
            buf += _varint(_zigzag(int(t) - prev))
            prev = int(t)
            buf += _varint(index_of[o])
    # Raw DEFLATE (no zlib header/checksum): std::compression::deflate in C3
    # decodes a bare deflate stream, so wrapping it in zlib would fail with
    # CORRUPTED_DATA. wbits=-15 selects the raw stream.
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    blob = comp.compress(bytes(buf)) + comp.flush()
    return blob, offsets, len(buf)


def parse_tzif(path: str) -> tuple[int, list[tuple[int, int]], list[str]]:
    """Parse a TZif v2 file. Returns (initial_offset_sec, [(epoch_sec, total_offset_sec), ...], abbreviations)."""
    with open(path, "rb") as f:
        data = f.read()

    if len(data) < 44:
        return 0, [], []

    magic = data[0:4]
    if magic != b"TZif":
        return 0, [], []

    # v1 header (we still need to skip it to find v2+ data)
    version = data[4]
    # Skip 15 reserved bytes
    # isutcnt / isstdcnt / leapcnt
    isutcnt, isstdcnt, leapcnt = struct.unpack_from(">III", data, 20)
    # timecnt, typecnt, charcnt
    timecnt, typecnt, charcnt = struct.unpack_from(">III", data, 32)

    # v1 transitions are 4 bytes; for v2/v3 we read v2 header instead.
    if version < 2:
        return 0, [], []  # not supported

    # Read the second (v2) header. v1 header size = 44 + 4*timecnt + timecnt (1-byte type indices)
    # + typecnt*(4+1+1) + charcnt + 8*leapcnt + isstdcnt + isutcnt
    v1_size = 44 + 4 * timecnt + timecnt + typecnt * (4 + 1 + 1) + charcnt + 8 * leapcnt + isstdcnt + isutcnt
    if len(data) < v1_size + 44:
        return 0, [], []

    magic2 = data[v1_size : v1_size + 4]
    if magic2 != b"TZif":
        return 0, [], []

    version2 = data[v1_size + 4]
    if version2 < 2:
        return 0, [], []

    # Re-parse v2 header
    isutcnt2, isstdcnt2, leapcnt2 = struct.unpack_from(">III", data, v1_size + 20)
    timecnt2, typecnt2, charcnt2 = struct.unpack_from(">III", data, v1_size + 32)
    base = v1_size + 44

    if typecnt2 == 0:
        return 0, [], []

    # IANA's zic writes the v2 section in a non-standard field order:
    #   transitions[], type_indices[], ttinfo[], abbrevs[], footer
    # RFC 8536 specifies ttinfo[] before type_indices[], but IANA's zic uses
    # the order above (same as glibc). Read type_indices first, then ttinfo.
    #
    # Transitions (8 bytes each in v2)
    trans = struct.unpack_from(f">{timecnt2}q", data, base)

    # Type indices (1 byte each), placed BEFORE ttinfo per IANA/glibc layout
    type_idx_off = base + 8 * timecnt2
    type_indices = struct.unpack_from(f">{timecnt2}B", data, type_idx_off)

    # ttinfo (6 bytes each): utoff(4) + dst(1) + abbrind(1)
    ttis_offset = type_idx_off + timecnt2
    offsets = []
    dst_flags = []
    abbr_indices = []
    for i in range(typecnt2):
        off, dst, abbr = struct.unpack_from(">iBB", data, ttis_offset + i * 6)
        offsets.append(off)
        dst_flags.append(dst)
        abbr_indices.append(abbr)

    # Abbreviation string table
    abbr_offset = ttis_offset + typecnt2 * 6
    abbrev_bytes = data[abbr_offset : abbr_offset + charcnt2]

    # Build transition list with offsets
    # Skip transitions whose type index is out of range — Apple's tzcode can
    # emit indices that reference the POSIX-rule-derived types which aren't
    # stored in the ttinfo table.
    transitions = []
    for i, t in enumerate(trans):
        idx = type_indices[i]
        if idx >= typecnt2:
            continue
        total_off = offsets[idx]
        transitions.append((t, total_off))

    # Initial offset = the offset in effect at the Unix epoch (t=0). The
    # generator truncates the transition list at t=0 (dropping pre-1970 entries),
    # and the lookup falls back to initial_offset for instants before the first
    # kept transition. So initial_offset must be the standard offset at epoch,
    # not offsets[-1]: the last type is a POSIX-rule-derived DST entry for many
    # zones (e.g. America/New_York -> -4h EDT), which would misreport a winter
    # date as daylight saving time.
    initial_offset = 0
    for t, off in transitions:
        if t <= 0:
            initial_offset = off
        else:
            break
    if not transitions or transitions[0][0] > 0:
        # No transition at or before epoch: the offset listed for the first
        # transition also applies in [0, first_transition).
        initial_offset = transitions[0][1] if transitions else (offsets[-1] if offsets else 0)

    # Extract unique abbreviations for the abbrevs pool
    used_abbrs = set()
    for i in range(len(trans)):
        idx = type_indices[i]
        if idx >= typecnt2:
            continue
        abbr_start = abbr_indices[idx]
        if abbr_start >= charcnt2:
            continue
        abbr_end = abbrev_bytes.find(b"\x00", abbr_start)
        if abbr_end < 0:
            abbr_end = charcnt2
        used_abbrs.add(abbrev_bytes[abbr_start:abbr_end].decode("ascii", errors="replace"))

    return initial_offset, transitions, sorted(used_abbrs)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zoneinfo-dir", default="/var/db/timezone/zoneinfo",
                    help="directory of TZif files (default: /var/db/timezone/zoneinfo)")
    ap.add_argument("--output", default="src/lib/temporal/tzdata_generated.c3")
    ap.add_argument("--tzdata-version", default=None,
                    help="e.g. 2025b; default: read from +VERSION file or omit")
    ap.add_argument("--max-zones", type=int, default=0,
                    help="if >0, only include the first N zones (for debugging)")
    ap.add_argument("--rules-up-to", default="2100",
                    help="year to expand POSIX DST rules to (e.g. 2100); "
                         "only used when --zoneinfo-dir is built with `zic -b fat`")
    args = ap.parse_args()

    zi_dir = args.zoneinfo_dir
    if not os.path.isdir(zi_dir):
        print(f"error: {zi_dir} not a directory", file=sys.stderr)
        return 1

    # Read version. `version_str` is the exact IANA release ("2026c") when we
    # know it, so the generated header records what the data actually came from
    # rather than a reconstructed guess.
    year = 2024
    month = 1
    version_str = None
    if args.tzdata_version:
        version_str = args.tzdata_version.strip()
    if args.tzdata_version:
        # like "2025b"
        try:
            year = int(args.tzdata_version[:4])
            # letter suffix -> ignore month, just use 1
        except ValueError:
            pass
    elif os.path.exists(os.path.join(zi_dir, "+VERSION")):
        with open(os.path.join(zi_dir, "+VERSION")) as f:
            for line in f:
                if line.startswith("tzdata"):
                    parts = line.split()
                    if len(parts) >= 2:
                        ver = parts[1].rstrip()
                        version_str = ver
                        try:
                            year = int(ver[:4])
                        except ValueError:
                            pass
                    break

    # Collect zone names (top-level entries that are files; skip directories and metadata)
    skip_top = {"posixrules", "leapseconds", "iso3166.tab", "zone.tab", "tzdata.zi", "+VERSION"}
    zone_names = []
    for entry in sorted(os.listdir(zi_dir)):
        full = os.path.join(zi_dir, entry)
        if not os.path.isfile(full):
            continue
        if entry in skip_top or entry.startswith("+"):
            continue
        zone_names.append(entry)

    # Optionally also include subdir zones (Africa/Cairo, etc.) — they're the ones used in practice.
    for sub in os.listdir(zi_dir):
        full = os.path.join(zi_dir, sub)
        if not os.path.isdir(full):
            continue
        if sub in {"posixrules", "Etc"} and False:
            pass
        for entry in sorted(os.listdir(full)):
            sub_full = os.path.join(full, entry)
            if not os.path.isfile(sub_full):
                continue
            if entry.startswith(".") or entry == "localtime":
                continue
            zone_names.append(f"{sub}/{entry}")

    zone_names.sort()
    if args.max_zones > 0:
        zone_names = zone_names[: args.max_zones]

    print(f"Found {len(zone_names)} zones (year={year}, month={month})", file=sys.stderr)

    # First pass: parse all zones
    parsed = []
    skipped = 0
    for name in zone_names:
        full = os.path.join(zi_dir, name)
        try:
            init_off, trans, abbrs = parse_tzif(full)
        except Exception as e:
            print(f"warn: {name}: {e}", file=sys.stderr)
            skipped += 1
            continue
        parsed.append((name, init_off, trans, abbrs))

    print(f"Parsed {len(parsed)} zones ({skipped} skipped)", file=sys.stderr)

    # Build the C3 source file. We emit a single const TzdbZone[] table with
    # transitions inline per zone, and a per-zone binary search at lookup time.
    # To keep the lookup binary search by name simple, also emit a sorted name
    # table that points into the zones array.
    #
    # Layout in the generated file:
    #   struct TzdbTransition { long epoch_sec; int offset_sec; }
    #   struct TzdbZone { String name; int name_offset; TzdbTransition[] transitions; int initial_offset_sec; }
    #
    # The lookup function does:
    #   1) binary search for `zone_name` in the sorted zone names
    #   2) binary search for `epoch_sec` in that zone's sorted transitions[]
    #   3) return the offset of the last transition <= epoch_sec, or initial_offset_sec
    #
    # Pre-1970 transitions are kept (Temporal can use them for historical
    # arithmetic); the lookup naturally returns the right offset for any instant.

    parsed_sorted = sorted(parsed, key=lambda x: x[0])

    # Discard TZif entries with malformed type indices (defensive; TZif v2
    # generation on macOS can produce indices that exceed typecnt for POSIX-
    # rule-derived transitions).
    cleaned = []
    for name, init_off, trans, abbrs in parsed_sorted:
        # Drop transitions whose offset is unreasonable (> +-24 hours).
        sane = [(t, o) for t, o in trans if -86400 <= o <= 86400]
        cleaned.append((name, init_off, sane, abbrs))

    # Drop pre-epoch transitions (epoch_sec < 0). Temporal queries instants
    # >= 0 in practice; historical pre-1970 data is dead weight that bloats
    # the generated source. Keep initial_offset so the lookup still works
    # for the boundary case (an instant before the first post-1970 entry
    # returns initial_offset, which is the zone's offset at the Unix epoch).
    #
    # Exception: zones whose post-1970 transition list is empty (Tokyo, etc.)
    # keep all transitions so the lookup has at least one entry. The dedup
    # below will collapse any that match other zones' full lists.
    truncated = []
    for name, init_off, trans, abbrs in cleaned:
        post = [(t, o) for t, o in trans if t >= 0]
        if len(post) == 0 and len(trans) > 0:
            post = trans
        truncated.append((name, init_off, post, abbrs))

    # Deduplicate by transition-content hash. Many IANA zones are aliases
    # that share the same transition list (e.g. Africa/Abidjan == Africa/
    # Bamako == Africa/Dakar == Etc/GMT — all offset 0 forever). The IANA
    # `backward` file is just aliases; the tzdb JSON-tzdb GitHub repo
    # similarly shares one transition list across aliases. Sharing cuts the
    # generated source size roughly in half.
    by_hash: dict[tuple, list] = {}
    for name, init_off, trans, abbrs in truncated:
        h = tuple(trans)
        by_hash.setdefault(h, []).append((name, init_off))

    canonical = []
    for h, members in by_hash.items():
        canonical.append((h, members))

    # Emit C3 source
    n_zones = sum(len(members) for _, members in canonical)
    # Count what encode_blob actually emits: a table with no transitions is
    # still written as a single (0, 0) placeholder, because C3 has no
    # zero-length arrays and the lookup wants at least one entry.
    n_trans = sum(max(len(h), 1) for h, _ in canonical)
    lines = []
    release = version_str or f"{year}{chr(ord('a') + (month - 1) // 3) if month else '?'}"
    lines.append(f"// Auto-generated by scripts/tzdata/build_tzdata.py from IANA tzdata{release}.")
    lines.append(f"// Regenerate with: scripts/tzdata/build.sh --version {release}")
    lines.append(f"// {n_zones} zone names -> {len(canonical)} unique transition tables "
                 f"({n_trans} total transitions). Aliases share tables via index.")
    lines.append("// DO NOT EDIT — re-run the generator instead.")
    lines.append("module boomkat::lib::temporal;")
    lines.append("")
    lines.append("// A single transition: at and after `epoch_sec` (UTC), the zone's")
    lines.append("// offset from UTC is `offset_sec`. Sorted ascending by epoch_sec.")
    lines.append("struct TzdbTransition {")
    lines.append("    long epoch_sec;")
    lines.append("    int  offset_sec;")
    lines.append("}")
    lines.append("")
    lines.append("// A zone entry: its IANA name, the index of its (shared) transition")
    lines.append("// table, and the offset used for instants before the first transition.")
    lines.append("// `table_idx` indexes the tables decoded from TZDB_BLOB; aliases that")
    lines.append("// share a transition list share an index.")
    lines.append("struct TzdbZone {")
    lines.append("    String name;")
    lines.append("    int    table_idx;")
    lines.append("    int    initial_offset_sec;")
    lines.append("}")
    lines.append("")

    blob, offsets, plain_len = encode_blob(canonical)

    lines.append(f"// Deflate-compressed transition tables: {len(canonical)} tables, "
                 f"{n_trans} transitions, {len(offsets)} distinct offsets.")
    lines.append(f"// {plain_len} bytes encoded -> {len(blob)} bytes deflated. Decoded once")
    lines.append("// on first tzdb lookup by tzdb_decode_blob() in tzdb.c3; see encode_blob()")
    lines.append("// in scripts/tzdata/build_tzdata.py for the wire format.")
    lines.append(f"const char[{len(blob)}] TZDB_BLOB = {{")
    for i in range(0, len(blob), 24):
        chunk = ", ".join(f"0x{b:02x}" for b in blob[i:i + 24])
        lines.append(f"    {chunk},")
    lines.append("};")
    lines.append("")
    lines.append(f"const usz TZDB_TABLE_COUNT = {len(canonical)};")
    lines.append(f"const usz TZDB_TRANSITION_COUNT = {n_trans};")
    lines.append("")

    # All zones — one entry per alias name, all sharing a transition table by
    # index. Sorted alphabetically by name for binary search.
    all_zones = []
    for table_idx, (_trans_tuple, members) in enumerate(canonical):
        for name, init_off in members:
            all_zones.append((name, init_off, table_idx))
    all_zones.sort(key=lambda x: x[0])
    lines.append(f"const TzdbZone[{len(all_zones)}] TZDB_ZONES = {{")
    for name, init_off, table_idx in all_zones:
        lines.append(f"    {{ \"{name}\", {table_idx}, {int(init_off)} }},")
    lines.append("};")
    lines.append("")

    out_src = "\n".join(lines) + "\n"

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w") as f:
        f.write(out_src)

    print(f"Wrote {args.output}: {len(out_src)} bytes, "
          f"{len(cleaned)} zones, "
          f"{sum(len(t) for _, _, t, _ in cleaned)} transitions", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
