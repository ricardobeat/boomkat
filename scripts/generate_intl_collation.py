#!/usr/bin/env python3
"""Generate the collation tables behind Intl.Collator from ICU 78.3 / CLDR 48.

Inputs are the two outputs of scripts/intl/dump_tailorings.c: the "sets" dump
(available locales, their collation types, and every tailored string and
contraction) and the "ces" dump (root collation elements, and each tailoring's
elements wherever they differ from root).

Full tables require INTL_FULL. The root subset for small builds retains the exact
root bytecode and weight ranks. Use --small-from to extract it from a generated
full table without the ICU dumps.

The engine looks a string up in a chain of overlays: a tailoring, the tailoring
it is stored against, and so on down to the root overlay. At each position the
longest key present in any overlay of the chain wins, the nearest overlay on a
tie. Each tailoring keeps only the keys whose elements differ from its parent's,
plus any key the chain needs to reproduce ICU's elements; the generator checks
that by running the same lookup over every tailored string and contraction.

Primaries become dense ranks in ICU order, from 2 up, so the stored deltas stay
small; rank 1 is the end-of-string terminator ICU calls NO_CE_PRIMARY.
Unassigned code points (ICU lead byte FE) are not stored: rank
INTL_COLL_RANK_LOW + 1 + cp stands in for them, which keeps their code point
order. INTL_COLL_RANK_LOW itself is the [first unassigned] boundary. A reordering tailoring carries runs that move ranks the way its
lead-byte permutation moves primaries.

Each overlay is a run of blocks. A block holds about BLOCK_ENTRIES entries,
sorted by key, and never splits the entries that share a first code point, so a
lookup binary-searches the block first code points and decodes one block. An
entry is LEB128 varints: first code point delta, extra key length << 1 | the
extendable bit, extra code points, element count, then per element a primary code (0 for
primary-ignorable, else the zigzagged rank delta from the block's previous
nonzero primary, plus 1) and an index into INTL_COLL_SECTER.

An extendable key is one ICU's suffix trie holds in NFD form, so a discontiguous
match (UTS #10 S2.1.2) can end on it. A canonical-closure contraction is stored
precomposed, and the NFD text the engine collates never reaches it there.
"""
import argparse
import bisect
import re
from collections import Counter, defaultdict
from pathlib import Path

BLOCK_ENTRIES = 16
MERGE_SEPARATOR_PRIMARY = 0x02000000
COMMON = (0x500, 0x500)
# ICU type names in the resource tree that differ from their BCP 47 forms.
TYPE_NAMES = {'dictionary': 'dict', 'phonebook': 'phonebk', 'traditional': 'trad'}


def unassigned_primary(cp):
    """Collation::unassignedPrimaryFromCodePoint."""
    c = cp + 1
    primary = 2 + (c % 18) * 14
    c //= 18
    primary |= (2 + (c % 254)) << 8
    c //= 254
    primary |= (4 + (c % 251)) << 16
    return primary | (0xFE << 24)


def unassigned_code_point(primary):
    b4 = primary & 0xFF
    b3 = (primary >> 8) & 0xFF
    b2 = (primary >> 16) & 0xFF
    c = ((b2 - 4) * 254 + (b3 - 2)) * 18 + (b4 - 2) // 14
    cp = c - 1
    assert unassigned_primary(cp) == primary, hex(primary)
    return cp


def parse_ces(text):
    out = []
    for item in text.split(' ') if text else []:
        p, s, t = (int(x, 16) for x in item.split(':'))
        if p or s or t:
            out.append((p, s, t))
    return tuple(out)


def parse_key(text):
    return tuple(int(x, 16) for x in text.split(' '))


def varint(n, out):
    assert n >= 0
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)


def zigzag(n):
    return n * 2 if n >= 0 else -n * 2 - 1


def c3_array(name, ctype, values, per_line, comment):
    lines = [comment, f'const {ctype}[*] {name} @feat(INTL_FULL) = {{']
    for i in range(0, len(values), per_line):
        lines.append('    ' + ', '.join(f'0x{v:X}' for v in values[i:i + per_line]) + ',')
    lines.append('};')
    return '\n'.join(lines)


