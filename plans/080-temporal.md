# Plan 080 — Temporal (`Temporal.*`, the IANA-tz-aware replacement for `Date`)

Status: IN PROGRESS. `built-ins/Temporal` runs unconditionally in
`scripts/run_test262.py` (no skip list, no feature-flag gate) — every
test262 file under it is scored on every run. See "Feature list" below
for what passes and what's left.

This plan states why, why ICU4X is the wrong tool, what the engine
already has to reuse, what new surfaces were needed, and the remaining
work.

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
    int             int_d;         // ms, microsecond
    int             int_e;         // µs
    int             int_f;         // ns (PlainTime nanosecond, 0..999)
    HObject*        calendar;      // shared ISO Calendar object
    HObject*        timezone;      // shared TimeZone object (ZonedDateTime)
}
```

**Engine-wide size gate.** `alloc_size_for_class` (src/hobject.c3:781)
routes every FUNCTION/REGEXP/PROMISE/DATE/etc. through
`HObjectBase::size + HObjectExtra::size + INLINE_EXTRA`. The union is
sized by its largest variant, so any variant that exceeds the current
max grows every such object across the heap. A new variant at the top
of the line is an engine-wide cost paid by every program.

Phase 1 must therefore start with a baseline measurement and an assert
holding the line:

```c3
// next to the HObjectTemporal struct declaration
$assert HObjectTemporal::size <= HObjectFunction::size;
```

Baseline (default nanbox build, macOS arm64, 2026-08-24):

| Struct | Size |
|---|---|
| `HObjectBase` | 80 |
| `HObjectFunction` (current max) | 72 |
| `HObjectIteratorHelper` | 64 |
| `HObjectPromise` | 40 |
| `HObjectBufferView` | 32 |
| **`HObjectTemporal` (proposed)** | **48** |
| `INLINE_EXTRA` | 32 |
| `OBJ_SIZE_FUNC` | 184 |

Proposed variant sits 24 B under the max, so adding it costs zero
bytes engine-wide. The assert documents the constraint; if a future
revision pushes `HObjectTemporal` over `HObjectFunction::size` (the
union re-sizes to the new max), the build fails and the implementer
is forced to either shrink the struct or re-examine the layout.

**Why one variant, not nine:** the GC walker is one extra branch on
`obj_class` instead of nine new variants in `HObjectExtra`. Total
extra union size is bounded (1 ptr + 6 ints + 2 HObject* = 48 B),
identical to the cost of one variant per type. **One variant is
strictly smaller.**

If the assert ever fires: pack the six ints into two longs (40 B total)
or move the variant out into a separate heap allocation. Both are
fallbacks, not first choices — readability on the duration and
time-field code matters more than 8 B saved on a union that isn't the
max anyway.

**Why no negative-year flag:** `ObjFlags` is a bitstruct : uint and
bit 29 (has_indexed_named_prop, src/hobject.c3:253) is the highest in
use. Two bits remain. The year sign is already in the slot (`int_a < 0`),
so a flag would be redundant. Branch on the slot value in `toString`.

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
    long year = (long)obj.extra.temporal.int_a;
    char[32] buf;
    usz len;
    // ISO 8601 extended years: a leading sign is required for |year| >= 10000,
    // so 10000-01-01 formats as +010000-01-01, not 10000-01-01.
    if (year < 0) {
        len = (usz)snprintf(&buf, 32, "-%06ld-%02d-%02d",
            -year, obj.extra.temporal.int_b, obj.extra.temporal.int_c);
    } else if (year > 9999) {
        len = (usz)snprintf(&buf, 32, "+%06ld-%02d-%02d",
            year, obj.extra.temporal.int_b, obj.extra.temporal.int_c);
    } else {
        len = (usz)snprintf(&buf, 32, "%04ld-%02d-%02d",
            year, obj.extra.temporal.int_b, obj.extra.temporal.int_c);
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}
```

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
- `src/lib/temporal/duration.c3` — 513 LOC. Duration value type,
  arithmetic, balance, round, total. DONE (2026-09-01).
