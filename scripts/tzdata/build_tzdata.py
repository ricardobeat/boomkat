#!/usr/bin/env python3
"""
Generate src/lib/temporal/tzdata_generated.c3 from IANA TZif files.

Input is two `zic` outputs of the same release: `-b slim` (explicit
transitions until each zone's POSIX TZ footer rule takes over) is encoded,
and `-b fat` (rules expanded through 2037) is the reference the encoding is
checked against before anything is written.

The tables are read in place from read-only data; nothing is decoded into the
heap. Transitions are stored the way tzdata writes them, as rules:

    TZDB_OFFSETS  int[]    every distinct UTC offset
    TZDB_RULES    uint[]   distinct (month, day rule, wall time) triples
    TZDB_TABLES   char[]   one record per distinct transition table
    TZDB_TABLE_AT ushort[] record start for each table
    TZDB_NAMES    char[]   zone names, sorted and front-coded in blocks
    TZDB_NAME_AT  ushort[] start of each block of TZDB_NAME_BLOCK names
    TZDB_ZONE_TABLE ushort[] table index for each zone, in name order

A rule is packed into 32 bits: month in bits 0-3; the day rule in bits 4-11,
either a fixed day of the month (< 0x80) or 0x80 | weekday << 3 | week, where
week 1-4 means the first weekday on or after day 1, 8, 15 or 22 and week 5
means the last one; and the wall time in seconds, signed, in bits 12-31. The
wall time is read on the offset in effect before the transition, which is
how both tzdata rules and POSIX TZ strings are written.

A table record is byte-aligned:

    initial offset index      1 byte (offset before the first transition)
    transition count n        1 byte
    if n > 0:
      first wall year         2 bytes, little-endian, signed
      rule palette            count byte, then count rule indices (ushort LE)
      offset palette          count byte, then count offset index bytes
    footer                    0, or 1 then std and dst offset index bytes and
                              start and end rule indices (ushort LE)
    n transitions             bit-packed LSB first: rule palette index,
                              offset palette index, then a 2-bit year step
                              (3 escapes to a 16-bit zigzag step)

Transitions that keep the offset in effect are dropped, except a zone's last
transition, after which its footer rule applies. Pre-1970 transitions
are dropped, except for a zone whose whole history is
pre-1970; `initial offset` is the offset in effect at the Unix epoch.

Run scripts/tzdata/build.sh, which fetches the pinned IANA release, compiles
it both ways, and calls this script. The result is committed.
"""

import argparse
import calendar
import datetime
import os
import re
import struct
import sys

NAME_BLOCK = 16
EPOCH = datetime.datetime(1970, 1, 1)
CHECK_UNTIL = 2**31  # fat TZif data stops at 2037; compare up to there


def _zigzag16(v: int) -> int:
    return ((v << 1) ^ (v >> 15)) & 0xFFFF


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


def tzif_footer(path):
    data = open(path, "rb").read().rstrip(b"\n")
    return data[data.rindex(b"\n") + 1:].decode()


# ---- POSIX TZ footers ----

def _posix_time(text):
    sign = -1 if text.startswith("-") else 1
    parts = [int(p) for p in text.lstrip("+-").split(":")]
    parts += [0] * (3 - len(parts))
    return sign * (parts[0] * 3600 + parts[1] * 60 + parts[2])


def parse_posix(footer):
    """(std_offset, dst_offset, start_rule, end_rule) as UTC offsets, or None
    when the footer has no daylight saving time. POSIX offsets count west."""
    m = re.fullmatch(r"(<[^>]+>|[A-Za-z]+)([-+]?[\d:]+)(?:(<[^>]+>|[A-Za-z]+)([-+]?[\d:]+)?(?:,(.*))?)?", footer)
    if not m:
        raise ValueError(f"unparsed TZ footer {footer!r}")
    std = -_posix_time(m.group(2))
    if not m.group(3):
        return None
    dst = -_posix_time(m.group(4)) if m.group(4) else std + 3600
    rules = []
    for spec in m.group(5).split(","):
        date, _, time = spec.partition("/")
        mm = re.fullmatch(r"M(\d+)\.(\d)\.(\d)", date)
        if not mm:
            raise ValueError(f"unsupported TZ rule {spec!r} in {footer!r}")
        month, week, weekday = (int(x) for x in mm.groups())
        rules.append((month, 0x80 | weekday << 3 | week, _posix_time(time) if time else 7200))
    return std, dst, rules[0], rules[1]


# ---- rules ----

def rule_day(year, month, dayspec):
    if dayspec < 0x80:
        return dayspec
    weekday, week = (dayspec >> 3) & 7, dayspec & 7
    length = calendar.monthrange(year, month)[1]
    if week == 5:
        day = length
        while (calendar.weekday(year, month, day) + 1) % 7 != weekday:
            day -= 1
        return day
    day = 7 * (week - 1) + 1
    while (calendar.weekday(year, month, day) + 1) % 7 != weekday:
        day += 1
    return day


