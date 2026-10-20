# 103: Intl data compaction

The native English Intl services add 132,288 stripped bytes to the CLI
(`scripts/icu_size/README.md`). About 78 KB of that is generated data in
`intl_english_data.c3` and `intl_date_data.c3`; the rest is code. This plan
shrinks the data without giving up random access, then shapes it so that
adding locales costs only what differs from a parent locale.

## Constraints

- **Random access from read-only data.** Lookups read `const` tables in place.
  Nothing is decompressed into the heap: on a microcontroller the tables live
  in flash and RAM is the scarce resource. This rules out the tzdb approach
  (`TZDB_BLOB` is deflated and decoded once into about 91 KB of heap).
- **No relocations.** `String` fields are pointer and length pairs. Each one
  needs a load-time fixup and keeps its table out of pure `.rodata` on some
  targets. Tables hold `ushort` pool offsets instead.
- **The generators do the work.** `scripts/generate_intl_english.py` and
  `scripts/generate_intl_dates.py` emit the compact forms; the C3 side gets
  small decoders. Generated output stays reproducible from ICU 78.3 / CLDR 48.
- **Same observable output.** Every string the services can produce must be
  byte-identical before and after.

## Baseline

Measured from the generated sources (entry count × C struct size, plus string
literals and pools). Struct sizes assume 64-bit `String` (16 bytes).

| Table | Entries | Fixed part | Strings |
|---|---:|---:|---:|
| `INTL_ZONE_NAMES` | 641 | 25,640 | in date pool |
| `INTL_ZONE_ALIASES` | 173 | 5,536 | 4,792 literals |
| `INTL_CURRENCIES` | 307 | 4,912 | in English pool |
| `INTL_DATE_INTERVALS` | 75 | 3,000 | 1,364 literals |
| `INTL_UNITS` | 45 | 1,800 | 306 literals |
| `INTL_DATE_PATTERNS` | 49 | 1,568 | 465 literals |
| `intl_date_strings` | | | 13,580 |
| `intl_english_strings` | | | 15,271 |

`just intl-size` (macOS, stripped, dead-stripped) measured the starting point:
Intl adds 132,320 bytes, 82,688 for the date service and 49,632 for the
numeric services. `TZDB_ZONES` adds 14,328 bytes of `String` rows on top.

After phases 3 to 5 (below) Intl adds 82,800 bytes (date service 33,152,
numeric 49,648) and the whole binary is 66 KB smaller than the baseline,
counting the tzdb rewrite. The golden output is unchanged except for DST after
2037, which the tzdb rules now compute.

Redundancy measured in the same data:

- **Zone names.** 641 rows cover 418 zones, but only 160 distinct name tuples.
  270 rows have no transitions (`from = -inf`, `until = +inf`). Each row
  carries two `long` bounds and six `ushort` offsets, mostly zero.
- **Derivable zone names.** All 86 tuples with generic, standard and daylight
  names follow `X Time` / `X Standard Time` / `X Daylight Time` or
  `X Summer Time`. One base string and a kind bit reproduce them.
- **Duplicated zone IDs.** The date pool holds 419 IANA IDs (6,826 bytes) that
  `TZDB_ZONES` in `src/lib/temporal/tzdata_generated.c3` already stores.
- **Currencies.** The symbol equals the ISO code for 284 of 307. The narrow
  symbol equals the symbol for 216. The plural name is the singular plus "s"
  for 192. Fraction digits take only the values 0, 2, 3 and 4. Currency names
  account for about 12.4 KB of the 15.3 KB English pool.

## Building blocks

### Rank bitmap

A sparse column is a bitmap over the key space plus a packed array holding
values only for set bits. `rank(i)`, the number of set bits below `i`, indexes
the packed array:

```
struct RankBitmap { ulong[] words; ushort[] block_rank; }
// value(i) = has(i) ? packed[block_rank[i / 64] + (words[i / 64] & ((1UL << (i % 64)) - 1)).popcount()] : default
```

`block_rank` holds the running count at each 64-bit word, so a lookup is one
`popcount` (`std::bits`, lowered to the hardware instruction where one exists).
The stdlib `BitSet` is fixed-size and has no rank, so this is a small new
type in `src/lib/` (about 40 lines), generated as `const` arrays.

