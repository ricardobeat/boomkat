# English Intl size measurement

Boomkat's default English numeric/date module is native C3. This experiment links
live ICU4C formatter paths into the actual CLI to measure an alternative.
It does not implement ICU-backed JavaScript constructors.

Measured on arm64 macOS 27 with c3c 0.8.4 and ICU4C 78.3:

| Profile | Added stripped binary bytes | ICU data bytes |
|---|---:|---:|
| Native English NumberFormat + PluralRules | 49,616 | no ICU package |
| Native English DateTimeFormat (increment over numeric module) | 82,672 | no ICU package |
| Native English numeric + date module | 132,288 | no ICU package |
| ICU numbers + plurals + parts + ranges | 1,081,824 | 190,336 |
| ICU numbers + Gregorian dates + parts + ranges | 1,947,488 | 478,560 |

Each comparison uses the same engine sources and build settings: release
Boomkat, linker dead stripping, no exported symbols, and `strip -x`. The
native comparison enables/disables `NO_INTL`. The ICU comparison disables
native Intl in every profile. ICU uses static libraries, `-Oz`, function/data
sections, and filtered `en_US` data with its `en` and root dependencies.
Collation, break iteration, transliteration, regexp, legacy conversion,
IDNA, services and MessageFormat 2 are disabled. Pool bundles are disabled
because their shared keys increase this small data package.

The date probe uses a fixed offset and excludes ICU timezone transition data;
Boomkat already has Temporal's native tzdb. Localized timezone names and
non-Gregorian calendars would require additional data. These numbers measure
this configuration, rather than a theoretical minimum or the cost of a full
ECMA-402 wrapper. Native Intl services support `en` and `en-US`;
other English regions use the `en` conventions.

## Reproduce

Download the official [ICU 78.3 release](https://github.com/unicode-org/icu/releases/tag/release-78.3)
source archive (`icu4c-78.3-sources.tgz`) and data source archive
(`icu4c-78.3-data.zip`). Extract the source archive, then merge the data
archive's `data` directory into `icu/source/data`. Remove the source
archive's prebuilt `icu/source/data/in/icudt78l.dat`: ICU uses it instead of
applying the filter when it is present. Use a disposable source tree.

```sh
python3 scripts/measure_icu_size.py --source /tmp/icu/source --no-intl
python3 scripts/measure_icu_size.py --source /tmp/icu/source --out out/icu-size/native --profiles baseline
python3 scripts/measure_icu_size.py --source /tmp/icu/source --out out/icu-size/native-disabled --profiles baseline --no-intl
```

Subtract the last baseline from the native baseline for the native module's
cost. JSON results, binaries and build/probe logs are retained under the output
directory. Each invocation snapshots the engine sources so profiles remain
comparable during development. The script currently uses macOS linker and
strip flags and requires a C/C++ toolchain, make and c3c.

`probe.c` exercises exact decimal currency formatting and half-up rounding,
field positions, English plural rules, number ranges, and (in the date
profile) date patterns, date fields and intervals. It runs when
`BK_ICU_SIZE_PROBE=1`; both ICU and the engine must complete their smoke calls.

Measure the date module independently with another baseline:

```sh
python3 scripts/measure_icu_size.py --source /tmp/icu/source --out out/icu-size/numbers-only --profiles baseline --no-intl-date
```

Subtract this baseline from the native baseline for DateTimeFormat's cost.

Regenerate the checked-in native English tables with:

```sh
python3 scripts/generate_intl_english.py --source /tmp/icu/source
python3 scripts/generate_intl_dates.py --source /tmp/icu/source
```

The extracted data is covered by `vendor/intl/LICENSE` (Unicode License V3).
