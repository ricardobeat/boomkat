#!/usr/bin/env python3
"""Generate the locale-identifier data (aliases and likely subtags) from ICU 78.3 / CLDR 48.

Reads ICU's text resources for the CLDR alias tables and the keyword
type map, plus scripts/intl/likely_subtags.txt (see dump_likely_subtags.c).
"""
import argparse
import re
from pathlib import Path
from generate_intl_english import resource

HERE = Path(__file__).resolve().parent

# CLDR transform.xml: deprecated m0 values and their preferred replacements.
TFIELD_ALIASES = {('m0', 'names'): 'prprname'}


def is_variant(s):
    return (5 <= len(s) <= 8 and s.isalnum()) or (len(s) == 4 and s[0].isdigit() and s.isalnum())


def is_region(s):
    return (len(s) == 2 and s.isalpha()) or (len(s) == 3 and s.isdigit())


def is_script(s):
    return len(s) == 4 and s.isalpha()


def uvalue(s):
    """True for a type that fits the unicode_locale_extensions `type` grammar."""
    return all(3 <= len(p) <= 8 and p.isalnum() for p in s.split('-'))


def region_code(r):
    if r.isdigit():
        return int(r)
    return 1000 + (ord(r[0]) - 65) * 26 + ord(r[1]) - 65