### Exception columns

Most fields equal a default derived from another field: symbol = code,
narrow = symbol, plural = singular + "s". The table stores a flag bitmap per
derivation and keeps explicit values only for exceptions, through a rank
bitmap.

### Word-token string pools

Pool strings become byte sequences in which `0x01..0x1F` (unused in this data)
or a high-bit escape selects a word from a shared dictionary: "Time",
"Standard", "Summer", "Daylight", "Central", "Islands", "Dollar", "Franc" and
so on. The generator picks the words by bytes saved. Decoding appends into the
caller's `StrBuf`, so strings stay random access. Short strings keep the
current zero-terminated layout.

### Offset-only tables

`IntlDatePattern`, `IntlDateInterval` and `IntlUnitData.name` replace `String`
with `ushort` offsets into the pool: 32 bytes per pattern row become 4.

## Per-table plan

Byte figures are estimates from the counts above. Each phase measures the real
result with the size harness below.

1. **Zone names (about 39 KB to about 6 KB).** Adopt CLDR's metazone model.
   - A metazone table of 160 tuples, each a base-name offset plus kind bits;
     non-derivable names are stored in full.
   - Zones are keyed by their `TZDB_ZONES` index, so no zone ID strings are
     stored. A rank bitmap over the 597 tzdb zones marks the 418 that have
     names.
   - Each named zone stores a metazone byte. The 371 extra periods (641 rows
     minus 270 transition-free ones) store a metazone byte and a 32-bit start.
     The end is the next period's start.
2. **Zone aliases (10.3 KB to under 1 KB).** Store pairs of tzdb indices, or a
   rank bitmap over tzdb indices plus one `ushort` canonical index per alias.
3. **Currencies (about 17 KB to about 6 KB).**
   - Codes: a sorted array of 15-bit packed codes (5 bits per letter) for
     binary search.
   - One flags byte per currency: three derivation bits plus 2 bits of digit
     class.
   - Exception columns for the 23 symbols, 91 narrow symbols and 115 plurals
     that are not derivable.
   - Names go through the word-token pool.
4. **Date patterns, intervals, units (about 6 KB to about 1.5 KB).** Offset-only
   rows. Unit rows reuse the exception scheme where the short and narrow forms
   equal each other.
5. **Pools.** Apply word tokens to whatever remains in both pools and report
   the gain separately, so it can be dropped if the decoder cost outweighs it.

The total target is about 78 KB of data down to 15–20 KB for English. This is
an estimate; the plan is judged on measured stripped-binary bytes.

## Multiple locales

Adding locales turns each table into a matrix, `[locale][key] -> value`.
CLDR already models locales as an inheritance chain (`de_AT` → `de` → `root`),
and most cells equal the parent's value. Each locale stores one rank bitmap per
column over the key space, with a bit set where it differs from its parent,
plus the packed differing values. A lookup walks the chain, at most three
steps in practice, and each step is one bitmap test.

- Currency symbols, unit patterns and zone metazone assignments are mostly
  root data. They are stored once, and the per-locale cost is the
  translations alone.
- Plural rules become a small table of CLDR rule bytecode, shared across
  locales with identical rules. That is a separate item in the locale-support
  plan; this plan only reserves the column.
- Build-time locale selection (`-D INTL_LOCALES=en,de`) emits only the chosen
  rows and their ancestors.

This plan builds the matrix layout for English first, with `en` → `root` as
the only chain, so the second locale adds rows and no new structure.

## Status

The branch implements compact English Intl tables, locale rows, calendar arithmetic
and text segmentation:

- tzdb retains complete historical offsets and transitions, plus shared recurring
  future rules. Data stays in read-only tables; one bounded cache decodes a zone.
- English ListFormat, DurationFormat, DisplayNames and Locale share the Intl host
  registry. Locale identifiers use CLDR aliases and likely subtags.
- `INTL_LOCALES` adds numeric, date, relative-time and list formatting rows. A locale
  matched through likely subtags retains the requested identifier shape.
- `INTL_COLLATOR` adds ICU's root collation, locale tailorings and collation types,
  including contractions and numeric ordering.
- DateTimeFormat and Temporal share all sixteen calendar IDs and calendar fields.
  ZonedDateTime and Duration resolve calendar arithmetic across IANA transitions.
  Temporal locale methods use the internal formatters and retain applicable styles.