- `src/lib/temporal/units.c3` — 276 LOC. `TemporalUnit` /
  `TemporalRoundMode` and their pure predicates and rounding
  primitives. DONE (2026-09-01).
- `src/lib/temporal/instant.c3` — NEW, ~80 LOC. Instant + ns arithmetic.
- `src/lib/temporal/tzdb.c3` — NEW, ~250 LOC. `$embed` + binary-search
  lookup.
- `src/lib/temporal/iso8601.c3` — NEW, ~120 LOC. ISO 8601 output
  formatters.
- `src/lib/temporal/lib.c3` — NEW, ~30 LOC. Module root + re-exports
  for convenience.
- `src/hobject.c3` — add `TEMPORAL_*` to `ObjClass`, `HObjectTemporal`
  to the extra union, the `$assert` holding the variant under
  `HObjectFunction::size`. No new `ObjFlags` bits.
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
  (line 160), update the comment on that line from "Stage 3 proposal" to
  "Stage 4 (shipped in V8/Safari/JSC, see plans/080-temporal.md)", and
  remove `Temporal` from `UNSUPPORTED_PATTERN` (line 181). The skip
  removal is gated per Phase 1 sub-step.
- `scripts/run_test262.py` — also update the `built-ins/BigInt` comment
  near line 169: it claims a fixed-width int128 with 130/136 pass, which
  predates commit b61e8d4f. The current implementation is the arbitrary-
  precision limb-vector BigInt (`BIGINT_MAX_LIMBS = 1 << 26` at
  `src/hbigint.c3:33`). Fix the comment so the runner and the engine
  description agree.
- `plans/040-test262-100-percent.md` — update phase table.
- `docs/engine-scope.md` — Temporal graduates from "Stage 3 proposal"
  skip list to "supported, ISO + Gregorian only".
- `docs/architecture.md` — add a Temporal section explaining the
  `src/lib/` layout, the value-types pattern, and the engine-wiring
  separation.

## Feature list

`built-ins/Temporal` runs unconditionally in `scripts/run_test262.py`
(no directory-level skips) — everything is scored on every run.

Per-method failure counts are not listed here; they go stale within a
few commits. Regenerate them:

```sh
just build-bench
python3 scripts/run_test262.py --phase 26 --log /tmp/t.log
grep -P '^FAIL' /tmp/t.log | sed -E 's#.*built-ins/Temporal/##; s#/[^/]+\.js$##' \
  | sort | uniq -c | sort -rn | head -30
```

Work in roughly this order, which tracks tests fixed per line changed:
the not-implemented methods below, then the shared root causes, then
per-type edge cases clustered from the log, then the non-ISO calendars.
The not-implemented methods parallelize safely across agents; the shared
root causes do not, since they touch common helpers.

More than one worktree has been active on this plan at a time. Check
`git worktree list` before claiming a task.

### Shared root causes

One defect surfacing as many unrelated-looking per-method failures.
Check here before treating a cluster as a per-method bug.

- `Duration.round` and `Duration.total` do time-unit-only math. Calendar-unit
  rounding and totals with `relativeTo` need `NanosecondsToDays`,
  `BubbleRelativeDuration`, `AddDaysToZonedDateTime` and `AddDaysToPlainDate`
  per the polyfill spec's "Balance" algorithm. One implementation covers
  both methods.
- `Duration.round`, `Duration.total` and `Duration.compare` each carry a
  verbatim copy of the same ~60-line `relativeTo` parsing block. Changing
  one leaves the others behind. Worth extracting when no agent is mid-edit
  on them.
- `until` and `since` share a difference algorithm across PlainDate,
  PlainDateTime, PlainTime, PlainYearMonth, Instant and ZonedDateTime.

Read property-bag fields with `prop_or_undefined_pa`. `prop_or_undefined`
does a raw slot read that skips getters and the prototype chain.

### Not implemented

These return `undefined`: the function, a `core.c3` enum entry and a
registration line are all missing. Confirm with a `typeof` probe before
starting — the list drifts.

