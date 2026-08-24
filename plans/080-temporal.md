# Plan 080 — Temporal (`Temporal.*`, the IANA-tz-aware replacement for `Date`)

Status: PLANNED (session 277). Scoped against the live tree. The Temporal
proposal is currently feature-flag-skipped (`scripts/run_test262.py:160`
"built-ins/Temporal" + `:181` "Temporal" in `UNSUPPORTED_PATTERN`), costing
~4,603 test262 tests. Landing this grows the subset under the plan 040
no-silent-shrinkage rule.

This plan picks up cold. It states why, why ICU4X is the wrong tool, what
the engine already has to reuse, what new surfaces are needed, and a
sequenced task list with verification gates.

## Design principle

**Value types for arithmetic, objects only at the JS boundary.** Every
spec algorithm reduces to integer math; the object layer is a thin
prop-getter shell. This is the smallness lever — the heap carries the
minimum number of slots the spec actually requires.

### Code layout: pure libraries in `src/lib/`, engine wiring in `src/builtins/`

Two new pure modules join `src/lib/`:

```
src/lib/bigmath/                    (moved from src/bigmath.c3)
  bigmath.c3                        — limb-vector arithmetic, stdlib only
src/lib/temporal/
  civil.c3                          — CivilDate / CivilTime / CivilDateTime value types
  duration.c3                       — Duration value type + arithmetic
  instant.c3                        — Instant = BigInt nanoseconds
  calendar.c3                       — proleptic-Gregorian / ISO 8601 algorithms
  tzdb.c3                           — $embed'd tzdb blob + binary-search lookup
  iso8601.c3                        — ISO 8601 string formatting (output side)
```

All files in `src/lib/` declare `module boomkat::lib::temporal;` (or
`::lib::bigmath`) and **import only `std::*` and `boomkat::lib::bigmath`**.
No `HObject`, `TVal`, `BuiltinContext*`, `Heap`, `hstring`, or any other
engine type. They are liftable as standalone libraries — drop
`src/lib/temporal/` into another C3 project that provides a `bigmath`
shim and the arithmetic works.

The engine wiring lives in `src/builtins/temporal.c3` (constructors,
prototypes, `Temporal.Now`) and `src/hobject.c3` (one extra variant).
`src/builtins/temporal.c3` imports `boomkat::lib::temporal` and adapts
the value-type API to JS objects.

The `bigmath` move is mechanical: `module boomkat::bigmath` →
`module boomkat::lib::bigmath`, file `src/bigmath.c3` →
`src/lib/bigmath/bigmath.c3`, single importer `hbigint.c3` updated.

## Why / scope

Temporal is Stage 4 (shipped in V8, Safari, JSC), replaces `Date`, and
splits the type system so calendar arithmetic + DST transitions stop
silently misbehaving.

| Surface | Tests (approx, by directory) |
|---|---|
| `built-ins/Temporal/PlainDate` | ~520 |
| `built-ins/Temporal/PlainTime` | ~310 |
| `built-ins/Temporal/PlainDateTime` | ~520 |
| `built-ins/Temporal/PlainYearMonth` | ~280 |
| `built-ins/Temporal/PlainMonthDay` | ~180 |
| `built-ins/Temporal/ZonedDateTime` | ~880 |
| `built-ins/Temporal/Instant` | ~310 |
| `built-ins/Temporal/Duration` | ~640 |
| `built-ins/Temporal/Calendar` | ~290 |
| `built-ins/Temporal/TimeZone` | ~430 |
| `built-ins/Temporal/Now` | ~140 |
| `built-ins/Temporal/(non-class)` (helpers, comparison, calendar-misc) | ~100 |

### Out of scope

- **`Intl.DateTimeFormat`-backed `Temporal.toLocaleString`.** The
  `Date.toLocaleString` shim (`src/builtins/date_locale.c3:4`) is partial;
  Temporal's locale formatters either throw or return ISO strings in this
  phase. Intl is a separate plan (`docs/engine-scope.md`).
- **Non-ISO calendars beyond Gregorian.** ISO 8601 and `gregory` are the
  only test262 fixtures. Hebrew / Islamic / Japanese / etc. land in a
  separate plan; ISO + Gregorian is the floor.