def generate_small(full_source, output):
    """Retain the exact root bytecode and ranks while dropping locale overlays."""
    arrays = {}
    for ctype, name, body in re.findall(
            r'const (\w+)\[\*\] (INTL_COLL_\w+) @feat\(INTL_FULL\) = \{(.*?)\};',
            full_source, re.S):
        arrays[name] = (ctype, [int(v, 0) for v in re.findall(r'0x[0-9A-Fa-f]+|\d+', body)])
    def values(name):
        return arrays[name][1]
    root_blocks = values('INTL_COLL_OVERLAY_COUNT')[0]
    root_end = values('INTL_COLL_BLOCK_AT')[root_blocks]
    for name in list(arrays):
        ctype, data = arrays[name]
        if name == 'INTL_COLL_BLOCK_FIRST':
            data = data[:root_blocks]
        elif name == 'INTL_COLL_BLOCK_AT':
            data = data[:root_blocks + 1]
        elif name == 'INTL_COLL_DATA':
            data = data[:root_end]
        elif name.startswith('INTL_COLL_OVERLAY_'):
            data = data[:1]
        elif name.startswith('INTL_COLL_REORDER_'):
            data = [0]
        arrays[name] = ctype, data
    # Both English and the root use the standard root order. Search retains the
    # same order, with the API's search sensitivity and punctuation options.
    replacements = {
        'INTL_COLL_LOCALE_NAMES': list(b'en\0und\0'),
        'INTL_COLL_LOCALE_AT': [0, 3],
        'INTL_COLL_LOCALE_DEFAULT': [1, 1],
        'INTL_COLL_LOCALE_PAIRS_AT': [0, 2, 4],
        'INTL_COLL_LOCALE_PAIRS': [0, 1 << 10, 0, 1 << 10],
        'INTL_COLL_TYPE_NAMES': list(b'search\0standard\0'),
        'INTL_COLL_TYPE_AT': [0, 7],
    }
    for name, data in replacements.items():
        arrays[name] = arrays[name][0], data
    out = [c3_array(name, ctype, data, 24 if ctype == 'char' else 12, '')
           .replace('@feat(INTL_FULL)', '@feat(!INTL_FULL)').lstrip()
           for name, (ctype, data) in arrays.items()]
    for ctype, name, value in re.findall(
            r'const (\w+) (INTL_COLL_\w+) @feat\(INTL_FULL\) = (\d+);', full_source):
        if name == 'INTL_COLL_MAX_KEY':
            value = str(values('INTL_COLL_OVERLAY_MAXLEN')[0])
        elif name == 'INTL_COLL_TYPE_STANDARD':
            value = '1'
        elif name == 'INTL_COLL_TYPE_SEARCH':
            value = '0'
        out.append(f'const {ctype} {name} @feat(!INTL_FULL) = {value};')
    header = ('// Generated by scripts/generate_intl_collation.py; root subset of ICU 78.3 / CLDR 48.\n'
              'module boomkat::builtins @feat(INTL);\n\n')
    output.write_text(header + '\n\n'.join(out) + '\n')
    print(f'{output}: {root_end} root data bytes, {root_blocks} blocks')


class Overlay:
    def __init__(self, entries, parent):
        self.entries = entries          # key tuple -> CE tuple
        self.extendable = set()         # keys a discontiguous match may end on
        self.parent = parent            # Overlay, or None for root
        self.maxlen = max((len(k) for k in entries), default=1)

    def add(self, key, ces):
        self.entries[key] = ces
        self.maxlen = max(self.maxlen, len(key))

    def chain(self):
        o = self
        while o is not None:
            yield o
            o = o.parent