- `Temporal.PlainDateTime.prototype.round`
- `Temporal.PlainDate.prototype.toZonedDateTime`
- `Temporal.Calendar.prototype.dateFromFields`, `mergeFields`, `dateAdd`,
  `dateUntil`. Nothing calls them, so they raise no failures of their own.
  Constructor field validation happens inline in each `Plain*` and
  `ZonedDateTime` constructor instead of routing through them.

A handler and enum entry can exist while the registration line does not,
in which case the method resolves up the prototype chain to
`Object.prototype` and `typeof` still reports `function`. Grep for the
`register_string_proto_method` call, not just the handler.

### Complete (0 failures)

- `Temporal.Calendar` — constructor, `from`, `id`, `toString`, ISO calendar
  only. Its prototype methods are in the not-implemented list.
- `Temporal.Now` — `instant`, `timeZoneId`, `plainDateISO`, `plainTimeISO`,
  `plainDateTimeISO`, `zonedDateTimeISO`.
- Object surface plumbing: `getOwnPropertyNames`, `keys`, `prop-desc`,
  `toStringTag` for every `Temporal.*` namespace.
- `PlainDate`, `PlainDateTime`, `PlainMonthDay`, `PlainTime`,
  `PlainYearMonth`, `ZonedDateTime` constructors, for basic-argument and
  branding tests. Edge-case argument handling still has single-file gaps.

### Calendars beyond ISO

Separate from the list above: Hebrew, Islamic (tabular + Umm al-Qura),
Indian, Persian, Japanese, Coptic, Ethiopic, ROC. Each is ~300–800 LOC
of arithmetic per the polyfill spec. Not started; sequence by test262
coverage once the ISO-calendar gaps above are closed.

## Validation

- `just rosetta` — must stay green (catches regressions in `TVal` /
  `HObject`).
- `python3 scripts/run_test262.py --phase 26 --log /tmp/t.log` — full
  Temporal test262 run; cluster failures with `awk`/`sort` on the log.
  `--single` runs `out/boomkat` and `--phase` runs `out/test262_runner`,
  so build both (`just build-bench`) before comparing their results.
- `just test-local` — `test/temporal/` fixtures run under the local
  suite (polyfill-spec reference implementations, ported to JS).
- New C3 statics get `@test` cases in the same file as the function
  they exercise, under `src/lib/temporal/`. The `@test` framework
  (`std::core::runtime_test`, see c3-lang reference) runs them under
  `c3c test`.
- ASAN: `just build-asan` + `python3 scripts/run_test262.py --phase 26`.

## Risks / sharp edges

1. **Tzdb second-precision vs nanosecond.** The IANA tzdb is in second
   precision; we multiply by 1e9 in the walker. Pre-1900 sub-second
   transitions follow the polyfill spec's "first transition on or after"
   rule.
2. **`Duration` sign normalization.** Components do not carry
   independent signs. Polyfill spec §"Balance" details the algorithm;
   off-by-one in the carry chain is the most common bug.
3. **Disambiguation at DST gap / overlap.** `Temporal.ZonedDateTime`
   from a `PlainDateTime` in a DST gap must reject (`reject`) or pick a
   side (`compatible`, `earlier`, `later`). Spec §"Disambiguate
   PossibleInstants".
4. **Year 2262 ns overflow.** Outside test262. BigInt path is correct
   anyway; the floor for `Date.now()` is the caller's responsibility.
5. **No Intl.** `Temporal.toLocaleString` throws `TypeError` or returns
   the ISO string.

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

---

## Addendum (2026-09-01) — code layout audit and the `relativeTo` zoned-ness bug

Written after a phase-26 audit at 13 failures, all in
`Duration.{round,total,compare}`. Two findings: a correctness bug in a
shared helper, and a measured inventory of what can still be split out
of `src/builtins/temporal.c3`.

### Finding 1 (bug): `read_relative_to_option` discards zoned-ness

`read_relative_to_option` (`src/builtins/temporal.c3`) accepts the
`relativeTo` option for `Duration.prototype.round`,
`Duration.prototype.total`, and `Duration.compare`. When handed a
`Temporal.ZonedDateTime` it reads the wall-clock fields and allocates a
**`Temporal.PlainDateTime`**, returning only that. The fact that the
argument was zoned is not returned anywhere.