- **`Duration.prototype.round({relativeTo})`.** Implement the no-relativeTo
  form first; relativeTo lands with ZonedDateTime (Phase 2).

## ICU4X is not an option

ICU4X is Rust-only with no stable C ABI for the components Temporal needs.
The experimental `icu_capi` would not be consumable from the C3 toolchain
(`c3c` cannot link a Rust `cdylib`). The minimum ICU4X slice is **~1.0–1.5
MB stripped code plus ~1.5–3.5 MB CLDR/zoneinfo data** — *larger than the
engine's current stripped ES6 binary*, ruling out the 16-bit target
constraint (`-D NONANBOX`, per `AGENTS.md`).

What we ship instead is what V8 ships minus the locale plumbing:

- **Calendar arithmetic** is pure integer math; proleptic Gregorian + ISO
  8601 is a few hundred lines, the polyfill spec gives them as explicit
  algorithms.
- **IANA tz database** ships as a small compiled blob, vendor pattern is
  `libregexp/libunicode.c`. tzdb2025b is ~123 KB compressed / ~430 KB
  uncompressed. We ship the full thing — small in absolute terms.
- **No CLDR.** `Temporal.toString` is locale-free ISO 8601.

## Existing machinery to reuse (do NOT rebuild)

- **`src/date_math.c` + `civil_from_seconds` in `src/builtins/date.c3:64`**
  — proleptic-Gregorian round-trip via Howard Hinnant's
  days-from-civil/inverse. **Lift** `civil_from_seconds` itself into
  `src/lib/temporal/civil.c3` (it has zero engine dependencies — only
  `std::math` for `floor`/`is_nan`, and `floor` is just a constant for
  integers so the stdlib import drops) and have `date.c3` import it.
  Add `epoch_days_from_civil(y, m, d)` next to it in the same file.
  No duplication.
- **`src/builtins/date.c3:39` `date_ms_to_sec`** — pure integer math,
  liftable to `lib/temporal/civil.c3`. Used by both `Date` and
  `Instant`.
- **`src/builtins/date.c3:1488` `date_utc_to_ms`** — **stays in
  `date.c3`**. It uses `boomkat_date_make_time` / `_make_date` from the
  relaxed-fp-math-avoidance C TU (double precision, IEEE-754-rounded per
  ES5 §21.4.1.14/15). Temporal is integer-only and uses
  `epoch_days_from_civil` + a pure nanosecond sum instead, so the two
  share `civil_from_seconds` and `epoch_days_from_civil` but not the
  full MakeDate path.
- **`HBigInt`** (`src/hbigint.c3`) — limb-vector BigInt with arbitrary
  precision, `BIGINT_MAX_LIMBS = 2^26` ceiling. Reused verbatim for
  `Instant.epochNanoseconds` and all `Duration` components.
- **`bigmath`** (after the move, `src/lib/bigmath/bigmath.c3`) — pure
  limb kernels. `lib/temporal` will depend on this and only this.
- **`HObject` + `HObjectExtra`** (`src/hobject.c3:679`) — one new union
  variant holds all Temporal internal slots; `ObjClass` enum gains
  `TEMPORAL_*` values, discriminated by `obj_class`.
- **`ObjFlags`** — no new flags needed. Every Temporal instance is a
  read-only wrapper around internal slots; the existing
  `prop_alloc_size` machinery handles the property table for `toString`
  accessors.
- **`BuiltinContext*`** pattern (`src/builtins/date.c3:101`+) — every
  builtin pulls `this`, checks `obj_class`, reads internal slots, calls
  into pure helpers.
- **`builtin_intern_string`** + ISO 8601 formatters — `date.c3:2237`
  already formats `YYYY-MM-DDTHH:mm:ss.sssZ`. Reused for `Instant`,
  `PlainDateTime` `toString`. Smaller types (`PlainDate`, `PlainTime`)
  use the same `snprintf` pattern.
- **Native accessor pattern** — read-only getters are getter/setter
  pairs (`hobject::ObjClass.GETTER_SETTER`, see `hobject.c3:154`) with
  `prop_flags = W | C` (no enumerable) — used for every
  `Temporal.PlainDate.prototype.year` etc. No own props are user-visible.

## New machinery required

### Storage: one `HObjectTemporal` extra variant

