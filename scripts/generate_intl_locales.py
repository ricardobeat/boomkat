#!/usr/bin/env python3
"""Extract number, compact, unit, currency and plural data per locale from ICU 78.3.

Every row is flattened from its CLDR parent chain (supplementalData parentLocales,
then truncation), so the engine reads one row per locale and walks no inheritance.

Two files are written:
- src/builtins/intl_locales_data.c3: the English row, always built.
- src/builtins/intl_locales_extra_data.c3: every other row, under @feat(INTL_LOCALES).
  Currency symbols and names are stored here only where a row differs from English.

Run from the repository root with --source pointing at the ICU 78.3 sources.
"""
import argparse
import re
from pathlib import Path
from generate_intl_english import resource, UNITS

HERE = Path(__file__).resolve().parent

# ICU locale ids. en is row 0 and the default; the rest are emitted under INTL_LOCALES.
LOCALES = ['en', 'en_IN', 'ar', 'ar_EG', 'de', 'de_AT', 'es', 'es_419', 'fa', 'fr', 'gv', 'hi',
           'it', 'ja', 'ko', 'ln', 'pl', 'pt', 'pt_PT', 'ru', 'si', 'sl', 'sr', 'sr_Latn', 'sv', 'th', 'tr',
           'zh', 'zh_Hant', 'zh_Hant_TW']
CATEGORIES = ['zero', 'one', 'two', 'few', 'many', 'other']
COMPACT_EXPONENTS = list(range(3, 15))
WIDTHS = ['units', 'unitsShort', 'unitsNarrow']
ROW_FIELDS = ['tag', 'decimal', 'group', 'minus', 'plus', 'percent', 'nan', 'infinity', 'exponential',
              'per_mille', 'decimal_pattern', 'percent_pattern', 'currency_pattern', 'accounting_pattern',
              'scientific_pattern', 'cardinal', 'ordinal']


class Chains:
    """Loads ICU resource files once and resolves paths through a locale's parent chain."""

    def __init__(self, source):
        self.source = source
        self.cache = {}
        supp = resource(source / 'data/misc/supplementalData.txt')
        self.parent = {}
        for parent, children in supp['parentLocales'].items():
            for child in children:
                self.parent[child] = parent

    def file(self, dirname, locale_id):
        key = (dirname, locale_id)
        if key not in self.cache:
            path = self.source / 'data' / dirname / f'{locale_id}.txt'
            node = resource(path) if path.exists() else None
            self.cache[key] = node if isinstance(node, dict) else None
        return self.cache[key]

    def chain(self, locale_id):
        ids = []
        current = locale_id
        while current:
            ids.append(current)
            if current in self.parent:
                current = self.parent[current]
            elif '_' in current:
                current = current.rpartition('_')[0]
            else:
                current = None
        if ids[-1] != 'root':
            ids.append('root')
        return ids

    def lookup(self, dirname, locale_id, path):
        """Returns the first value along the chain, following /LOCALE/ aliases within the chain."""
        for ident in self.chain(locale_id):
            node = self.file(dirname, ident)
            if node is None:
                continue
            value = get_path(node, path)
            if value is None:
                continue
            if isinstance(value, list) and len(value) == 1 and isinstance(value[0], str) and value[0].startswith('/LOCALE/'):
                return self.lookup(dirname, locale_id, value[0][len('/LOCALE/'):].split('/'))
            return value
        return None


def get_path(node, path):
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return None
        node = node[key]
    return node


def string_of(value):
    """The string under a leaf value: a plain string or a single-element list."""
    if isinstance(value, list):
        return value[0] if value else None
    return value


def plural_value(node, category):
    """The string for a category of a plural node, falling back to other."""
    if not isinstance(node, dict):
        return string_of(node)
    if category in node:
        return string_of(node[category])
    return string_of(node.get('other'))


class Pool:
    def __init__(self):
        self.data = bytearray(b'\0')
        self.at = {'': 0}

    def add(self, text):
        if text is None:
            return 0
        if text not in self.at:
            self.at[text] = len(self.data)
            self.data += text.encode('utf-8') + b'\0'
        return self.at[text]


