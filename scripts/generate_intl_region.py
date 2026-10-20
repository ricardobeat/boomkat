#!/usr/bin/env python3
"""Generate the per-region and per-language facts behind Intl.Locale from ICU 78.3 / CLDR 48.

Region data (calendar preferences, week data, hour cycles) comes from ICU's
supplementalData.txt. Time zones per region come from IANA's zone.tab,
summarized in scripts/intl/zone_regions.txt. Collation types, default
numbering systems and right-to-left scripts come from the ICU API through
scripts/intl/dump_locale_info.c (output in scripts/intl/locale_info.txt).

Tables hold packed integers and offsets into NUL-separated name pools, so
they sit in read-only data and need no load-time fixups.
"""
import argparse
from pathlib import Path
from generate_intl_english import resource
from generate_intl_dates import tzdb_names
from generate_intl_locale import region_code, lang_code

HERE = Path(__file__).resolve().parent

# Calendar IDs in supplementalData are ICU's; the locale extension uses the
# BCP 47 type.
CALENDAR_TYPE = {'gregorian': 'gregory', 'ethiopic-amete-alem': 'ethioaa'}
HOUR_CYCLE = {'H': 'h23', 'h': 'h12', 'hb': 'h12', 'hB': 'h12', 'K': 'h11', 'k': 'h24'}
HOUR_CYCLES = ['h11', 'h12', 'h23', 'h24']


def c3_array(name, ctype, values, per_line=12, comment=None):
    lines = []
    if comment:
        lines.append(comment)
    lines.append(f'const {ctype}[*] {name} = {{')
    for i in range(0, len(values), per_line):
        lines.append('    ' + ', '.join(str(v) for v in values[i:i + per_line]) + ',')
    lines.append('};')
    return '\n'.join(lines)


class Pool:
    """NUL-separated names addressed by byte offset, with a leading NUL so
    offset 0 means none."""

    def __init__(self):
        self.data = bytearray(b'\0')
        self.at = {}

    def add(self, s):
        if s not in self.at:
            self.at[s] = len(self.data)
            self.data += s.encode() + b'\0'
        return self.at[s]