All Temporal types share the same internal-slot union variant; `obj_class`
discriminates which fields are live. Memory layout per object: `HObject`
header (~96 B) + property table for read-only getters (~120 B for the
~10 properties of `PlainDate`) = ~216 B per instance. Compare `Date`'s
~120 B. The extra 96 B is the cost of the strict separation Temporal
mandates (every accessor must validate `obj_class`).

```c3
// src/hobject.c3 — new struct appended to HObjectExtra union
struct HObjectTemporal {
    HBigInt*        big_ns;        // Instant / ZonedDateTime ns; null otherwise
    int             int_a;         // year, hour, or yearRef — depends on obj_class
    int             int_b;         // month, minute, monthRef
    int             int_c;         // day, second, dayRef
    int             int_d;         // ms, microsecond, (PlainTime nanosecond/1000)
    int             int_e;         // µs, nanosecond (the two nano fields of PlainTime)
    int             int_f;         // ns (high 16 bits) — packed with int_e for ns
    HObject*        calendar;      // shared ISO Calendar object
    HObject*        timezone;      // shared TimeZone object (ZonedDateTime)
}
```

**Why one variant, not nine:** the GC walker is one extra branch on
`obj_class` instead of nine new variants in `HObjectExtra`. Total
extra union size is bounded (4 ints + 1 BigInt ptr + 2 HObject* = 56 B),
identical to the cost of one variant per type. **One variant is
strictly smaller.**

Packing: `PlainTime` uses `int_d..int_f` for ms/µs/ns; `PlainDate`
uses `int_a..int_c` for year/month/day; `Instant` uses only `big_ns`;
`Duration` uses `big_ns` for years (a BigInt too big to fit `int`).
ZonedDateTime uses `big_ns` + `timezone`.

### Vendor: `vendor/tzdata/tzdata.bin`

A flat binary blob. Generated from the IANA tz data at build time by a
short Python script (3 modules: `africa`, `europe`, `northamerica`, etc.
combined; `zic`-style). Committed for reproducibility. Layout:

```
Header:
  char[4] magic = 'TZDB'
  uint16  version_year, version_month
  uint32  zone_count, transition_count, rule_count
  uint32  name_table_offset
  uint32  zone_table_offset
  uint32  transition_table_offset
  uint32  rule_table_offset
Names:        char[]  (zone identifiers, '\0'-terminated, sorted)
Zones:        ZoneRecord[zone_count]      // name_idx, until_idx, until_count, offset_idx
Transitions:  int64[transition_count]     // sorted epoch_seconds
Rules:        RuleRecord[rule_count]       // year, month, day, weekday, at_sec, save_min, letter_idx
```

Size: full IANA tzdata = ~430 KB uncompressed (Africa, Americas, Asia,
Atlantic, Australia, Europe, Indian, Pacific + `backward` aliases). The
whole blob is `const char[]` via `$embed("vendor/tzdata/tzdata.bin")`
and lives in `.rodata`. **No allocation at runtime.**

Lookup algorithm: binary search the sorted `transitions[]` for the
instant. Zone transitions are second-precision in the IANA data, so
the spec's "first transition on or after" rule reduces to one
`std::sort::binary_search` (already in stdlib). **No transition
walker, no per-zone struct.** This is the size/efficiency lever.

License: IANA tz data is **public domain** per the upstream `LICENSE`.
This is the single most important licensing point of the plan.

### Calendar math: extend `date.c3`, do not duplicate

```c3
// src/builtins/date.c3 — add next to civil_from_seconds (line 64)

// Inverse of civil_from_seconds; converts proleptic Gregorian y/m/d to
// epoch days since 1970-01-01 (Hinnant's days_from_civil, the forward
// function that civil_from_seconds inverts).
fn long epoch_days_from_civil(long y, long m, long d) {
    long y2 = m <= 2 ? y - 1 : y;
    long era = (y2 >= 0 ? y2 : y2 - 399) / 400;
    long yoe = y2 - era * 400;
    long doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}
```

That's it for the calendar core. Reuses the existing forward function,
mirrors its epoch offset, ~10 LOC.

### Pure arithmetic module: `src/lib/temporal/`

A **statics-only** module hierarchy under `boomkat::lib::temporal`. No
`module boomkat::builtins` dependency, no engine imports. Importable
from any C3 project. Splits along spec axes:

- `civil.c3` — value types `CivilDate { long y; int m, d; }`,
  `CivilTime { int h, mi, s, ms, us, ns; }`, `CivilDateTime`,
  plus `epoch_days_from_civil(y, m, d)` and its inverse. ISO/Gregorian
  only.
- `duration.c3` — `Duration` value type, `balance_duration`,
  `add/subtract_duration`, `round_duration_to`, `total_duration_in`.
- `instant.c3` — `Instant` = `BigInt* ns`, `add_instant`,
  `difference_instant`, `since` / `until`. Thin wrappers over
  `lib::bigmath` calls; duration / calendar interaction passes through
  here.
- `calendar.c3` — `add_days_to_date`, `add_months_to_date`,
  `difference_dates`, `until` / `since` (calendar units). The proleptic
  Gregorian + ISO 8601 algorithms from the polyfill spec.
- `tzdb.c3` — `$embed`'d `vendor/tzdata/tzdata.bin`, binary-search
  lookup of `tzdb_offset_for_zone_at(name, epoch_sec)`. Pure: no
  allocator, just pointer math over a `const char[]`.
- `iso8601.c3` — formatters for ISO 8601 strings (output side only).
  `format_civil_date(buf, d) -> usz`, `format_instant(buf, ns) -> usz`,
  etc. Returns bytes written.

BigInt args are pointers because `bigmath` works on `Limb*` vectors.
Each function is a self-contained spec algorithm.

**Estimated total: ~700 LOC across 6 files.** Pure integer math, no GC
traffic, no HObject reads. Testable with `c3c test` under each file.

### Engine wiring: `src/builtins/temporal.c3`

The JS layer. Imports `boomkat::lib::temporal` and adapts each value-type
API to `HObject` slots:

```c3
fn void builtin_temporal_plain_date_proto_year(BuiltinContext* ctx) {
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
        builtin_throw_type_error(ctx, "this is not a Temporal.PlainDate");
        return;
    }
    // civil.c3 value type reconstructed from heap slots, then read.
    CivilDate d = {
        .y = (long)obj.extra.temporal.int_a,
        .m = obj.extra.temporal.int_b,
        .d = obj.extra.temporal.int_c,
    };
    ctx.result.set_number((double)d.y);
}
```

**Estimated total: ~1500 LOC** for all constructors + prototypes +
`Temporal.Now`. Object creation is the only engine-specific surface in
this layer.

### TimeZone lookup: `src/lib/temporal/tzdb.c3`

```c3
module boomkat::lib::temporal;

const char[] TZDB_BLOB = $embed("vendor/tzdata/tzdata.bin");

struct TzdbHeader { ... } // mirror of binary layout

fn int tzdb_offset_for_zone_at(const char* zone_name, int64 epoch_sec);
fn int tzdb_zone_exists(const char* zone_name);
fn usz tzdb_zone_name(usz idx, char* buf, usz buf_size);
```

Both functions parse the binary header once on first call (cached in a
`bool` static). Binary search of the sorted transitions array. **~250
LOC total.** No allocation, no engine types — pure pointer math over the
`const char[]` blob.

### Builtins: `src/builtins/temporal.c3`

Thin wrapper layer that imports `boomkat::lib::temporal` and adapts
value types to `HObject`. Each builtin is 5–15 lines:

```c3
fn void builtin_temporal_plain_date_proto_year(BuiltinContext* ctx) {
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
        builtin_throw_type_error(ctx, "this is not a Temporal.PlainDate");
        return;
    }
    ctx.result.set_fastint(obj.extra.temporal.int_a);
}
```

The spec mandates property getters return *numbers*, not *fastints* —
so use `set_number` for years/months/days/hours etc. (fastint loss
silently bites here).

**Total estimated size: ~1500 LOC** for all constructors + prototypes +
`Temporal.Now`.

### Object creation: shared `Temporal.createPlainDate` etc.

```c3
fn HObject*? create_temporal_plain_date(Heap* hp, long y, int m, int d) {
    HObject*? o = hp.alloc_object(hobject::ObjClass.TEMPORAL_PLAIN_DATE);
    if (catch e = o) return e;
    HObject* obj = o;
    obj.extra.temporal.int_a = (int)y;   // year fits int32 until ±2 million
    obj.extra.temporal.int_b = m;
    obj.extra.temporal.int_c = d;
    obj.extra.temporal.calendar = get_iso_calendar(hp);
    return obj;
}
```