def plural_rules(chains, source, locale_id, ordinal):
    """CLDR plural rules for the locale as 'category: rule;' text, without the examples after '@'."""
    plurals = resource(source / 'data/misc/plurals.txt')
    section = 'locales_ordinals' if ordinal else 'locales'
    for ident in chains.chain(locale_id):
        rules_set = plurals[section].get(ident)
        if rules_set is None:
            continue
        rules = plurals['rules'][string_of(rules_set)]
        parts = []
        for category in ['zero', 'one', 'two', 'few', 'many']:
            if category in rules:
                text = string_of(rules[category])
                if text is None:
                    continue
                parts.append(f'{category}: {text.split(" @")[0].strip()}')
        return ';'.join(parts)
    return ''


def find_unit(chains, locale_id, width, name, key):
    """The first value of `key` for a unit in one width, walking the locale's parent chain."""
    for ident in chains.chain(locale_id):
        node = chains.file('unit', ident)
        if node is None:
            continue
        group = node.get(width)
        if not isinstance(group, dict):
            continue
        for values in group.values():
            if isinstance(values, dict) and isinstance(values.get(name), dict) and key in values[name]:
                return values[name][key]
    return None


def default_numbering():
    """Each locale's default numbering system from the ICU dump, keyed by locale id."""
    table = {}
    for line in (HERE / 'intl/locale_info.txt').read_text().splitlines():
        if line.startswith('numbering\t'):
            _, loc, system = line.split('\t')
            table[loc] = system
    return table


NUMBERING = default_numbering()


def build_row(chains, source, pool, locale_id, en_currencies, en_narrow, en_plurals):
    """Flattens one locale into a row of pool offsets plus its compact, unit and currency blocks."""
    # Symbols and patterns come from the locale's default numbering system.
    system = NUMBERING.get(locale_id) or NUMBERING.get(locale_id.partition('_')[0], 'latn')
    ns = ['NumberElements', system]
    symbols = {k: string_of(chains.lookup('locales', locale_id, ns + ['symbols', k]))
               for k in ['decimal', 'group', 'minusSign', 'plusSign', 'percentSign', 'nan', 'infinity',
                         'exponential', 'perMille']}
    patterns = {k: string_of(chains.lookup('locales', locale_id, ns + ['patterns', k]))
                for k in ['decimalFormat', 'percentFormat', 'currencyFormat', 'accountingFormat', 'scientificFormat']}
    compact = []
    for style in ['patternsShort', 'patternsLong']:
        # A locale without patternsLong uses its patternsShort, as ICU's CompactData does.
        node = chains.lookup('locales', locale_id, ns + [style, 'decimalFormat'])
        if node is None and style == 'patternsLong':
            node = chains.lookup('locales', locale_id, ns + ['patternsShort', 'decimalFormat'])
        for exponent in COMPACT_EXPONENTS:
            entry = node.get(str(10 ** exponent)) if isinstance(node, dict) else None
            for category in CATEGORIES:
                text = plural_value(entry, category) if entry is not None else None
                compact.append(pool.add(text))
    units = []
    for name in UNITS:
        for width in WIDTHS:
            # A unit's own width is searched through the locale chain first (ko narrow "h" is in root),
            # then the other widths, so a locale defining only units "per" patterns still renders its numerator.
            def form(key):
                for fallback in [width] + [w for w in ['unitsNarrow', 'unitsShort', 'units'] if w != width]:
                    value = find_unit(chains, locale_id, fallback, name, key)
                    if value is not None:
                        return value
                return None
            other = form('other')
            one = form('one') if form('one') is not None else other
            per = find_unit(chains, locale_id, width, name, 'per')
            units += [pool.add(string_of(one) if one is not None else None),
                      pool.add(string_of(other) if other is not None else None),
                      pool.add(string_of(per) if per is not None else None)]
    for width in WIDTHS:
        # A width without a compound per pattern uses unitsShort's, as ICU does.
        compound = None
        for fallback in [width, 'unitsShort', 'units']:
            compound = chains.lookup('unit', locale_id, [fallback, 'compound', 'per'])
            if compound is not None:
                break
        units.append(pool.add(string_of(compound)))
    row = [
        pool.add(locale_id.replace('_', '-')),
        pool.add(symbols['decimal']), pool.add(symbols['group']), pool.add(symbols['minusSign']),
        pool.add(symbols['plusSign']), pool.add(symbols['percentSign']), pool.add(symbols['nan']),
        pool.add(symbols['infinity']), pool.add(symbols['exponential']), pool.add(symbols['perMille']),
        pool.add(patterns['decimalFormat']), pool.add(patterns['percentFormat']),
        pool.add(patterns['currencyFormat']), pool.add(patterns['accountingFormat']),
        pool.add(patterns['scientificFormat']),
        pool.add(plural_rules(chains, source, locale_id, False)),
        pool.add(plural_rules(chains, source, locale_id, True)),
    ]
    min_grouping = string_of(chains.lookup('locales', locale_id, ['NumberElements', 'minimumGroupingDigits'])) or '1'
    row.append(int(min_grouping))
    overrides = []
    if en_currencies is not None:
        for code, strings in sorted((chains.lookup('curr', locale_id, ['Currencies']) or {}).items()):
            if not (code.isupper() and len(code) == 3 and code in en_currencies):
                continue
            symbol = strings[0]
            narrow = string_of(chains.lookup('curr', locale_id, ['Currencies%narrow', code])) or symbol
            plural_node = chains.lookup('curr', locale_id, ['CurrencyPlurals', code]) or {}
            one = plural_value(plural_node, 'one') or symbol
            other = plural_value(plural_node, 'other') or symbol
            en_symbol = en_currencies[code][0]
            en_narrow_value = string_of(en_narrow.get(code)) or en_symbol
            en_node = en_plurals.get(code, {})
            en_one = plural_value(en_node, 'one') or en_symbol
            en_other = plural_value(en_node, 'other') or en_symbol
            if (symbol, narrow, one, other) == (en_symbol, en_narrow_value, en_one, en_other):
                continue
            overrides.append((code, symbol, narrow, one, other))
    return row, compact, units, overrides