def rule_epoch(year, rule, offset_before):
    month, dayspec, secs = rule
    days = (datetime.date(year, month, rule_day(year, month, dayspec)) - EPOCH.date()).days
    return days * 86400 + secs - offset_before


def wall_rules(epoch, offset_before):
    """The fixed-day and weekday rules that both reproduce this transition."""
    w = EPOCH + datetime.timedelta(seconds=epoch + offset_before)
    secs = w.hour * 3600 + w.minute * 60 + w.second
    weekday = (w.weekday() + 1) % 7
    length = calendar.monthrange(w.year, w.month)[1]
    week = 5 if w.day + 7 > length else (w.day - 1) // 7 + 1
    return w.year, (w.month, w.day, secs), (w.month, 0x80 | weekday << 3 | week, secs)


def pack_rule(rule):
    month, dayspec, secs = rule
    if not (-(1 << 19) <= secs < (1 << 19)):
        raise ValueError(f"rule time {secs} does not fit 20 bits")
    return (month | dayspec << 4 | (secs & 0xFFFFF) << 12) & 0xFFFFFFFF


def footer_transitions(footer, year):
    std, dst, start, end = footer
    pair = [(rule_epoch(year, start, std), dst), (rule_epoch(year, end, dst), std)]
    return sorted(pair)


def expand(table, until):
    """Every transition of a decoded table before `until`, as the C3 side
    computes them."""
    init, trans, footer = table
    out = [p for p in trans if p[0] < until]
    if footer:
        last = trans[-1][0] if trans else None
        year = (EPOCH + datetime.timedelta(seconds=last)).year - 1 if trans else 1970
        while True:
            pairs = [p for p in footer_transitions(footer, year) if last is None or p[0] > last]
            if pairs and pairs[0][0] >= until:
                break
            out += [p for p in pairs if p[0] < until]
            year += 1
    return out


class Bits:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def put(self, value, width):
        self.acc |= value << self.n
        self.n += width
        while self.n >= 8:
            self.out.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def flush(self):
        if self.n:
            self.out.append(self.acc & 0xFF)
        return bytes(self.out)


def width(count):
    return (count - 1).bit_length()


def encode_table(init, trans, footer, offsets, rules):
    """Encode one table; returns the record and the transitions it decodes to."""
    out = bytearray([offsets.index(init), len(trans)])
    if len(trans) > 255:
        raise ValueError("transition count does not fit a byte")
    prev = init
    seq = []
    for epoch, off in trans:
        year, fixed, weekly = wall_rules(epoch, prev)
        seq.append((year, fixed, weekly, off))
        prev = off
    repeats = {}
    for _, _, weekly, _ in seq:
        repeats[weekly] = repeats.get(weekly, 0) + 1
    chosen = [(year, weekly if repeats[weekly] > 1 else fixed, off) for year, fixed, weekly, off in seq]
    rule_pal = sorted({r for _, r, _ in chosen}, key=pack_rule)
    off_pal = sorted({o for _, _, o in chosen})
    for r in rule_pal + ([footer[2], footer[3]] if footer else []):
        if r not in rules:
            rules.append(r)
    if trans:
        out += struct.pack("<hB", chosen[0][0], len(rule_pal))
        for r in rule_pal:
            out += struct.pack("<H", rules.index(r))
        out.append(len(off_pal))
        out += bytes(offsets.index(o) for o in off_pal)
    if footer:
        out += bytes([1, offsets.index(footer[0]), offsets.index(footer[1])])
        out += struct.pack("<HH", rules.index(footer[2]), rules.index(footer[3]))
    else:
        out.append(0)
    bits = Bits()
    year = chosen[0][0] if chosen else 0
    for y, r, o in chosen:
        bits.put(rule_pal.index(r), width(len(rule_pal)))
        bits.put(off_pal.index(o), width(len(off_pal)))
        step = y - year
        if 0 <= step <= 2:
            bits.put(step, 2)
        else:
            bits.put(3, 2)
            bits.put(_zigzag16(step), 16)
        year = y
    out += bits.flush()
    # Decode the way tzdb.c3 does, so a mismatch fails here and not at runtime.
    decoded = []
    prev = init
    for y, r, o in chosen:
        decoded.append((rule_epoch(y, r, prev), o))
        prev = o
    if decoded != list(trans):
        raise ValueError("table does not decode to its transitions")
    return bytes(out)


def changes(init, trans):
    """Drop transitions that keep the offset in effect (an abbreviation or
    isdst change): no lookup can observe them. The last one stays, because
    the footer rule applies only after it."""
    out = []
    prev = init
    for i, (t, o) in enumerate(trans):
        if o != prev or i == len(trans) - 1:
            out.append((t, o))
        prev = o
    return out