Reuse `get_iso_calendar` from a single function — it returns the shared
singleton; we never construct more than one. Same for `Temporal.TimeZone`
(the timezone is just a string identifier + the shared blob).

### Locale-free formatters: ISO 8601 only

`toString` is straight ISO 8601. No CLDR. Reuse `date_format_to_string`'s
pattern for the buffer-and-`builtin_intern_string` flow:

```c3
fn void builtin_temporal_plain_date_proto_toString(BuiltinContext* ctx) {
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    char[32] buf;
    usz len;
    if (obj.flags.is_negative_year) {
        len = (usz)snprintf(&buf, 32, "-%06d-%02d-%02d",
            -obj.extra.temporal.int_a, obj.extra.temporal.int_b, obj.extra.temporal.int_c);
    } else {
        len = (usz)snprintf(&buf, 32, "%04d-%02d-%02d",
            obj.extra.temporal.int_a, obj.extra.temporal.int_b, obj.extra.temporal.int_c);
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}
```

A new `is_negative_year` `ObjFlags` bit is the single flag we add —
distinguishes `"-002000-01-01"` from `"002000-01-01"` (extended-year
ISO 8601, mandated for |year| ≥ 10000).

### GC safety

Every Temporal type is `HObject` → walks via the standard
`extra_ptr().temporal.calendar` / `.timezone` (which are GC-traced
objects) and `.big_ns` (a `HBigInt*`, GC leaf). The single
`HObjectTemporal` extra walks like this:

```c3
// src/heap.c3 or wherever the GC marks object fields
fn void mark_temporal(Heap* hp, HObjectTemporal* t) {
    if (t.big_ns)   gc::mark(hp, t.big_ns);
    if (t.calendar) gc::mark(hp, t.calendar);
    if (t.timezone) gc::mark(hp, t.timezone);
}
```

`big_ns` is always set to `null` at allocation time so the fast path
skips the check for `PlainDate`/`PlainTime` etc. The existing
`flags.obj_class` switch in the GC walker gains one case:

```c3
case TEMPORAL_PLAIN_DATE, TEMPORAL_PLAIN_TIME, ... :
    mark_temporal(hp, &obj.extra.temporal);
    break;
```

### No new opcodes

All Temporal arithmetic is C3 statics; builtin wrappers call them.
The existing `OP_ADD` etc. handle the rare integer cases. Spec ops like
`AddDurationToDate` are pure C3 functions taking primitives.

## Files touched

- `src/lib/bigmath/bigmath.c3` — moved from `src/bigmath.c3`. Module
  renames to `boomkat::lib::bigmath`. One importer (`hbigint.c3`)
  updated. Mechanical.
- `src/lib/temporal/civil.c3` — NEW, ~150 LOC. Lifts
  `civil_from_seconds` from `date.c3:64` (verbatim) plus its inverse
  `epoch_days_from_civil`. CivilDate / CivilTime / CivilDateTime value
  types live here. `date.c3` imports `civil_from_seconds` from this
  module; no duplication.
- `src/lib/temporal/calendar.c3` — NEW, ~180 LOC. `add_days_to_date`,
  `add_months_to_date`, ISO 8601 / Gregorian arithmetic per polyfill
  spec.
- `src/lib/temporal/duration.c3` — NEW, ~150 LOC. Duration value type,
  arithmetic, balance, round, total.
- `src/lib/temporal/instant.c3` — NEW, ~80 LOC. Instant + ns arithmetic.
- `src/lib/temporal/tzdb.c3` — NEW, ~250 LOC. `$embed` + binary-search
  lookup.
- `src/lib/temporal/iso8601.c3` — NEW, ~120 LOC. ISO 8601 output
  formatters.
- `src/lib/temporal/lib.c3` — NEW, ~30 LOC. Module root + re-exports
  for convenience.
- `src/hobject.c3` — add `TEMPORAL_*` to `ObjClass`, `HObjectTemporal`
  to the extra union, one new flag `is_negative_year`.