def pack_code(code):
    return sum((ord(c) - 64) << (5 * (2 - i)) for i, c in enumerate(code))


def c_str(text):
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"') + '"'


def c_array(ctype, name, values, per_line, attr=''):
    lines = [f'const {ctype}[*] {name}{attr} = {{']
    for i in range(0, len(values), per_line):
        lines.append('    ' + ', '.join(str(v) for v in values[i:i + per_line]) + ',')
    lines.append('};\n')
    return '\n'.join(lines)


def c_pool(name, data, attr=''):
    lines = [f'const char[*] {name}{attr} = {{']
    for i in range(0, len(data), 24):
        lines.append('    ' + ', '.join(f'0x{b:02x}' for b in data[i:i + 24]) + ',')
    lines.append('};\n')
    return '\n'.join(lines)


def row_struct():
    return ('// One row per locale. Strings are offsets into the row set\'s string pool, 0 meaning absent.\n'
            'struct IntlLocaleRow {\n'
            '    ushort ' + '; ushort '.join(ROW_FIELDS[:-1]) + ';\n'
            '    ushort ' + ROW_FIELDS[-1] + '; char min_grouping;\n'
            '}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out-dir', type=Path, default=Path('src/builtins'))
    args = parser.parse_args()
    if '#define U_ICU_VERSION "78.3"' not in (args.source / 'common/unicode/uvernum.h').read_text():
        parser.error('Use ICU 78.3 sources')
    chains = Chains(args.source)
    en_currencies = chains.lookup('curr', 'en', ['Currencies'])
    en_narrow = chains.lookup('curr', 'en', ['Currencies%narrow']) or {}
    en_plurals = chains.lookup('curr', 'en', ['CurrencyPlurals']) or {}
    # Each row has its own string pool, so offsets stay 16-bit. Extra pools are concatenated;
    # INTL_EXTRA_POOL_AT gives each row's base.
    en_pool = Pool()
    en_row, en_compact, en_units, _ = build_row(chains, args.source, en_pool, 'en', en_currencies, en_narrow, en_plurals)
    extra_rows, extra_compact, extra_units, extra_cur, extra_cur_at = [], [], [], [], []
    extra_data, extra_base = bytearray(), []
    total_overrides = 0
    for locale_id in LOCALES[1:]:
        pool = Pool()
        row, compact, units, overrides = build_row(chains, args.source, pool, locale_id,
                                                   en_currencies, en_narrow, en_plurals)
        extra_rows.append(row)
        extra_compact += compact
        extra_units += units
        extra_cur_at.append(len(extra_cur))
        extra_cur.append(len(overrides))
        total_overrides += len(overrides)
        for code, symbol, narrow, one, other in overrides:
            extra_cur += [pack_code(code), pool.add(symbol), pool.add(narrow), pool.add(one), pool.add(other)]
        # The pool is copied after the override strings are added to it.
        if len(pool.data) > 65535:
            raise ValueError(f'{locale_id} string pool exceeds 16-bit offsets: {len(pool.data)}')
        extra_base.append(len(extra_data))
        extra_data += pool.data
    if len(en_pool.data) > 65535:
        raise ValueError(f'en string pool exceeds 16-bit offsets: {len(en_pool.data)}')
    write_default(args.out_dir / 'intl_locales_data.c3', en_row, en_compact, en_units, en_pool)
    write_extra(args.out_dir / 'intl_locales_extra_data.c3', extra_rows, extra_compact, extra_units,
                extra_cur, extra_cur_at, extra_data, extra_base)
    print(f'en: {len(en_pool.data)} string bytes; {len(extra_rows)} locales: {len(extra_data)} string bytes, '
          f'{total_overrides} currency overrides')