All three callers then attempt to recover it from the returned object:

```c
bool is_zdt = (relative_to.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME);
```

The object is the *converted* `PlainDateTime`, so this is **always
false**. Every zoned branch reachable through these three builtins is
dead code.

This matters because the spec distinguishes the two cases: with a
`PlainDate`/`PlainDateTime` relativeTo, days fold into the time total as
uniform 24-hour days (`Add24HourDaysToTimeDuration`, via
`NudgeToDayOrTime`); with a `ZonedDateTime`, a day is whatever the tz
rules make it, and `NudgeToZonedTime` applies. The two agree exactly
when the zone has no offset transitions — which is why UTC-based tests
pass and the bug survived.

Runtime demonstration across a US spring-forward (local day = 23 h):

```js
const zdt = Temporal.ZonedDateTime.from("2024-03-09T00:00:00[America/New_York]");
new Temporal.Duration(0,0,0,1,12).total({unit:"day", relativeTo: zdt});
// produced: 1.5                  (flat 24 h days — unzoned path)
// expected: 1.5217391304347827   (1 + 12/23 — zoned path)
```

**Resolution.** Return a tagged value rather than a bare object:

```c
struct RelativeTo { HObject* dt; bool is_zoned; }
```

Preferred over an `out_is_zoned bool*` out-parameter because it makes
the invariant impossible to ignore at a call site — an out-param can be
silently dropped by a future fourth caller. The `PlainDateTime`
conversion itself is kept: the ISO-calendar difference math wants
wall-clock fields, and only the discarded flag was the defect.

Suspected to be implicated in several of the baseline-13 failures,
including `Duration/compare/throws-when-target-zoned-date-time-outside-valid-limits.js`,
`Duration/prototype/total/relativeto-total-of-each-unit.js`, and
`Duration/prototype/round/relativeto-date-limits.js`.

### Finding 2 (layout): ~905 pure LOC remain in the engine layer

`src/builtins/temporal.c3` is 15,201 lines / 407 functions: 241
`builtin_temporal_*` JS entry points and 166 helpers. Classifying each
helper body by whether it references `BuiltinContext`, `HObject`,
`TVal`, `Heap`, `hbigint`, or `ctx.`:

- **43 helpers are already pure — ~905 LOC**, movable with no signature
  change.
- 123 helpers are legitimately engine-coupled and belong where they are.

Proposed destinations:

| File | Contents | ~LOC |
|---|---|---|
| `duration.c3` (NEW) | `add_durations_no_relative`, `is_valid_duration`, `decompose_ns`/`_128`, `duration_total_ns_from`, `time_ns_split`, `duration_to_time_ns`, `default_largest_unit`, `smallest_unit_count`/`set_`/`clear_below`/`apply_date_part` | ~400 |
| `units.c3` (NEW) | `TemporalUnit` + `TemporalRoundMode` enums, `round_num_to_incr`, `round_long_ns`/`_128`, `unit_ns_divisor`, `max_round_incr`, `is_cal_unit`, `is_date_unit`, `negate_round_mode`, `mode_for_negative*`, `is_half_mode` | ~250 |
| `parse.c3` (existing) | `parse_offset_only`, `parse_unit_str`, `parse_rm_str`, `now_skip_iso_prefix`, `now_find_bracket_zone`, `ci_eq` | ~160 |
| `iso8601.c3` (existing) | `format_fractional_seconds`, `format_offset_seconds` | ~55 |

**Ordering constraint.** `TemporalUnit` and `TemporalRoundMode` are
defined in the engine layer and are parameters to most of the pure
duration helpers. Nothing moves into `duration.c3` until `units.c3`
exists. These enums are shared vocabulary (PlainDate / PlainTime /
ZonedDateTime rounding use them too), which is why they get their own
file rather than living in `duration.c3`.

**`DurationParts` is currently misplaced**: the struct is declared in
`iso8601.c3`, a file about string formatting, while all of its
arithmetic lives in the engine layer. It moves to `duration.c3`.