- Segmenter implements Unicode 17 default grapheme, word and sentence boundaries,
  UTF-16 segment indices, containing queries and independent iterators. Dictionary
  word segmentation remains outside the profile.
- Array and TypedArray locale methods forward locales and options to each element.
  DateTimeFormat and NumberFormat implement the optional legacy constructor chain.

The runner enables the implemented Intl directories. Non-English formatting fixtures
require `BOOMKAT_INTL_LOCALES=1` with the corresponding build; Collator fixtures require
`BOOMKAT_INTL_COLLATOR=1`. Cross-realm fixtures remain outside the single-realm engine.
The `numbering-system.js` fixture expects an ASCII space before AM where CLDR 48 and
our golden output use U+202F, so it retains an explicit skip.

## Conformance validation

With `INTL_LOCALES` and `INTL_COLLATOR` enabled, intl402 passes 3,350 tests with
zero failures. Its twelve skips are eleven cross-realm fixtures and one CLDR 48
spacing expectation (`DateTimeFormat/prototype/format/numbering-system.js`).
The default English build passes 3,162 tests with zero failures; its additional
skips require the opt-in locale rows or Collator.

Every intl402/Temporal fixture runs in the locale-enabled build:

| Type | Passed | Failed |
|---|---:|---:|
| Duration | 21 | 0 |
| Instant | 17 | 0 |
| Now | 3 | 0 |
| PlainDate | 493 | 0 |
| PlainDateTime | 483 | 0 |
| PlainMonthDay | 90 | 0 |
| PlainTime | 12 | 0 |
| PlainYearMonth | 327 | 0 |
| ZonedDateTime | 583 | 0 |

The built-in Temporal directory passes 4,605 tests, Rosetta passes 42, and the
local suite passes 605 script files plus its module, exception, robustness and
TypeScript checks. `staging/intl402` has no directory in this test262 checkout;
its obsolete directory skip is removed.

The `NO_INTL`, `NO_INTL_DATE`, `boomkat_slim` and `NONANBOX` builds compile and
pass their smoke checks. The non-NaN-boxing build also passes the Segmenter and
calendar-aware Duration local fixtures.

## Phases

1. **Size harness.** Add `just intl-size`. It builds `boomkat` with and without
   `NO_INTL` and `NO_INTL_DATE`, strips both, and prints the deltas next to the
   per-table byte counts from a generator `--report` flag. Record the baseline
   in this file.
2. **Golden dump.** Before changing any encoding, add a test that enumerates
   every producible string: every currency field, every unit pattern, every
   zone name for every period, every date and interval pattern. It writes them
   to a golden file. Every later phase must reproduce that file exactly.
3. **Offset-only tables** (patterns, intervals, units): the smallest change,
   and it validates the generator and decoder plumbing.
4. **Zone names and aliases** through tzdb indices, metazones and rank
   bitmaps. This is the largest single gain.
5. **Currency derivation and exception columns.**
6. **Word-token pools**, measured separately.
7. **Matrix layout** with `root` and `en` as the first two rows.

Each phase is its own commit with its measured delta.

## Validation gates

- The golden dump is byte-identical.
- `just test262-suite intl402` and `staging` pass with the same counts as
  before. The current baseline is intl402 591 passing and 0 failing.
- `just rosetta`, `just test-local`, and the `NO_INTL`, `NO_INTL_DATE` and
  `boomkat_slim` builds pass.
- Lookup cost: benchmark formatting 10,000 dates in a dozen zones, and
  currency formatting over all 307 codes. Neither may regress by more than
  noise, since rank lookups replace direct indexing.
- `-D NONANBOX` build, for the 16-bit target path.

## Related

- Temporal's tzdb is done: transitions are stored as `zic -b slim` data plus
  shared POSIX footer rules, read in place (no deflate, no heap), with
  front-coded zone names. The binary shrank by 16.6 KB and the 91 KB heap
  pool is gone; DST now continues past 2037. Phase 4 keys Intl zone data by
  the zone index `tzdb_zone_index` returns.
- The other 54 KB of the Intl footprint is code. A follow-up should profile
  per-function sizes in the date formatter, which is the largest.