HEADER = '// Generated from ICU 78.3 / CLDR 48. Unicode License V3: vendor/intl/LICENSE.\n' \
         '// Regenerate with scripts/generate_intl_locales.py --source <icu/source>.\n' \
         'module boomkat::builtins;\n\n'


def write_default(path, en_row, en_compact, en_units, en_pool):
    out = HEADER + row_struct() + '\n'
    out += '// English number data (row 0), the default locale for every service.\n'
    out += 'const IntlLocaleRow INTL_EN_ROW = { ' + ', '.join(str(v) for v in en_row[:-1]) + ', ' + str(en_row[-1]) + ' };\n\n'
    out += '// Compact patterns: a short block then a long block, each 12 exponents x 6 categories.\n'
    out += c_array('ushort', 'INTL_EN_COMPACT', en_compact, 12)
    out += '// Unit patterns: one, other and per-unit pattern per unit and width (units, unitsShort, unitsNarrow),\n'
    out += '// then the compound per pattern per width. Unit order matches INTL_UNIT_NAMES.\n'
    out += c_array('ushort', 'INTL_EN_UNITS', en_units, 12)
    out += c_pool('INTL_EN_STRINGS', en_pool.data)
    path.write_text(out)


def write_extra(path, rows, compact, units, currencies, currency_at, data, bases):
    gate = '@feat(INTL_LOCALES)'
    out = HEADER
    out += '// Non-English rows, in LOCALES order after en. Strings are offsets into the row\'s own pool,\n'
    out += '// which starts at INTL_EXTRA_POOL_AT[row].\n'
    out += 'const IntlLocaleRow[*] INTL_EXTRA_ROWS ' + gate + ' = {\n'
    for row in rows:
        out += '    { ' + ', '.join(str(v) for v in row[:-1]) + ', ' + str(row[-1]) + ' },\n'
    out += '};\n\n'
    out += c_array('ushort', 'INTL_EXTRA_COMPACT', compact, 12, ' ' + gate)
    out += c_array('ushort', 'INTL_EXTRA_UNITS', units, 12, ' ' + gate)
    out += '// Currency overrides per row: a count, then (packed code, symbol, narrow, one, other) records.\n'
    out += c_array('ushort', 'INTL_EXTRA_CURRENCIES', currencies, 10, ' ' + gate)
    out += c_array('ushort', 'INTL_EXTRA_CURRENCY_AT', currency_at, 12, ' ' + gate)
    out += c_array('uint', 'INTL_EXTRA_POOL_AT', bases, 12, ' ' + gate)
    out += c_pool('INTL_EXTRA_STRINGS', data, ' ' + gate)
    path.write_text(out)


if __name__ == '__main__':
    main()