**`round_date_part` is the one signature change.** It is the sole
duration helper with engine coupling, and shallow: two `builtin_throw`
sites plus a `rebalance_date_part` call. Moving it means returning a
status enum and letting the caller raise the `RangeError` — the library
layer should not know about JS exceptions. Worth doing as its own step.

### Duplication worth collapsing (after the move, not before)

The literal `3600000000000L` occurs at **45 sites**. The
hours→nanoseconds accumulation is re-inlined at ~7 of them (including
lines 1545, 2091, 2337, 2463, 3002, 3335) even though
`duration_to_time_ns` already does exactly this; those should call it.

Care is required: several nearby sites are *decomposition* rather than
accumulation and differ in sign handling and in `int128` vs `long`
width. These are near-duplicates, not duplicates. Consolidate after the
files are split, when the remaining differences are visible side by
side.

### Sequencing

1. Fix `read_relative_to_option` (Finding 1) — a correctness bug,
   independent of any refactor, and the enabling change for the
   remaining zoned-relativeTo failures.
2. Drive phase 26 to 0 failures.
3. `units.c3`, then `duration.c3` — pure code motion, verified by the
   phase-26 count not moving.
4. `round_date_part` status-enum conversion.
5. Extend `scripts/check_temporal_standalone.sh` with duration
   assertions so the new boundary is enforced, not merely intended.
6. Collapse the accumulation duplication.

Steps 3 and 4 are safest once step 2 has landed: the phase-26 count is
the only real correctness signal for pure code motion, and it is most
trustworthy at zero.


## Addendum 2 (2026-09-01) — the split is done

Phase 26 reached 4600/4600, and the pure/engine split the plan called
for is complete.

`src/builtins/temporal.c3` went from 15,520 to 14,488 lines and now
contains **no pure functions at all**: every one of its 155 remaining
helpers genuinely touches `BuiltinContext`, `HObject`, `TVal`, `Heap`,
`HString` or `hbigint`. It is the JS binding layer — coercion,
allocation, property access, error raising — and nothing else.

Three commits, each pure code motion verified by the phase-26 count not
moving:

1. `units.c3` (276 LOC) — the enums plus 15 helpers. This had to come
   first: most pure Duration arithmetic takes a `TemporalUnit` or a
   `TemporalRoundMode`, so nothing else could move while they sat in
   the engine.
2. `duration.c3` (513 LOC) — `DurationParts` (lifted out of
   `iso8601.c3`, where a formatting file had been holding the type)
   plus its 17 arithmetic helpers.
3. The last 15 helpers distributed into `civil.c3`, `iso8601.c3`,
   `parse.c3`, `tzdb.c3` and `instant.c3` by topic.

`scripts/check_temporal_standalone.sh` now exercises the Duration and
unit surface as well as the calendar one, so the boundary is enforced
rather than intended. The guard was verified to still fail as designed
by injecting an engine import into `duration.c3`.

### Why Duration was the one that rotted

Duration was the only Temporal type whose arithmetic never left the
engine layer, and it is where every precision and range bug in this
round of work turned out to live. With no standalone surface, its
int128/float64 conversion logic accumulated across a series of fixes
that could only be validated through the full engine. The other value
types, which had been pure from the start, produced none of these.

### Bugs found along the way

Two were invisible to test262 and worth recording:

- `read_relative_to_option` downgraded a `ZonedDateTime` relativeTo to a
  `PlainDateTime`, so `is_zdt` was permanently false and every zoned
  branch in `Duration.{round,total,compare}` was dead code. Fixing it
  exposed that the tz-aware arithmetic had never been written for
  `total` at all: days were flat 24-hour spans. The correct algorithm
  already existed in `zdt_add_sub` and is now shared as
  `add_zoned_datetime`.
- `builtin_to_number` and `json_parse_number` both guarded
  `set_fastint` with the safe-integer range (±(2^53−1)) when the nanbox
  payload is 48 bits (±2^47), silently corrupting
  `Number("9007199254740991")` and `JSON.parse("9007199254740991")` to
  `-1`. Engine-wide, unrelated to Temporal.

The first is now covered by `test/temporal_duration_dst_spec.js`, which
asserts the non-24-hour day lengths test262 never exercises.
