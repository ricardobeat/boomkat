#!/usr/bin/env python3
"""Extract English Gregorian date patterns and timezone display names from ICU 78.3."""
import argparse
import datetime
import json
from pathlib import Path
from generate_intl_english import resource


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
    out = ['// Generated from ICU 78.3 / CLDR 48. Unicode License V3: vendor/intl/LICENSE.',
           '// Regenerate with scripts/generate_intl_dates.py --source <icu/source>.',
           'module boomkat::builtins;',
           'struct IntlDatePattern { String skeleton; String pattern; }',
           'struct IntlDateInterval { String skeleton; char field; String pattern; }',
           'struct IntlZoneName { ushort zone; long from_sec; long until_sec; ushort generic; ushort standard; ushort daylight; ushort short_generic; ushort short_standard; ushort short_daylight; }',
           'const IntlDatePattern[*] INTL_DATE_PATTERNS = {']
    for skeleton, pattern in gregory['availableFormats'].items():
        if isinstance(pattern, list) and not any(c in skeleton for c in 'QwW'):
            out.append('    { '+string(skeleton)+', '+string(pattern[0])+' },')
    out += ['};', 'const String[*] INTL_DATE_STYLES = {']
    out += ['    '+string(p)+',' for p in gregory['DateTimePatterns'][:8]]
    out += ['};', 'const IntlDateInterval[*] INTL_DATE_INTERVALS = {']
    for sk, fields in gregory['intervalFormats'].items():
        if isinstance(fields, dict):
            for f, pattern in fields.items():
                out.append('    { '+string(sk)+", '"+f+"', "+string(pattern[0])+' },')
    out += ['};', 'const IntlZoneName[*] INTL_ZONE_NAMES = {']
    pool = bytearray(b'\0')
    offsets = {'': 0}
    def intern(text):
        if text not in offsets:
            offsets[text] = len(pool)
            pool.extend(text.encode('utf-8') + b'\0')
        return str(offsets[text])
    names = resource(data/'zone/en.txt')['zoneStrings']
    zones = resource(data/'misc/metaZones.txt')['metazoneInfo']
    def epoch(s):
        return int(datetime.datetime.strptime(s,'%Y-%m-%d %H:%M').replace(tzinfo=datetime.timezone.utc).timestamp())
    for zone, periods in sorted(zones.items()):
        zone = zone.strip('"').replace(':','/')
        for period in periods:
            n = names.get('"meta:'+period[0]+'"', {})
            if not n:continue
            start = epoch(period[1]) if len(period)>1 else -9223372036854775807
            end = epoch(period[2]) if len(period)>2 else 9223372036854775807
            out.append('    { '+', '.join([intern(zone), str(start)+'L', str(end)+'L']+[intern(n.get(k,[''])[0]) for k in ['lg','ls','ld','sg','ss','sd']])+' },')
    out += ['};']
    types = resource(data/'misc/timezoneTypes.txt')
    aliases = types.get('typeAlias',{}).get('timezone',{}).copy()
    primary = types.get('ianaMap',{}).get('timezone',{})
    aliases.update(primary)
    out += ['const IntlDatePattern[*] INTL_ZONE_ALIASES = {']
    for alias, target in sorted(aliases.items()):
        target = primary.get(target[0].replace('/', ':'), primary.get('\"'+target[0].replace('/', ':')+'\"', target))
        out.append('    { '+string(alias.strip('"').replace(':','/'))+', '+string(target[0].replace(':','/'))+' },')
    out += ['};']
    if len(pool) > 65535:raise ValueError('Date string pool exceeds 16-bit offsets')
    out += ['char[*] intl_date_strings @private = {']
    for i in range(0, len(pool), 24):
        out += ['    '+', '.join(f'0x{b:02x}' for b in pool[i:i+24])+',']
    out += ['};']
    args.out.write_text('\n'.join(out)+'\n')


if __name__ == '__main__':main()
