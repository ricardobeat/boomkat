#!/usr/bin/env python3
"""Generate the root collation table behind Intl.Collator from ICU 78.3 / CLDR 48.

Input is the output of scripts/intl/dump_collation.c. Each explicit code point
gets a run of 32-bit ICU collation elements, packed as primary << 16 |
secondary << 8 | tertiary. Code points in a UCA implicit class are stored as
runs with the class number; the engine derives their weights from the code
point (UCA 9.1 section 10.1). Their primaries sit above every 16-bit explicit
primary, since ICU's explicit radicals already use the FB00 range.

Explicit code points through U+1FFFF are a rank-indexed bitmap; the few above
it are a sorted list, searched by binary search.
"""
import argparse
from pathlib import Path


def c3_array(name, ctype, values, per_line, comment):
    lines = [comment, f'const {ctype}[*] {name} @feat(INTL_COLLATOR) = {{']
    for i in range(0, len(values), per_line):
        lines.append('    ' + ', '.join(f'0x{v:X}' for v in values[i:i + per_line]) + ',')
    lines.append('};')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dump', type=Path, required=True)
    parser.add_argument('--out', type=Path, default=Path('src/builtins/intl_collation_data.c3'))
    args = parser.parse_args()

    explicit = {}
    runs = []
    variable_top = None
    for line in args.dump.read_text().splitlines():
        parts = line.split('\t')
        if parts[0] == 'explicit':
            explicit[int(parts[1], 16)] = [int(c, 16) for c in parts[2].split(',')]
        elif parts[0] == 'implicit':
            runs.append((int(parts[1], 16), int(parts[2], 16), int(parts[3])))
        elif parts[0] == 'variable':
            variable_top = int(parts[1], 16)
    assert variable_top is not None, 'dump is missing the variable-top line'

    bitmapped = sorted(cp for cp in explicit if cp <= 0x1FFFF)
    high = sorted(cp for cp in explicit if cp > 0x1FFFF)
    assert all(explicit[cp] and len(explicit[cp]) <= 64 for cp in explicit)
    # ICU splits some 64-bit elements into a word whose tertiary byte is 0xC0
    # and secondary is 0. Those words carry more primary bits, so they take
    # tertiary 0 (UCA 9.1 section 10.1) and are exempt from the range check.
    def is_continuation(ce):
        return (ce & 0xFFFF) == 0x00C0
    for cp in explicit:
        explicit[cp] = [ce & ~0xFF if is_continuation(ce) else ce for ce in explicit[cp]]
    assert all((ce >> 16) <= 0xFFFF for ces in explicit.values() for ce in ces), 'explicit primaries are 16-bit'
    assert all(0 <= c <= 5 for _, _, c in runs)

    # Bitmap and rank over U+0000..U+1FFFF, one 64-bit word per 64 code points.
    words = [0] * 2048
    for cp in bitmapped:
        words[cp // 64] |= 1 << (cp % 64)
    rank, total = [], 0
    for w in words:
        rank.append(total)
        total += bin(w).count('1')
    assert total == len(bitmapped) and total < 65536

    ces, counts = [], []
    for cp in bitmapped + high:
        counts.append(len(explicit[cp]))
        ces.extend(explicit[cp])
    # One start per block of 32 code points; a lookup adds the counts before it.
    block_at = [sum(counts[:i]) for i in range(0, len(counts), 32)] + [len(ces)]

    out = [
        c3_array('INTL_COLL_BITS', 'ulong', [w for w in words], 4,
                 '// Bit cp set when code point cp below 0x20000 has explicit collation elements.'),
        c3_array('INTL_COLL_RANK', 'ushort', rank, 16,
                 '// Explicit code points before each 64-code-point word of INTL_COLL_BITS.'),
        c3_array('INTL_COLL_HIGH_CPS', 'uint', high, 12,
                 '// Explicit code points at or above U+20000, sorted.'),
        c3_array('INTL_COLL_COUNT', 'char', counts, 24,
                 '// Element count of each explicit code point, in index order: bitmap rank, then INTL_COLL_HIGH_CPS.'),
        c3_array('INTL_COLL_BLOCK_AT', 'uint', block_at, 12,
                 '// Offset in INTL_COLL_CES of the first element of each block of 32 explicit code points.'),
        c3_array('INTL_COLL_CES', 'uint', ces, 8,
                 '// 32-bit ICU collation elements: primary << 16 | secondary << 8 | tertiary.'),
        c3_array('INTL_COLL_IMPLICIT_FIRST', 'uint', [r[0] for r in runs], 12,
                 '// Implicit runs in code point order: first code point.'),
        c3_array('INTL_COLL_IMPLICIT_LAST', 'uint', [r[1] for r in runs], 12, '// Last code point of each implicit run.'),
        c3_array('INTL_COLL_IMPLICIT_CLASS', 'char', [r[2] for r in runs], 16,
                 '// UCA implicit class of each run: 0 core Han, 1 other Han, 2 Tangut, 3 Nushu, 4 Khitan, 5 unassigned and private use.'),
        f'// Code points with explicit elements before INTL_COLL_HIGH_CPS, the rank of the first high entry.\nconst usz INTL_COLLATION_BITMAPPED @feat(INTL_COLLATOR) = {total};',
        f'// Primaries at or below this are variable: ignored by ignorePunctuation.\nconst ushort INTL_COLL_VARIABLE_TOP @feat(INTL_COLLATOR) = 0x{variable_top:X};',
    ]
    header = ('// Generated by scripts/generate_intl_collation.py from ICU 78.3 / CLDR 48 (root collation).\n'
              '// Do not edit.\nmodule boomkat::builtins;\n\n')
    args.out.write_text(header + '\n\n'.join(out) + '\n')
    print(f'{args.out}: {len(bitmapped)} bitmapped + {len(high)} high explicit code points, {len(ces)} elements, {len(runs)} implicit runs')


if __name__ == '__main__':
    main()