- `src/heap.c3` — extend the GC walker to mark `HObjectTemporal` fields.
- `src/builtins/date.c3` — remove the local `civil_from_seconds`,
  replace with `import boomkat::lib::temporal` + delegate. Net change:
  −32 LOC + 2 lines of import glue.
- `src/builtins/temporal.c3` — NEW, ~1500 LOC. Constructors + prototypes
  + `Temporal.Now`. Imports `boomkat::lib::temporal`.
- `vendor/tzdata/tzdata.bin` — NEW, ~430 KB committed.
- `vendor/tzdata/build.sh` — NEW. Python script that produces the blob
  from the IANA tarball (not committed; the *source* tarball is fetched
  at developer setup time, the *blob* is what ships).
- `scripts/run_test262.py` — remove `built-ins/Temporal` from `SKIP_DIRS`
  (line 160) and `Temporal` from `UNSUPPORTED_PATTERN` (line 181).
- `plans/040-test262-100-percent.md` — update phase table.
- `docs/engine-scope.md` — Temporal graduates from "Stage 3 proposal"
  skip list to "supported, ISO + Gregorian only".
- `docs/architecture.md` — add a Temporal section explaining the
  `src/lib/` layout, the value-types pattern, and the engine-wiring
  separation.

## Phased plan (each phase lands with a green test262 run)

### Phase 0 — `bigmath` move (separate commit, must land first)

- Move `src/bigmath.c3` → `src/lib/bigmath/bigmath.c3`. Rename module
  to `boomkat::lib::bigmath`. Update the single importer
  (`src/hbigint.c3:22`).
- Gate: `just rosetta` + `just test-local` stay green; binary size
  unchanged (no code delta, just file path).

### Phase 1 — `lib/temporal/civil.{h,c3}` + Calendar skeleton

- Lift `civil_from_seconds` from `src/builtins/date.c3:64` into
  `src/lib/temporal/civil.c3` (verbatim). Add `epoch_days_from_civil`.
  Add CivilDate / CivilTime / CivilDateTime value types.
- Update `date.c3` to import `boomkat::lib::temporal` and drop the
  local copy. Net: −32 LOC.
- Land `src/lib/temporal/calendar.c3` (ISO + Gregorian only).
- Land `src/lib/temporal/duration.c3` + `instant.c3` + `iso8601.c3`.
- Land `HObjectTemporal` extra + `TEMPORAL_PLAIN_DATE/TIME/DATETIME/YEARMONTH/MONTHDAY/DURATION`
  + `is_negative_year` flag.
- Land `src/lib/temporal/lib.c3` (module root).
- Land `Temporal.Calendar` constructor + `.from` (returns the ISO
  singleton).
- Land `Temporal.PlainDate` / `PlainTime` / `PlainDateTime` /
  `PlainYearMonth` / `PlainMonthDay` constructors + `from` + `compare` +
  `with` + `add` + `subtract` + `until` + `since` + `equals`.
- Land `Temporal.Duration` constructor + arithmetic + `round` / `total`
  (without `relativeTo`).
- Land ISO 8601 `toString`.
- Lift matching test262 directories in `SKIP_DIRS`. Expected: ~2,800
  new pass / 0 new fail.
- Gate: `just test262` with those directories un-skipped reports 100%
  pass; total failures unchanged from baseline.

### Phase 2 — Instant + TimeZone + ZonedDateTime

- Land `vendor/tzdata/tzdata.bin` + `src/lib/temporal/tzdb.c3`.
- Land `Temporal.Instant` constructor + arithmetic + `since` / `until` +
  `equals` + `toString`.
- Land `Temporal.TimeZone` constructor + `from` +
  `getOffsetNanosecondsFor` + `getPossibleInstantsFor` +
  `getNextTransition` + `getPreviousTransition`.
- Land `Temporal.ZonedDateTime` constructor + `with` + `withTimeZone` +
  `withCalendar` + `add` / `subtract` + `until` / `since` + `equals` +
  `toString` (with offset + zone).
- Lift matching test262 directories.
- Gate: `just test262` zero failures.

### Phase 3 — `Temporal.Now` + disambiguation coverage

- Land `Temporal.Now.instant()` / `now.timeZone()` / `now.plainDateISO()`
  / etc. The plumbing is the reverse of Phase 2.
