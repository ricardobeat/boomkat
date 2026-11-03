#!/usr/bin/env python3
"""Generate the Intl.DisplayNames tables from ICU 78.3 / CLDR 48.

Names of languages (with the dialect names), scripts, regions, variants,
calendar types, currencies and date-time fields, plus the language-name
patterns, share one sorted key table. Each key carries a one-letter kind prefix;
short-style variants have their own kind:

    l language   L language, short     s script   S script, short
    r region     R region, short       v variant  c calendar type
    f field      u currency name       p pattern and separator

Two files are written:
- src/builtins/intl_names_data.c3: the key table and the English names, always built.
- src/builtins/intl_names_extra_data.c3: the other locales, under @feat(INTL_FULL).

A locale row lists only the keys whose name differs from its parent row, the
nearest row on its CLDR parent chain. A row whose chain leaves the row set
(de reaches root) has no parent and does not inherit English. Names sit in one
NUL-separated pool per row, addressed by 16-bit offsets, so the tables live in
read-only data and need no load-time fixups.
"""
import argparse
from pathlib import Path
from generate_intl_english import resource
from generate_intl_locales import Chains, LOCALES, get_path, c_array, c_pool

CALENDAR_TYPE = {'gregorian': 'gregory', 'ethiopic-amete-alem': 'ethioaa'}
FIELDS = ['era', 'year', 'quarter', 'month', 'week', 'weekday', 'day', 'dayperiod', 'hour', 'minute', 'second', 'zone']
NO_PARENT = 255
# Statistics group the kinds by DisplayNames type.
TYPE_OF_KIND = {'l': 'language', 'L': 'language', 'v': 'language', 'p': 'language', 's': 'script', 'S': 'script',
                'r': 'region', 'R': 'region', 'u': 'currency', 'c': 'calendar', 'f': 'dateTimeField'}


def first(value):
    return value[0] if isinstance(value, list) else value


def merged(chains, dirname, locale_id, path):
    """The table at `path`, its entries merged along the locale's parent chain."""
    out = {}
    for ident in reversed(chains.chain(locale_id)):
        node = get_path(chains.file(dirname, ident) or {}, path)
        if isinstance(node, dict):
            out.update(node)
    return out


def field_name(chains, locale_id, key):
    """A field's display name. A locale's field table may lack the name, which then comes from the
    parent; the narrow field of root aliases the short one, and short aliases the long."""
    for ident in chains.chain(locale_id):
        node = get_path(chains.file('locales', ident) or {}, ['fields', key])
        if isinstance(node, list) and node and isinstance(node[0], str) and node[0].startswith('/LOCALE/fields/'):
            return field_name(chains, locale_id, node[0][len('/LOCALE/fields/'):])
        if isinstance(node, dict) and 'dn' in node:
            return first(node['dn'])
    return None


def locale_names(chains, locale_id, currencies):
    """Every display name of one locale, flattened through its parent chain, by kind + code."""
    entries = {}
    def add(kind, table, rename=lambda k: k):
        for key, value in table.items():
            text = first(value)
            if isinstance(text, str) and not text.startswith('/LOCALE/'):
                entries[kind + rename(key)] = text
    hyphen = lambda k: k.replace('_', '-')
    add('l', merged(chains, 'lang', locale_id, ['Languages']), hyphen)
    add('L', merged(chains, 'lang', locale_id, ['Languages%short']), hyphen)
    add('s', merged(chains, 'lang', locale_id, ['Scripts']))
    add('S', merged(chains, 'lang', locale_id, ['Scripts%short']))
    add('r', merged(chains, 'region', locale_id, ['Countries']))
    add('R', merged(chains, 'region', locale_id, ['Countries%short']))
    add('v', merged(chains, 'lang', locale_id, ['Variants']))
    add('c', merged(chains, 'lang', locale_id, ['Types', 'calendar']), lambda k: CALENDAR_TYPE.get(k, k))
    add('p', merged(chains, 'lang', locale_id, ['localeDisplayPattern']))
    for key in ('ppattern', 'pseparator'):
        assert entries[key].index('{0}') < entries[key].index('{1}'), 'the engine splits patterns in argument order'
    for field in FIELDS:
        for suffix in ('', '-short', '-narrow'):
            name = field_name(chains, locale_id, field + suffix)
            if name is not None:
                entries['f' + field + suffix] = name
    for code, names in merged(chains, 'curr', locale_id, ['Currencies']).items():
        # A name equal to the code marks a currency the locale does not name.
        if code in currencies and isinstance(names, list) and len(names) > 1 and names[1] != code:
            entries['u' + code] = names[1]
    return entries


def chain_parent(chains, locale_id):
    """The nearest ancestor of a locale that has a row, or None when the chain leaves the row set."""
    for ident in chains.chain(locale_id)[1:]:
        if ident in LOCALES:
            return ident
    return None