def lang_code(l):
    v = 0
    for i in range(3):
        v = v * 27 + (ord(l[i]) - 96 if i < len(l) else 0)
    return v


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, default=Path('src/builtins/intl_locale_data.c3'))
    args = parser.parse_args()
    if '#define U_ICU_VERSION "78.3"' not in (args.source/'common/unicode/uvernum.h').read_text():
        parser.error('Use ICU 78.3 sources')
    misc = args.source/'data/misc'
    alias = resource(misc/'metadata.txt')['alias']
    key_type = resource(misc/'keyTypeData.txt')
    tz_types = resource(misc/'timezoneTypes.txt')

    pool = bytearray(b'\0')
    offsets = {}

    def intern(text):
        if text not in offsets:
            offsets[text] = len(pool)
            pool.extend(text.encode() + b'\0')
        return offsets[text]

    def replacement(entry):
        return entry['replacement'][0]

    # Language aliases. A key is "lang" or "lang_sub..." where each sub is a
    # script, region or variant; keys with other shapes (grandfathered
    # "i-klingon", extlang forms) cannot occur in a well-formed identifier.
    plain, complex_ = {}, {}
    for key, entry in alias['language'].items():
        parts = key.split('_')
        value = replacement(entry)
        if len(parts) == 1:
            plain[key] = value
        elif len(parts[0]) >= 2 and all(is_script(p) or is_region(p) or is_variant(p) for p in parts[1:]):
            kinds = [('s' if is_script(p) else 'r' if is_region(p) else 'v') for p in parts[1:]]
            if kinds.count('s') > 1 or kinds.count('r') > 1:
                continue
            complex_[key] = value
    # Specific languages come before "und", which matches any language.
    complex_order = sorted(complex_, key=lambda k: (k.startswith('und_'), -len(k.split('_')), k))

    territory = {}
    for key, entry in alias['territory'].items():
        if is_region(key):  # ICU also lists three-letter ISO 3166 codes
            territory[region_code(key)] = replacement(entry)

    out = ['// Generated from ICU 78.3 / CLDR 48. Unicode License V3: vendor/intl/LICENSE.',
           '// Regenerate with scripts/generate_intl_locale.py --source <icu/source>.',
           'module boomkat::builtins;']

    def array(kind, name, values, per_line=12):
        out.append(f'const {kind}[*] {name} = {{')
        for i in range(0, len(values), per_line):
            out.append('    ' + ', '.join(str(v) for v in values[i:i + per_line]) + ',')
        out.append('};')

    def string_table(name, mapping, sort=True):
        keys = sorted(mapping) if sort else list(mapping)
        array('ushort', name, [x for k in keys for x in (intern(k), intern(mapping[k]))], 8)

    string_table('INTL_LANGUAGE_ALIASES', plain)
    string_table('INTL_LANGUAGE_COMPLEX_ALIASES', {k: complex_[k] for k in complex_order}, sort=False)
    string_table('INTL_SCRIPT_ALIASES', {k: replacement(v) for k, v in alias['script'].items()})
    string_table('INTL_VARIANT_ALIASES', {k: replacement(v) for k, v in alias['variant'].items()})
    string_table('INTL_SUBDIVISION_ALIASES', {k: replacement(v).split()[0] for k, v in alias['subdivision'].items()})

    # Territory aliases: sorted (code, replacement) ushort pairs. A
    # replacement is one region code, or 0x8000 | pool offset for a list.
    pairs = []
    for code in sorted(territory):
        repl = territory[code]
        if ' ' in repl:
            value = 0x8000 | intern(repl)
        else:
            value = region_code(repl)
        pairs += [code, value]
    array('ushort', 'INTL_REGION_ALIASES', pairs, 8)

    # Unicode extension value aliases, keyed "key:alias".
    bcp_keys = {}
    for long_name, short in key_type['keyMap'].items():
        short = short[0]
        bcp_keys[long_name] = short or long_name
    keyword = {}
    for long_key, types in key_type['typeMap'].items():
        if long_key not in bcp_keys or not isinstance(types, dict):
            continue
        key = bcp_keys[long_key]
        for name, bcp in types.items():
            name = name.strip('"')
            if bcp and bcp[0] and name != bcp[0] and uvalue(name):
                keyword[f'{key}:{name.lower()}'] = bcp[0]
    for key, types in key_type['bcpTypeAlias'].items():
        if isinstance(types, dict) and key != 'tz':
            for name, bcp in types.items():
                keyword[f'{key}:{name}'] = bcp[0]
    zone_ids = {name.strip('"'): bcp[0] for name, bcp in tz_types['typeMap']['timezone'].items()}
    for name, bcp in zone_ids.items():
        if uvalue(name) and name.lower() != bcp:
            keyword[f'tz:{name.lower()}'] = bcp
    # typeAlias maps an alternative IANA name to its canonical IANA zone.
    for name, target in tz_types['typeAlias']['timezone'].items():
        name = name.strip('"')
        zone = zone_ids.get(target[0].replace('/', ':'))
        if zone and uvalue(name) and name.lower() != zone:
            keyword[f'tz:{name.lower()}'] = zone
    for name, bcp in tz_types['bcpTypeAlias']['tz'].items():
        keyword[f'tz:{name}'] = bcp[0]
    string_table('INTL_KEYWORD_ALIASES', keyword)
    string_table('INTL_TFIELD_ALIASES', {f'{k}:{a}': v for (k, a), v in TFIELD_ALIASES.items()})

    # Likely subtags: entries sorted by key, packed as
    # lang(15 bits) | script index(8) | region index(9), index 0 = absent.
    rows = [line.split('\t') for line in (HERE/'intl/likely_subtags.txt').read_text().splitlines()]
    scripts, regions = [], []

    def script_index(s):
        if not s:
            return 0
        if s not in scripts:
            scripts.append(s)
        return scripts.index(s) + 1

    def region_index(r):
        if not r:
            return 0
        c = region_code(r)
        if c not in regions:
            regions.append(c)
        return regions.index(c) + 1

    for key, value in rows:
        for part in key.split('_')[1:]:
            (script_index if is_script(part) else region_index)(part)
        for part in value.split('_')[1:]:
            (script_index if is_script(part) else region_index)(part)
    scripts.sort()
    regions.sort()
    if len(scripts) > 255 or len(regions) > 511:
        raise SystemExit('likely-subtags index space exceeded')

    def pack(spec):
        parts = spec.split('_')
        lang = lang_code(parts[0])
        script = region = 0
        for part in parts[1:]:
            if is_script(part):
                script = scripts.index(part) + 1
            elif part:
                region = regions.index(region_code(part)) + 1
        return (lang << 17) | (script << 9) | region

    entries = sorted((pack(k), pack(v)) for k, v in rows)
    array('uint', 'INTL_LIKELY_KEYS', [f'0x{k:08x}' for k, _ in entries], 8)
    array('uint', 'INTL_LIKELY_VALUES', [f'0x{v:08x}' for _, v in entries], 8)
    out.append('const char[*] INTL_LIKELY_SCRIPTS = "' + ''.join(scripts) + '";')
    array('ushort', 'INTL_LIKELY_REGIONS', regions, 12)

    out.append('const char[*] INTL_LOCALE_POOL = {')
    for i in range(0, len(pool), 24):
        out.append('    ' + ', '.join(str(b) for b in pool[i:i + 24]) + ',')
    out.append('};')
    args.out.write_text('\n'.join(out) + '\n')
    print(f'{args.out}: pool {len(pool)} bytes, {len(entries)} likely entries')


if __name__ == '__main__':
    main()