def emulate(chain, key):
    """The engine's lookup: longest key in any overlay of the chain, nearest on a tie."""
    out = []
    i = 0
    n = len(key)
    while i < n:
        best = None
        best_len = 0
        for o in chain:
            for length in range(min(o.maxlen, n - i), best_len, -1):
                ces = o.entries.get(key[i:i + length])
                if ces is not None:
                    best, best_len = ces, length
                    break
        if best is None:
            best = ((unassigned_primary(key[i]),) + COMMON,)
            best_len = 1
        out.extend(best)
        i += best_len
    return tuple(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sets', type=Path)
    parser.add_argument('--ces', type=Path)
    parser.add_argument('--digits', type=Path)
    parser.add_argument('--out', type=Path, default=Path('src/builtins/intl_collation_data.c3'))
    parser.add_argument('--small-from', type=Path, help='extract root tables from generated full tables')
    parser.add_argument('--small-out', type=Path, default=Path('src/builtins/intl_collation_root_data.c3'))
    args = parser.parse_args()
    if args.small_from:
        generate_small(args.small_from.read_text(), args.small_out)
        return
    if not all((args.sets, args.ces, args.digits)):
        parser.error('--sets, --ces and --digits are required unless --small-from is supplied')

    locale_types = defaultdict(dict)   # ICU locale -> {type: tailoring}
    defaults = {}
    nfd_keys = defaultdict(set)        # tailoring -> contractions its trie holds in NFD form
    for line in args.sets.read_text().splitlines():
        parts = line.split('\t')
        if parts[0] == 'locale':
            locale_types[parts[1]][parts[2]] = int(parts[3])
        elif parts[0] == 'default':
            defaults[parts[1]] = parts[2]
        elif parts[0] == 'key':
            nfd_keys[int(parts[1])].add(parse_key(parts[2]))

    root_single = {}
    root_multi = {}
    settings = {}
    diffs = defaultdict(dict)
    leads = defaultdict(dict)
    for line in args.ces.read_text().splitlines():
        parts = line.split('\t')
        kind = parts[0]
        if kind == 'root':
            key = parse_key(parts[1])
            ces = parse_ces(parts[2] if len(parts) > 2 else '')
            (root_single if len(key) == 1 else root_multi)[key] = ces
        elif kind == 'entry':
            diffs[int(parts[1])][parse_key(parts[2])] = parse_ces(parts[3] if len(parts) > 3 else '')
        elif kind == 'tailoring':
            settings[int(parts[1])] = {
                'backwards': parts[2] == '1', 'shifted': parts[3] == '1', 'case_first': int(parts[4]),
                'case_level': parts[5] == '1', 'numeric': parts[6] == '1', 'variable_top': int(parts[7], 16),
                'reorder': parts[8], 'id': parts[9],
            }
        elif kind == 'lead':
            leads[int(parts[1])][int(parts[2], 16)] = int(parts[3], 16)

    universe = sorted(set(root_multi) | {k for d in diffs.values() for k in d}, key=lambda k: (len(k), k))
    by_cp = defaultdict(list)
    for key in universe:
        for cp in set(key):
            by_cp[cp].append(key)

    def icu_root(key):
        if len(key) > 1:
            return root_multi[key]
        ces = root_single.get(key)
        return ces if ces is not None else ((unassigned_primary(key[0]),) + COMMON,)

    # Root contractions: the multi-code-point strings the per-code-point lookup gets wrong.
    root = Overlay(dict(root_single), None)
    for key in universe:
        if len(key) > 1 and emulate([root], key) != icu_root(key):
            root.add(key, icu_root(key))
    for key in nfd_keys[0]:
        if len(key) > 1:
            root.add(key, icu_root(key))
            root.extendable.add(key)

    def chain_extendable(chain, key):
        """Whether the entry the engine finds for exactly `key` lets a discontiguous match end."""
        for o in chain:
            if key in o.entries:
                return key in o.extendable
        return False

    def language(t):
        return settings[t]['id'].split('|')[0].split('@')[0].split('_')[0] or 'root'

    def icu(key, t):
        if t is None:
            return icu_root(key)
        ces = diffs[t].get(key)
        return ces if ces is not None else icu_root(key)

    # Store each tailoring against the earlier overlay of its language (or a root type) it differs
    # from least; smaller tailorings go first so they can serve as parents.
    used = {tl for loc, types in locale_types.items() if not loc.endswith('_POSIX') for tl in types.values()}
    order = sorted(used, key=lambda t: (len(diffs[t]), t))
    overlays = {}
    parents = {}
    for t in order:
        if t == 0:
            continue  # root itself
        best_parent, best_diff = None, len(diffs[t])
        for p in overlays:
            if language(p) not in (language(t), 'root'):
                continue
            d = sum(1 for key in set(diffs[t]) | set(diffs[p]) if icu(key, t) != icu(key, p))
            if d < best_diff:
                best_parent, best_diff = p, d
        parents[t] = best_parent
        candidates = set(diffs[t]) | (set(diffs[best_parent]) if best_parent is not None else set())
        # A multi-code-point string starts out stored only when ICU holds it as a contraction: any
        # other one the chain gets wrong is added below. Storing one ICU lacks (z s, under a
        # tailored z) would swallow a code point a later discontiguous match needs.
        overlay = Overlay({k: icu(k, t) for k in candidates
                           if icu(k, t) != icu(k, best_parent) and (len(k) == 1 or k in nfd_keys[t])},
                          overlays[best_parent] if best_parent is not None else root)
        chain = list(overlay.chain())
        checked = set()
        while True:
            todo = set()
            for key in overlay.entries:
                for cp in key:
                    if cp not in checked:
                        checked.add(cp)
                        todo.update(by_cp[cp])
            for o in chain[1:-1]:
                for key in o.entries:
                    for cp in key:
                        if cp not in checked:
                            checked.add(cp)
                            todo.update(by_cp[cp])
            if not todo:
                break
            for key in sorted(todo, key=lambda k: (len(k), k)):
                want = icu(key, t)
                if emulate(chain, key) != want:
                    overlay.add(key, want)
        # Give the tailoring its own set of extendable keys where the chain would answer differently.
        inherited = {k for o in chain[1:] for k in o.extendable}
        for key in sorted(nfd_keys[t] | inherited):
            if len(key) < 2:
                continue
            want = key in nfd_keys[t]
            if key not in overlay.entries:
                if chain_extendable(chain[1:], key) == want:
                    continue
                overlay.add(key, icu(key, t))
            if want:
                overlay.extendable.add(key)
        overlays[t] = overlay
        print(f'  {settings[t]["id"]}: {len(overlay.entries)} keys over '
              f'{settings[best_parent]["id"] if best_parent is not None else "root"}', flush=True)

    # Dense primary ranks in ICU order; unassigned primaries take the code point slots.
    everything = [root] + list(overlays.values())
    primaries = {p for o in everything for ces in o.entries.values() for p, _, _ in ces
                 if p and (p >> 24) != 0xFE}
    low = sorted(p for p in primaries if p < 0xFE000000)
    high = sorted(p for p in primaries if p >= 0xFF000000)
    # One rank above the assigned primaries holds U+FDD1 U+FDD0, ICU's [first unassigned] boundary.
    rank_low = len(low) + 2
    rank = {p: i + 2 for i, p in enumerate(low)}
    rank[0xFE040200] = rank_low
    for i, p in enumerate(high):
        rank[p] = rank_low + 0x110001 + i

    def rank_of(p):
        if p == 0:
            return 0
        if (p >> 24) == 0xFE and p != 0xFE040200:
            return rank_low + 1 + unassigned_code_point(p)
        return rank[p]

    def rank_at_most(primary):
        return bisect.bisect_right(low, primary) + 1

    secter = Counter((s, t) for o in everything for ces in o.entries.values() for _, s, t in ces)
    secter_list = [st for st, _ in secter.most_common()]
    secter_index = {st: i for i, st in enumerate(secter_list)}

    data = bytearray()
    block_first, block_at = [], []

    def encode(o):
        start = len(block_first)
        keys = sorted(o.entries)
        i = 0
        while i < len(keys):
            j = i + 1
            while j < len(keys) and (j - i < BLOCK_ENTRIES or keys[j][0] == keys[j - 1][0]):
                j += 1
            block_first.append(keys[i][0])
            block_at.append(len(data))
            prev_cp = keys[i][0]
            prev_rank = 0
            for key in keys[i:j]:
                varint(key[0] - prev_cp, data)
                prev_cp = key[0]
                varint((len(key) - 1) << 1 | (key in o.extendable), data)
                for cp in key[1:]:
                    varint(cp, data)
                ces = o.entries[key]
                varint(len(ces), data)
                for p, s, t in ces:
                    r = rank_of(p)
                    if r == 0:
                        varint(0, data)
                    else:
                        varint(zigzag(r - prev_rank) + 1, data)
                        prev_rank = r
                    varint(secter_index[(s, t)], data)
            i = j
        return start, len(block_first) - start

    def flags_of(st):
        return (st['backwards'] | st['shifted'] << 1 | st['case_level'] << 2 | st['numeric'] << 3
                | st['case_first'] << 4)

    # Reorder runs: maximal rank ranges that move together under the tailoring's lead permutation.
    reorder_from, reorder_to, reorder_count = [], [], []

    def reorder_runs(t):
        table = leads[t]
        sampled = sorted(table)

        def moved(p):
            # A prefix this tailoring has no primary in (another tailoring's) moves with the nearest
            # sampled prefix below it, so it stays inside the same run.
            k = bisect.bisect_right(sampled, p >> 16) - 1
            return (table[sampled[k]] if k >= 0 else p >> 24, p)
        new_order = sorted(low, key=moved)
        new_rank = {p: i + 2 for i, p in enumerate(new_order)}
        start = len(reorder_from)
        r = 0
        while r < len(low):
            if new_rank[low[r]] == r + 2:
                r += 1
                continue
            k = r
            while k + 1 < len(low) and new_rank[low[k + 1]] == new_rank[low[k]] + 1:
                k += 1
            reorder_from.append(r + 2)
            reorder_count.append(k - r + 1)
            reorder_to.append(new_rank[low[r]])
            r = k + 1
        return start, len(reorder_from) - start

    index_of = {0: 0}
    for t in order:
        if t != 0:
            index_of[t] = len(index_of)
    rows = [None] * len(index_of)
    start, count = encode(root)
    st0 = settings[0]
    rows[0] = (start, count, root.maxlen, 0xFFFF, flags_of(st0), rank_at_most(st0['variable_top'] | 0xFFFF), 0, 0)
    for t in order:
        if t == 0:
            continue
        o = overlays[t]
        before = len(data)
        start, count = encode(o)
        print(f'  {len(data) - before:8} bytes  {settings[t]["id"]}')
        st = settings[t]
        run_start, run_count = reorder_runs(t) if st['reorder'] else (len(reorder_from), 0)
        parent = parents[t]
        rows[index_of[t]] = (start, count, o.maxlen, 0 if parent is None else index_of[parent], flags_of(st),
                             rank_at_most(st['variable_top'] | 0xFFFF), run_start, run_count)
    block_at.append(len(data))

    # Locales: BCP 47 tags in sorted order, each with its default type and its (type, overlay) pairs.
    def type_name(ty):
        return TYPE_NAMES.get(ty, ty)
    type_names = sorted({type_name(ty) for types in locale_types.values() for ty in types})
    type_index = {n: i for i, n in enumerate(type_names)}
    locale_rows = []
    for loc, types in locale_types.items():
        if loc.endswith('_POSIX'):
            continue
        tag = 'und' if loc == 'root' else loc.replace('_', '-')
        pairs = sorted((type_index[type_name(ty)], index_of[tl]) for ty, tl in types.items())
        locale_rows.append((tag, type_index[type_name(defaults[loc])], pairs))
    locale_rows.sort(key=lambda r: r[0].lower())
    name_pool = bytearray()
    name_at, default_type, pair_at, pair_words = [], [], [], []
    for tag, default, pairs in locale_rows:
        name_at.append(len(name_pool))
        name_pool += tag.encode() + b'\0'
        default_type.append(default)
        pair_at.append(len(pair_words))
        pair_words += [ti << 10 | oi for ti, oi in pairs]
    pair_at.append(len(pair_words))
    assert len(rows) < 1024 and len(type_names) < 64
    type_pool = bytearray()
    type_at = []
    for n in type_names:
        type_at.append(len(type_pool))
        type_pool += n.encode() + b'\0'

    digit_rank = rank_of(root_single[(0x30,)][0][0])
    digit_zeros = [int(line.split('\t')[1], 16) for line in args.digits.read_text().splitlines()]
    out = [
        c3_array('INTL_COLL_BLOCK_FIRST', 'uint', block_first, 12, '// First code point of each block, by overlay; binary-searched.'),
        c3_array('INTL_COLL_BLOCK_AT', 'uint', block_at, 12, '// Offset of each block in INTL_COLL_DATA, then the data length.'),
        c3_array('INTL_COLL_DATA', 'char', list(data), 24, '// Encoded overlay entries (see scripts/generate_intl_collation.py).'),
        c3_array('INTL_COLL_SECTER', 'uint', [s << 16 | t for s, t in secter_list], 8,
                 '// Secondary << 16 | tertiary of each element, most frequent first.'),
        c3_array('INTL_COLL_OVERLAY_BLOCKS', 'uint', [r[0] for r in rows], 12, '// First block of each overlay; overlay 0 is root.'),
        c3_array('INTL_COLL_OVERLAY_COUNT', 'uint', [r[1] for r in rows], 12, '// Block count of each overlay.'),
        c3_array('INTL_COLL_OVERLAY_MAXLEN', 'char', [r[2] for r in rows], 24, '// Longest key of each overlay, in code points.'),
        c3_array('INTL_COLL_OVERLAY_PARENT', 'ushort', [r[3] for r in rows], 12, '// Parent overlay; 0xFFFF ends the chain.'),
        c3_array('INTL_COLL_OVERLAY_FLAGS', 'char', [r[4] for r in rows], 24,
                 '// Bit 0 backwards secondary, 1 alternate shifted, 2 case level, 3 numeric, bits 4-5 caseFirst (1 lower, 2 upper).'),
        c3_array('INTL_COLL_OVERLAY_VARIABLE', 'uint', [r[5] for r in rows], 12, '// Highest variable rank of each overlay.'),
        c3_array('INTL_COLL_OVERLAY_RUNS', 'ushort', [r[6] for r in rows], 12, '// First reorder run of each overlay.'),
        c3_array('INTL_COLL_OVERLAY_RUN_COUNT', 'ushort', [r[7] for r in rows], 12, '// Reorder run count of each overlay.'),
        c3_array('INTL_COLL_REORDER_FROM', 'uint', reorder_from or [0], 12, '// First rank of each reorder run.'),
        c3_array('INTL_COLL_REORDER_COUNT', 'uint', reorder_count or [0], 12, '// Ranks in each reorder run.'),
        c3_array('INTL_COLL_REORDER_TO', 'uint', reorder_to or [0], 12, '// Rank each run moves its first rank to.'),
        c3_array('INTL_COLL_DIGIT_ZEROS', 'uint', digit_zeros, 12, '// The zero of each run of ten decimal digits (Nd), for numeric collation.'),
        c3_array('INTL_COLL_LOCALE_NAMES', 'char', list(name_pool), 24, '// NUL-terminated BCP 47 tags of the collation locales; "und" is root.'),
        c3_array('INTL_COLL_LOCALE_AT', 'ushort', name_at, 12, '// Offset of each locale tag, sorted ASCII case-insensitively.'),
        c3_array('INTL_COLL_LOCALE_DEFAULT', 'char', default_type, 24, '// Collation type each locale uses by default.'),
        c3_array('INTL_COLL_LOCALE_PAIRS_AT', 'ushort', pair_at, 12, "// Start of each locale's pairs, then the end."),
        c3_array('INTL_COLL_LOCALE_PAIRS', 'ushort', pair_words, 12, '// Type index << 10 | overlay of each collation type a locale has.'),
        c3_array('INTL_COLL_TYPE_NAMES', 'char', list(type_pool), 24, '// NUL-terminated BCP 47 collation types, sorted.'),
        c3_array('INTL_COLL_TYPE_AT', 'char', type_at, 24, '// Offset of each collation type name.'),
        f'const uint INTL_COLL_RANK_LOW @feat(INTL_FULL) = {rank_low};  // unassigned code point cp has rank INTL_COLL_RANK_LOW + 1 + cp',
        f'const uint INTL_COLL_MERGE_RANK @feat(INTL_FULL) = {rank_at_most(MERGE_SEPARATOR_PRIMARY)};  // variable ranks are above it',
        f'const usz INTL_COLL_MAX_KEY @feat(INTL_FULL) = {max(r[2] for r in rows)};  // longest key of any overlay, in code points',
        f'const uint INTL_COLL_DIGIT_RANK @feat(INTL_FULL) = {digit_rank};  // rank of digit zero, where numeric runs sort',
        f'const usz INTL_COLL_TYPE_STANDARD @feat(INTL_FULL) = {type_index["standard"]};',
        f'const usz INTL_COLL_TYPE_SEARCH @feat(INTL_FULL) = {type_index["search"]};',
    ]
    header = ('// Generated by scripts/generate_intl_collation.py from ICU 78.3 / CLDR 48. Do not edit.\n'
              'module boomkat::builtins @feat(INTL);\n\n')
    full_source = header + '\n\n'.join(out) + '\n'
    args.out.write_text(full_source)
    generate_small(full_source, args.small_out)
    keys = sum(len(o.entries) for o in overlays.values())
    print(f'{args.out}: {len(root.entries)} root keys, {len(overlays)} tailorings with {keys} keys, '
          f'{len(data)} data bytes, {len(block_first)} blocks, {len(secter_list)} weight pairs, '
          f'{len(reorder_from)} reorder runs, {len(locale_rows)} locales, types {type_names}')


if __name__ == '__main__':
    main()