def zone_tables(zi_dir):
    """{name: (initial_offset, transitions, footer_text)} for every zone."""
    skip_top = {"posixrules", "localtime", "leapseconds", "iso3166.tab", "zone.tab", "zone1970.tab", "tzdata.zi", "+VERSION"}
    zones = {}
    for directory, subdirs, files in os.walk(zi_dir):
        subdirs[:] = sorted(x for x in subdirs if not x.startswith(".") and x not in {"posix", "right"})
        for entry in sorted(files):
            if entry in skip_top or entry.startswith(("+", ".")):
                continue
            full = os.path.join(directory, entry)
            name = os.path.relpath(full, zi_dir).replace(os.sep, "/")
            init, trans, _ = parse_tzif(full)
            trans = [(t, o) for t, o in trans if -86400 <= o <= 86400]
            post = [(t, o) for t, o in trans if t >= 0] or trans
            zones[name] = (init, changes(init, post), tzif_footer(full))
    return zones


def front_code(names):
    data = bytearray()
    starts = []
    prev = b""
    for i, name in enumerate(names):
        raw = name.encode()
        shared = 0
        if i % NAME_BLOCK == 0:
            starts.append(len(data))
        else:
            while shared < min(len(raw), len(prev), 255) and raw[shared] == prev[shared]:
                shared += 1
        data += bytes([shared, len(raw) - shared]) + raw[shared:]
        prev = raw
    return bytes(data), starts


def c_array(kind, name, values, per_line=16):
    lines = [f"const {kind}[{len(values)}] {name} = {{"]
    for i in range(0, len(values), per_line):
        lines.append("    " + ", ".join(str(v) for v in values[i:i + per_line]) + ",")
    lines.append("};")
    return lines


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--slim-dir", required=True, help="zic -b slim output")
    ap.add_argument("--fat-dir", required=True, help="zic -b fat output, the reference")
    ap.add_argument("--output", default="src/lib/temporal/tzdata_generated.c3")
    ap.add_argument("--tzdata-version", required=True, help="e.g. 2026c")
    args = ap.parse_args()

    slim = zone_tables(args.slim_dir)
    fat = zone_tables(args.fat_dir)
    if sorted(slim) != sorted(fat):
        raise SystemExit("slim and fat builds list different zones")
    names = sorted(slim)

    tables = {}
    zone_table = []
    for name in names:
        init, trans, footer_text = slim[name]
        footer = parse_posix(footer_text)
        if not footer and trans and footer_text and trans[-1][1] != -_posix_time(re.match(r"(?:<[^>]+>|[A-Za-z]+)([-+]?[\d:]+)", footer_text).group(1)):
            raise SystemExit(f"{name}: last transition disagrees with footer {footer_text}")
        expanded = expand((init, trans, footer), CHECK_UNTIL)
        reference = [(t, o) for t, o in fat[name][1] if t < CHECK_UNTIL]
        expanded = changes(init, expanded)
        reference = changes(init, reference)
        if expanded != reference or fat[name][0] != init:
            raise SystemExit(f"{name}: slim + footer differs from the fat expansion")
        key = (init, tuple(trans), footer)
        zone_table.append(tables.setdefault(key, len(tables)))

    offsets = sorted({o for init, trans, footer in tables for o in [init] + [x for _, x in trans] + (list(footer[:2]) if footer else [])})
    if len(offsets) > 256:
        raise SystemExit("more than 256 distinct offsets")
    rules = []
    stream = bytearray()
    table_at = []
    for init, trans, footer in tables:
        table_at.append(len(stream))
        stream += encode_table(init, list(trans), footer, offsets, rules)
    table_at.append(len(stream))
    names_data, name_at = front_code(names)
    for limit, what in ((len(stream), "table stream"), (len(names_data), "name pool")):
        if limit > 65535:
            raise SystemExit(f"{what} exceeds 16-bit offsets")

    n_trans = sum(len(t) for _, t, _ in tables)
    lines = [
        f"// Auto-generated by scripts/tzdata/build_tzdata.py from IANA tzdata{args.tzdata_version}.",
        f"// Regenerate with: scripts/tzdata/build.sh --version {args.tzdata_version}",
        f"// {len(names)} zones, {len(tables)} tables, {n_trans} explicit transitions, {len(rules)} rules,",
        f"// {len(offsets)} offsets. See build_tzdata.py for the encoding. DO NOT EDIT.",
        "module boomkat::lib::temporal;",
        "",
        f"const usz TZDB_NAME_BLOCK = {NAME_BLOCK};",
    ]
    lines += c_array("int", "TZDB_OFFSETS", offsets, 12)
    lines += c_array("uint", "TZDB_RULES", [f"0x{pack_rule(r):08x}" for r in rules], 8)
    lines += c_array("ushort", "TZDB_TABLE_AT", table_at)
    lines += c_array("ushort", "TZDB_ZONE_TABLE", zone_table)
    lines += c_array("ushort", "TZDB_NAME_AT", name_at)
    lines += c_array("char", "TZDB_TABLES", [f"0x{b:02x}" for b in stream], 24)
    lines += c_array("char", "TZDB_NAMES", [f"0x{b:02x}" for b in names_data], 24)
    out_src = "\n".join(lines) + "\n"
    with open(args.output, "w") as f:
        f.write(out_src)
    print(f"Wrote {args.output}: {len(names)} zones, {len(tables)} tables, {n_trans} transitions, "
          f"{len(stream)} table bytes, {len(names_data)} name bytes, {len(rules)} rules", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