def dedupe_lists(lists):
    """Concatenates the distinct lists as length-prefixed byte runs. Returns
    the blob and a map from list to its offset."""
    blob = bytearray(b'\0')  # offset 0: the empty list
    at = {(): 0}
    for items in lists:
        key = tuple(items)
        if key not in at:
            at[key] = len(blob)
            blob.append(len(key))
            blob.extend(key)
    return blob, at


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, default=Path('src/builtins/intl_region_data.c3'))
    args = parser.parse_args()
    if '#define U_ICU_VERSION "78.3"' not in (args.source/'common/unicode/uvernum.h').read_text():
        parser.error('Use ICU 78.3 sources')
    supp = resource(args.source/'data/misc/supplementalData.txt')
    out = []

    # --- Calendars per region -------------------------------------------
    names = []
    def calendar_index(name):
        name = CALENDAR_TYPE.get(name, name)
        if name not in names:
            names.append(name)
        return names.index(name)
    prefs = {region_code(r): [calendar_index(c) for c in cals] for r, cals in supp['calendarPreferenceData'].items()}
    names_sorted = sorted(names)
    remap = {names.index(n): i for i, n in enumerate(names_sorted)}
    prefs = {r: [remap[i] for i in cals] for r, cals in prefs.items()}
    blob, at = dedupe_lists(prefs.values())
    pool = Pool()
    for n in names_sorted:
        pool.add(n)
    keys = sorted(prefs)
    pairs = []
    for r in keys:
        pairs += [r, at[tuple(prefs[r])]]
    out.append(c3_array('INTL_CALENDAR_NAMES', 'char', list(pool.data), 24, '// Calendar types in sorted order.'))
    out.append(c3_array('INTL_CALENDAR_LISTS', 'char', list(blob), 24, '// Length-prefixed lists of indices into INTL_CALENDAR_NAMES.'))
    out.append(c3_array('INTL_CALENDAR_REGIONS', 'ushort', pairs, 8, '// (region code, INTL_CALENDAR_LISTS offset) pairs sorted by region.'))

    # --- Week data per region -------------------------------------------
    def js_day(icu_day):  # ICU counts 1 = Sunday; ECMA-402 counts 1 = Monday
        return (icu_day + 5) % 7 + 1
    week = {}
    for region, v in supp['weekData'].items():
        first, _min_days, w_start, w_start_ms, w_end, w_end_ms = (int(x) for x in v)
        end = w_end if w_end_ms != 0 else (w_end + 5) % 7 + 1
        mask, day = 0, w_start
        while True:
            mask |= 1 << (js_day(day) - 1)
            if day == end:
                break
            day = day % 7 + 1
        week[region_code(region)] = js_day(first) | mask << 3
    pairs = []
    for r in sorted(week):
        pairs += [r, week[r]]
    out.append(c3_array('INTL_WEEK_REGIONS', 'ushort', pairs, 8,
                        '// (region code, first day | weekend mask << 3) pairs sorted by region. Days count from 1 = Monday;\n'
                        '// bit d - 1 of the mask marks day d as weekend.'))

    # --- Hour cycles per region and language_region ----------------------
    time = {}
    for key, entry in supp['timeData'].items():
        lang, _, region = key.rpartition('_')
        k = (lang_code(lang) if lang else 0) << 11 | region_code(region)
        cycles = []
        for c in entry['preferred'] + entry['allowed']:
            hc = HOUR_CYCLES.index(HOUR_CYCLE[c])
            if hc not in cycles:
                cycles.append(hc)
        value = len(cycles)
        for i, hc in enumerate(cycles):
            value |= hc << 3 + 2 * i
        time[k] = value
    ks = sorted(time)
    out.append(c3_array('INTL_TIME_KEYS', 'uint', ks, 8, '// Sorted keys: language code << 11 | region code, with language 0 for region-only entries.'))
    out.append(c3_array('INTL_TIME_VALUES', 'ushort', [time[k] for k in ks], 12,
                        '// Entry count in bits 0-2, then 2 bits per hour cycle (index into h11, h12, h23, h24), preferred first.'))

    # --- Time zones per region -------------------------------------------
    tzdb = tzdb_names(HERE.parent/'src/lib/temporal/tzdata_generated.c3')
    index = {n: i for i, n in enumerate(tzdb)}
    by_region = {}
    for line in (HERE/'intl/zone_regions.txt').read_text().splitlines():
        region, zone = line.split('\t')
        if zone in index:
            by_region.setdefault(region_code(region), []).append(index[zone])
    keys = sorted(by_region)
    zones, starts = [], []
    for r in keys:
        starts.append(len(zones))
        zones += sorted(by_region[r])
    starts.append(len(zones))
    out.append(c3_array('INTL_ZONE_REGIONS', 'ushort', keys, 12, '// Regions with time zones, sorted.'))
    out.append(c3_array('INTL_ZONE_REGION_AT', 'ushort', starts, 12, '// Start of each region\'s run in INTL_ZONE_REGION_ZONES, plus the end.'))
    out.append(c3_array('INTL_ZONE_REGION_ZONES', 'ushort', zones, 12, '// tzdb zone indices, ascending (tzdb order is name order) within each region.'))

    # --- Collations, numbering systems and scripts ------------------------
    collations, numbering, rtl, digits, scattered = {}, {}, [], {}, {}
    for line in (HERE/'intl/locale_info.txt').read_text().splitlines():
        kind, *rest = line.split('\t')
        if kind == 'collation' and '_' not in rest[0]:
            collations[rest[0]] = sorted(rest[1].split(',')) if rest[1] else []
        elif kind == 'numbering':
            numbering[rest[0]] = rest[1]
        elif kind == 'rtl':
            rtl.append(rest[0])
        elif kind == 'digits':
            digits[rest[0]] = int(rest[1])
        elif kind == 'scattered':
            scattered[rest[0]] = [int(c) for c in rest[1:]]
            digits[rest[0]] = scattered[rest[0]][0]
    root = ['emoji', 'eor']
    types = sorted({t for lst in collations.values() for t in lst} | set(root))
    pool = Pool()
    for t in types:
        pool.add(t)
    lists = [[types.index(t) for t in collations[l]] for l in sorted(collations) if collations[l] != root]
    root_list = [types.index(t) for t in root]
    blob, at = dedupe_lists([root_list] + lists)
    langs = sorted(l for l in collations if collations[l] != root)
    out.append(c3_array('INTL_COLLATION_TYPES', 'char', list(pool.data), 24, '// Collation types in sorted order.'))
    out.append(c3_array('INTL_COLLATION_LISTS', 'char', list(blob), 24, '// Length-prefixed lists of indices into INTL_COLLATION_TYPES.'))
    out.append(f'const usz INTL_COLLATION_ROOT = {at[tuple(root_list)]};  // offset of the list for languages without their own')
    out.append(c3_array('INTL_COLLATION_LANGS', 'ushort', [lang_code(l) for l in langs], 12, '// Languages with their own list, sorted by language code.'))
    out.append(c3_array('INTL_COLLATION_LANG_LISTS', 'ushort',
                        [at[tuple(types.index(t) for t in collations[l])] for l in langs], 12, '// INTL_COLLATION_LISTS offset for each language.'))

    pool = Pool()
    systems = sorted(set(numbering.values()))
    for s in systems:
        pool.add(s)
    entries = {}
    for loc, system in numbering.items():
        lang, _, region = loc.partition('_')
        base = numbering.get(lang, 'latn')
        if region:
            if system != base:
                entries[lang_code(lang) << 11 | region_code(region)] = system
        elif system != 'latn':
            entries[lang_code(lang) << 11] = system
    ks = sorted(entries)
    out.append(c3_array('INTL_NUMBERING_NAMES', 'char', list(pool.data), 24, '// Default numbering systems, sorted; latn is the fallback and is also listed.'))
    out.append(c3_array('INTL_NUMBERING_KEYS', 'uint', ks, 8, '// Sorted keys: language code << 11 | region code (0 for the language default).'))
    out.append(c3_array('INTL_NUMBERING_VALUES', 'ushort', [pool.at[entries[k]] for k in ks], 12, '// INTL_NUMBERING_NAMES offset for each key.'))
    # Decimal numbering systems with ten consecutive digits, in name order.
    names = sorted(digits)
    pool = Pool()
    for n in names:
        pool.add(n)
    out.append(c3_array('INTL_DIGIT_NAMES', 'char', list(pool.data), 24,
                        '// Names of the numbering systems NumberFormat can render, sorted.'))
    out.append(c3_array('INTL_DIGIT_NAME_AT', 'ushort', [pool.at[n] for n in names], 12, '// Offset of each name in INTL_DIGIT_NAMES.'))
    out.append(c3_array('INTL_DIGIT_ZEROS', 'uint', [digits[n] for n in names], 8, '// Code point of each system\'s digit zero.'))
    out.append(f'const usz INTL_DIGIT_LATN = {names.index("latn")};')
    assert len(scattered) == 1, 'one system with non-consecutive digits is expected'
    (odd, odd_digits), = scattered.items()
    out.append(f'const usz INTL_DIGIT_SCATTERED = {names.index(odd)};  // {odd}')
    out.append(c3_array('INTL_SCATTERED_DIGITS', 'uint', odd_digits, 10, '// Digit code points of INTL_DIGIT_SCATTERED.'))
    out.append(f'const String INTL_RTL_SCRIPTS = "{"".join(sorted(rtl))}"; // four-letter codes')

    header = ('// Generated by scripts/generate_intl_region.py from ICU 78.3 / CLDR 48 and IANA zone.tab.\n'
              '// Do not edit.\nmodule boomkat::builtins;\n\n')
    args.out.write_text(header + '\n\n'.join(out) + '\n')
    print(f'{args.out}: {len(by_region)} zone regions, {len(week)} week regions, {len(time)} time entries, {len(langs)} collation languages')


if __name__ == '__main__':
    main()