- Lift `Temporal/Now`.
- Gate: `just test262` zero failures.

### Phase 4 — small odds and ends

- `Temporal.Duration.prototype.round({relativeTo})` — uses Phase 1 +
  Phase 2.
- Explicit `Temporal.Calendar.prototype.dateFromFields` /
  `mergeFields` / `dateAdd` / `dateUntil` (currently implicit through
  constructors).
- Gate: full `just test262` at zero failures, `Temporal` removed from
  `UNSUPPORTED_PATTERN`, `built-ins/Temporal` removed from `SKIP_DIRS`.

### Calendars beyond ISO (separate plan, post-Phase 4)

Each calendar is ~300–800 LOC of arithmetic. Polyfill spec gives Hebrew,
Islamic (tabular + Umm al-Qura), Indian, Persian, Japanese, Coptic,
Ethiopic, ROC. Implement in priority order based on test262 coverage.

## Validation

Per-phase:

- `just rosetta` — must stay green (catches regressions in `TVal` /
  `HObject`).
- `just test262-phase <n>` — for the relevant phase(s); failures must be
  zero.
- `just test262` — full run only at the end of each phase and after the
  final phase.
- `just test-local` — `test/temporal/` fixtures run under the local suite
  (these are the polyfill-spec reference implementations, ported to JS).

Always:

- New C3 statics get `@test` cases in `src/temporal_arith.c3` (no JS
  needed; the test262 fixtures will catch any divergence from spec).
- ASAN: `just build-asan` + `python3 scripts/run_test262.py
  --phase <n>` for each phase's lifted directories.

## Risks / sharp edges

1. **Tzdb second-precision vs nanosecond.** The IANA tzdb is in second
   precision; we multiply by 1e9 in the walker. Pre-1900 sub-second
   transitions follow the polyfill spec's "first transition on or after"
   rule.
2. **`Duration` sign normalization.** Components do not carry
   independent signs. Polyfill spec §"Balance" details the algorithm;
   off-by-one in the carry chain is the most common bug. Cover early.
3. **Disambiguation at DST gap / overlap.** `Temporal.ZonedDateTime`
   from a `PlainDateTime` in a DST gap must reject (`reject`) or pick a
   side (`compatible`, `earlier`, `later`). Spec §"Disambiguate
   PossibleInstants".
4. **Year 2262 ns overflow.** Outside test262. BigInt path is correct
   anyway; the floor for `Date.now()` is the caller's responsibility.
5. **No Intl.** `Temporal.toLocaleString` throws `TypeError` or returns
   the ISO string in this phase.

## Verification method

For each phase:

1. Port the polyfill spec's reference algorithm to a JS test in
   `test/temporal/<phase>/` (these are reproducible, spec-locked).
2. `just run` each fixture; QuickJS + the temporal polyfill are the
   differential oracle.
3. Lift the corresponding test262 directories in
   `scripts/run_test262.py` and run `python3 scripts/run_test262.py
   --phase <n> --log /tmp/t.log`.
4. Cluster failures with `awk` / `sort`.
5. Fix root causes.
6. Re-run; the floor is zero failures.

After all phases:

7. Run full `just test262` and confirm zero net failures.
8. Update `plans/040-test262-100-percent.md` with new per-directory
   numbers.
9. Update `docs/engine-scope.md` and `docs/architecture.md`.

## Estimated cost

- **Pure C3 library** (`src/lib/temporal/`): ~960 LOC across 7 files.
  Liftable as a standalone library — depends only on
  `boomkat::lib::bigmath` and `std::*`.
- **Engine wiring** (`src/builtins/temporal.c3`): ~1500 LOC. The
  builtin layer that imports `lib::temporal` and adapts to `HObject` /
  `TVal` / `BuiltinContext`.
- **`src/lib/bigmath/`** (move only): 0 LOC delta, 1 importer updated.
- **`src/builtins/date.c3`**: −32 LOC (lift `civil_from_seconds`).
- **Vendor data:** ~430 KB committed (`vendor/tzdata/tzdata.bin`).
- **Runtime memory:** the tzdb lives in `.rodata`; per `ZonedDateTime`
  same as a small `Date` (~216 B vs ~120 B).
- **Build time:** the `tzdata.bin` generator runs in <2 s and is
  committed; no per-build network access.