class Pool:
    """NUL-separated strings addressed by their offset; offset 0 is the empty string."""

    def __init__(self):
        self.data = bytearray(b'\0')
        self.at = {'': 0}

    def add(self, text):
        if text not in self.at:
            self.at[text] = len(self.data)
            self.data += text.encode('utf-8') + b'\0'
        return self.at[text]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out-dir', type=Path, default=Path('src/builtins'))
    args = parser.parse_args()
    if '#define U_ICU_VERSION "78.3"' not in (args.source / 'common/unicode/uvernum.h').read_text():
        parser.error('Use ICU 78.3 sources')
    chains = Chains(args.source)
    currencies = set(chains.lookup('curr', 'en', ['Currencies']))
    names = {loc: locale_names(chains, loc, currencies) for loc in LOCALES}

    keys = sorted(set().union(*(set(n) for n in names.values())))
    key_index = {k: i for i, k in enumerate(keys)}
    key_blob = bytearray()
    key_at = []
    for k in keys:
        key_at.append(len(key_blob))
        key_blob += k.encode() + b'\0'
    assert len(key_blob) < 65536

    english = Pool()
    english_at = [english.add(names['en'].get(k, '')) for k in keys]
    assert len(english.data) < 65536

    parents, row_at, pool_at = [], [0], []
    entry_key, entry_at = [], []
    strings = bytearray()
    stats = {}  # type -> [entries, string bytes]
    for loc in LOCALES[1:]:
        parent = chain_parent(chains, loc)
        parents.append(LOCALES.index(parent) if parent else NO_PARENT)
        inherited = names[parent] if parent else {}
        pool = Pool()
        for k in keys:
            text = names[loc].get(k)
            if text is None or inherited.get(k) == text:
                continue
            entry_key.append(key_index[k])
            entry_at.append(pool.add(text))
            row = stats.setdefault(TYPE_OF_KIND[k[0]], [0, 0])
            row[0] += 1
            row[1] += len(text.encode('utf-8')) + 1
        if len(pool.data) > 65535:
            raise ValueError(f'{loc} names pool exceeds 16-bit offsets: {len(pool.data)}')
        pool_at.append(len(strings))
        strings += pool.data
        row_at.append(len(entry_key))

    header = ('// Generated by scripts/generate_intl_names.py from ICU 78.3 / CLDR 48.\n'
              '// Do not edit.\nmodule boomkat::builtins;\n\n')
    english_out = [
        '// Sorted NUL-terminated keys: a kind letter, then the code.\n',
        c_array('char', 'INTL_NAME_KEYS', list(key_blob), 24),
        '// Offset of each key in INTL_NAME_KEYS.\n',
        c_array('ushort', 'INTL_NAME_KEY_AT', key_at, 12),
        '// Offset of each key\'s English name in INTL_NAME_POOL; 0 where English has none.\n',
        c_array('ushort', 'INTL_NAME_VALUE_AT', english_at, 12),
        '// NUL-separated English names.\n',
        c_pool('INTL_NAME_POOL', english.data),
    ]
    (args.out_dir / 'intl_names_data.c3').write_text(header + ''.join(english_out))

    gate = ' @feat(INTL_FULL)'
    extra = [
        '// Names of the non-English rows, in LOCALES order after en. A row lists the keys whose name differs\n'
        '// from its parent row\'s; INTL_NAMES_PARENT is that row, or 255 when the chain leaves the row set.\n',
        c_array('char', 'INTL_NAMES_PARENT', parents, 24, gate),
        '// Entries [INTL_NAMES_ROW_AT[row - 1], INTL_NAMES_ROW_AT[row]) of a row, sorted by key index.\n',
        c_array('uint', 'INTL_NAMES_ROW_AT', row_at, 12, gate),
        c_array('ushort', 'INTL_NAMES_ENTRY_KEY', entry_key, 12, gate),
        '// Each entry\'s name: an offset in the row\'s pool, which starts at INTL_NAMES_POOL_AT[row - 1].\n',
        c_array('ushort', 'INTL_NAMES_ENTRY_AT', entry_at, 12, gate),
        c_array('uint', 'INTL_NAMES_POOL_AT', pool_at, 12, gate),
        c_pool('INTL_NAMES_STRINGS', strings, gate),
    ]
    (args.out_dir / 'intl_names_extra_data.c3').write_text(header + ''.join(extra))

    print(f'{len(keys)} keys ({len(key_blob)} key bytes), English pool {len(english.data)} bytes, '
          f'{len(entry_key)} entries, {len(strings)} string bytes')
    for kind, (count, size) in sorted(stats.items()):
        print(f'  {kind}: {count} entries, {count * 4 + size} bytes ({size} string bytes)')


if __name__ == '__main__':
    main()
