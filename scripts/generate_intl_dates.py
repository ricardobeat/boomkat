#!/usr/bin/env python3
"""Extract English Gregorian date patterns and timezone display names from ICU 78.3."""
import argparse
import datetime
import json
import re
import struct
from pathlib import Path
from generate_intl_english import resource


def tzdb_names(path):
    """Zone names in tzdb index order, decoded from the front-coded
    TZDB_NAMES table in tzdata_generated.c3."""
    source = path.read_text()
    match = re.search(r'TZDB_NAMES = \{(.*?)\};', source, re.S)
    data = bytes(int(x, 16) for x in re.findall(r'0x[0-9a-f]{2}', match.group(1)))
    names, prev, pos = [], b'', 0
    while pos < len(data):
        shared, rest = data[pos], data[pos + 1]
        prev = prev[:shared] + data[pos + 2:pos + 2 + rest]
        names.append(prev.decode())
        pos += 2 + rest
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, default=Path('src/builtins/intl_date_data.c3'))
    args = parser.parse_args()
    if '#define U_ICU_VERSION "78.3"' not in (args.source/'common/unicode/uvernum.h').read_text():
        parser.error('Use ICU 78.3 sources')
    data = args.source/'data'
    gregory = resource(data/'locales/en.txt')['calendar']['gregorian']
    def string(s):
        return json.dumps(s, ensure_ascii=False)
    pool = bytearray(b'\0')
    offsets = {'': 0}
    def intern(text):
        if text not in offsets:
            offsets[text] = len(pool)
            pool.extend(text.encode('utf-8') + b'\0')
        return str(offsets[text])
    out = ['// Generated from ICU 78.3 / CLDR 48. Unicode License V3: vendor/intl/LICENSE.',
           '// Regenerate with scripts/generate_intl_dates.py --source <icu/source>.',
           'module boomkat::builtins;',
           'struct IntlDatePattern { ushort skeleton; ushort pattern; }',
           'struct IntlDateInterval { ushort skeleton; char field; ushort pattern; }',
                      'const IntlDatePattern[*] INTL_DATE_PATTERNS = {']
    for skeleton, pattern in gregory['availableFormats'].items():
        if isinstance(pattern, list) and not any(c in skeleton for c in 'QwW'):
            out.append('    { '+intern(skeleton)+', '+intern(pattern[0])+' },')
    out += ['};', 'const ushort[*] INTL_DATE_STYLES = {']
    out += ['    '+intern(p)+',' for p in gregory['DateTimePatterns'][:8]]
    out += ['};', 'const IntlDateInterval[*] INTL_DATE_INTERVALS = {']
    for sk, fields in gregory['intervalFormats'].items():
        if isinstance(fields, dict):
            for f, pattern in fields.items():
                out.append('    { '+intern(sk)+", '"+f+"', "+intern(pattern[0])+' },')
    out += ['};']
    names = resource(data/'zone/en.txt')['zoneStrings']
    zones = resource(data/'misc/metaZones.txt')['metazoneInfo']
    def epoch(s):
        return int(datetime.datetime.strptime(s,'%Y-%m-%d %H:%M').replace(tzinfo=datetime.timezone.utc).timestamp())
    zone_ids = tzdb_names(Path(__file__).resolve().parent.parent/'src/lib/temporal/tzdata_generated.c3')
    zone_index = {name: i for i, name in enumerate(zone_ids)}
    # Name tuples (generic, standard, daylight, short forms) are shared by
    # every zone in a metazone; tuple 0 is the empty tuple.
    tuples = [(0,) * 6]
    tuple_index = {tuples[0]: 0}
    def tuple_of(meta):
        n = names['"meta:' + meta + '"']
        t = tuple(int(intern(n.get(k, [''])[0])) for k in ['lg', 'ls', 'ld', 'sg', 'ss', 'sd'])
        if t not in tuple_index:
            tuple_index[t] = len(tuples)
            tuples.append(t)
        return tuple_index[t]
    FOREVER = 2**31 - 1
    NEG = -2**63
    periods_of = {}
    for zone, periods in zones.items():
        zone = zone.strip('"').replace(':', '/')
        kept = [p for p in periods if names.get('"meta:' + p[0] + '"')]
        if kept:
            periods_of[zone_index[zone]] = kept
    stream = bytearray()
    zone_at = []
    def segment(meta, until):
        if until is None:
            stream.extend(struct.pack('<H', meta))
        else:
            if not 0 <= until < FOREVER:
                raise ValueError('period boundary outside 32 bits')
            stream.extend(struct.pack('<HI', meta | 0x8000, until))
    for i in range(len(zone_ids)):
        zone_at.append(len(stream))
        cursor = NEG
        last_open = False
        for p in periods_of.get(i, []):
            start = epoch(p[1]) if len(p) > 1 else NEG
            end = epoch(p[2]) if len(p) > 2 else None
            if end is not None and end >= epoch('9999-12-31 23:59'):
                end = None
            if start < cursor:
                raise ValueError('overlapping zone periods')
            if start > cursor:
                segment(0, start)
            segment(tuple_of(p[0]), end)
            last_open = end is None
            cursor = end if end is not None else FOREVER
        if i in periods_of and not last_open:
            segment(0, None)
    zone_at.append(len(stream))
    def table(kind, name, values, per_line):
        lines = ['const ' + kind + '[*] ' + name + ' = {']
        for j in range(0, len(values), per_line):
            lines.append('    ' + ', '.join(str(v) for v in values[j:j + per_line]) + ',')
        return lines + ['};']
    out += table('ushort', 'INTL_ZONE_META', [v for t in tuples for v in t], 12)
    out += table('ushort', 'INTL_ZONE_AT', zone_at, 16)
    out += table('char', 'INTL_ZONE_PERIODS', list(stream), 24)
    types = resource(data/'misc/timezoneTypes.txt')
    aliases = types.get('typeAlias',{}).get('timezone',{}).copy()
    primary = types.get('ianaMap',{}).get('timezone',{})
    aliases.update(primary)
    links = {}
    for alias, target in aliases.items():
        target = primary.get(target[0].replace('/', ':'), primary.get('\"'+target[0].replace('/', ':')+'\"', target))
        alias = alias.strip('"').replace(':', '/')
        target = target[0].replace(':', '/')
        # An alias or target that tzdb lacks can never be reached: zone
        # names are validated against tzdb before this table is consulted.
        if alias in zone_index and target in zone_index:
            links[zone_index[alias]] = zone_index[target]
    out += table('ushort', 'INTL_ZONE_ALIASES', [v for k in sorted(links) for v in (k, links[k])], 16)
    if len(pool) > 65535:raise ValueError('Date string pool exceeds 16-bit offsets')
    out += ['char[*] intl_date_strings @private = {']
    for i in range(0, len(pool), 24):
        out += ['    '+', '.join(f'0x{b:02x}' for b in pool[i:i+24])+',']
    out += ['};']
    args.out.write_text('\n'.join(out)+'\n')


if __name__ == '__main__':main()
