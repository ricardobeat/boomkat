# Plan: size object payloads per class instead of by the largest variant

## Status

📝 PLANNED — the general mechanism is unproven; one concrete instance
(Temporal) was built, measured, and set aside. See "What was tried" and
"The blocker".

## The problem

`HObject` carries its per-class payload in `HObjectExtra`, a union. A union is
sized by its largest member, so **every object in the engine is charged for the
biggest variant**, whatever class it actually is.

Measured member sizes (relative order is what matters; absolute values are from
the declarations in `src/hobject.c3`):

| Member | Size | Used by |
|---|---|---|
| `HObjectTemporal` | **largest** | the 10 `TEMPORAL_*` classes |
| `HObjectFunction` | 72 | FUNCTION |
| `HObjectIteratorHelper` | 64 | ITERATOR_HELPER |
| `HObjectPromise` | 40 | PROMISE |
| `HObjectGenerator` / `Proxy` / `ArrayBuffer` / `BufferView` | 32 | one class each |
| `HObjectRegExp` / `RegExpStringIterator` | 24 | one class each |
| `HObjectIterator` / `WrapForValidIterator` / `GetterSetter` / `Host` | 16 | one class each |
| `HObjectPrimitive` / `HObjectError` | 8 | boxed primitives, ERROR |
| `array_length` (bare `uint`) | **4** | ARRAY |

The distribution is the point. The union is sized by one member that a handful
of object kinds use, while the *common* kinds need a fraction of it:

- an **ARRAY** uses 4 bytes (`array_length`) and is charged the full union
- a boxed **String/Number/Boolean** uses 8
- an **ERROR** uses 8
- a **PROMISE** uses 40

`src/hobject.c3` already documents one instance of this in a comment: widening
Temporal's slots "pushed HObjectTemporal from 64 to 92 bytes… every
FUNCTION/REGEXP/PROMISE object now pays +20 bytes." That comment describes the
general failure mode, not a Temporal quirk.

`alloc_size_for_class()` already switches on `ObjClass` and already has three
size classes (`OBJ_SIZE_PLAIN`, `OBJ_SIZE_ARRAY`, `OBJ_SIZE_GS`), so the idea
that different classes get different sizes is established — but two of those
three still embed the whole union, and everything else falls through to
`OBJ_SIZE_FUNC`.

## The mechanism

Two independent moves, applicable per class:

**A. Right-size the tail.** `alloc_size_for_class` returns
`HObjectBase::size + <this class's payload> + INLINE_EXTRA` instead of
`… + HObjectExtra::size + …`. The union stays as the accessor type; only the
*allocation* shrinks. This is what `OBJ_SIZE_GS` already does for
GETTER_SETTER, so it needs no new machinery — just a size per class and the
discipline that allocation and free agree.

**B. Externalise the outliers.** For a payload far larger than the rest,
allocate it separately and reach it through a pointer (`HObjectHost.payload`
is already in the union and already does this for host classes). This removes
the member from the union entirely, so it stops sizing anything.

(A) is cheap and safe and should come first: it captures most of the win with
no lifetime changes and no new failure modes. (B) is only worth it for a member
that dominates, and it trades memory *back* on the class being externalised —
see the measurements.

## What was tried

(B), applied to Temporal — the largest member and therefore the one setting the
union size. Built, fully verified, then reverted.

| Workload | Payload in union | Payload separate | Delta |
|---|---|---|---|
| 200,000 functions | 113.5 MB | 107.0 MB | **−6.5 MB** (−32 B/obj) |
| 120,000 PlainDates | 34.3 MB | 46.0 MB | **+11.7 MB** (+82 B/obj) |

Break-even is ~2.5 non-Temporal objects per Temporal object. Typical programs
clear that easily, but a Temporal-heavy program regresses, so it was not landed.

Verified during the attempt (the bar for any future version): test262
43,815/281 and phase 26 4,319/281 both unchanged, `just test-local` 371 scripts
0 failed, gc_stress 429/429 on a Temporal fixture, ASAN clean.

**Negative result worth keeping:** routing the separate payload through the pool
allocator (`Heap.pool_alloc`; the payload lands in the 96-byte size class)
changed nothing measurable. The cost is the payload itself, not allocator
overhead — so don't retry that.

The lesson generalises: **(B) is only a win when the externalised class is rare
relative to everything else.** For Temporal that is usually true but not
guaranteed. (A) has no such condition, which is why it should be done first and
may make (B) unnecessary.

## Per-class payload sizes

### Already right-sized

`GETTER_SETTER` → `OBJ_SIZE_GS`. `OBJECT` / `ARGUMENTS` → `OBJ_SIZE_PLAIN`
(no union at all).

### Candidates for (A), by how much each over-pays

| Class | Needs | Currently charged |
|---|---|---|
| ARRAY | 4 B (`array_length`) | full union |
| ERROR | 8 B (`captured_stack`) | full union |
| STRING / NUMBER / BOOLEAN (boxed) | 8 B (`primitive_value`) | full union |
| Iterators, `WRAP_FOR_VALID_ITERATOR`, HOST | 16 B | full union |
| REGEXP, REGEXP_STRING_ITERATOR | 24 B | full union |
| GENERATOR, PROXY, ARRAYBUFFER, typed-array views | 32 B | full union |
| PROMISE | 40 B | full union |
| ITERATOR_HELPER | 64 B | full union |
| FUNCTION | 72 B | full union |

ARRAY and the boxed primitives are the most valuable: they are common and need
almost nothing.

### Temporal, if (B) is revisited

Derived mechanically from every write to `obj.temporal().<slot>` in
`src/builtins/temporal.c3`, grouped by the `ObjClass` of the enclosing
allocator. 8-byte fields on a 64-bit target.

| ObjClass | `big_ns` | longs | ptrs | Bytes | Slots |
|---|---|---|---|---|---|
| `TEMPORAL_CALENDAR` | – | – | – | **0** | none (ISO calendar is a singleton) |
| `TEMPORAL_INSTANT` | 1 | – | – | **8** | `big_ns` |
| `TEMPORAL_TIMEZONE` | – | – | 2 | **16** | `calendar` (⚠ holds an `HString*`), `timezone` |
| `TEMPORAL_ZONEDDATETIME` | 1 | – | 2 | **24** | `big_ns`, `calendar`, `timezone` |
| `TEMPORAL_PLAIN_DATE` | – | 3 | 1 | **32** | `long_a..c`, `calendar` |
| `TEMPORAL_PLAIN_YEARMONTH` | – | 3 | 1 | **32** | `long_a..c`, `calendar` |
| `TEMPORAL_PLAIN_MONTHDAY` | – | 3 | 1 | **32** | `long_a..c`, `calendar` |
| `TEMPORAL_PLAIN_TIME` | – | 6 | – | **48** | `long_a..f` |
| `TEMPORAL_PLAIN_DATETIME` | – | 9 | 1 | **80** | `long_a..i`, `calendar` |
| `TEMPORAL_DURATION` | – | 10 | – | **80** | `long_a..j` |

Distinct sizes: 0, 8, 16, 24, 32, 48, 80. Slot meanings:

- `PlainDate` / `PlainYearMonth` / `PlainMonthDay`: `long_a`=year, `long_b`=month,
  `long_c`=day (or reference day/year — see `plain_yearmonth_day`,
  `plain_monthday_year`).
- `PlainTime`: `long_a..f` = h, mi, s, ms, us, ns.
- `PlainDateTime`: `long_a..c` = date, `long_d..i` = time.
- `Duration`: `long_a..j` = years, months, weeks, days, hours, minutes, seconds,
  ms, us, ns.

## The blocker

Only for the Temporal part; (A) is unaffected.

**`TEMPORAL_TIMEZONE` stores an `HString*` in the `calendar` field**
(`alloc_timezone`), because `HObjectTemporal` has no string slot:

```c3
HString* str = builtin_intern_string(hp, zone_name);
obj.temporal().calendar = (HObject*)str;
```

and `Heap.mark_temporal` marks that field unconditionally:

```c3
if (t.calendar != null) { self.mark_hobject(t.calendar); }
```

`mark_hobject` sets the reachable bit and **pushes the pointer onto the gray
stack**, where the mark loop pops it, switches on `obj.flags.obj_class`, and
dereferences `extra_ptr()` — reading an `HString`'s bytes as object flags and a
union payload.

This is **pre-existing, not introduced by the payload move.** It is invisible
today because interned strings are kept alive by the string table regardless of
the mark bit. It surfaced only because per-class sizing forces a decision about
TimeZone's layout, and any layout that moves `calendar` changes what the GC
reads. 21 call sites read the slot back through `timezone_name()`.

### Prerequisite fix

1. Give `HObjectTemporal` a real string slot (or a tagged slot) for the zone.
2. Point `alloc_timezone` and `timezone_name` at it — 2 writes, 21 reads.
3. Make `mark_temporal` discriminate by `obj_class`, marking `calendar` /
   `timezone` only for classes that hold `HObject*` there. Decide the zone
   string's ownership explicitly rather than by accident.
4. Add gc_stress coverage for TimeZone and ZonedDateTime — nothing exercises
   them today.

Worth doing on its own merits.

## Implementation notes

- **One size function, two readers.** `alloc_size_for_class` and the free path
  must derive the size from the same function. A mismatch is heap corruption
  with no diagnostic — the discipline `pool_class_index` already documents for
  `POOL_BYPASS`.
- Several classes share a shape (the three 32-byte Temporal date types are
  identical), so define structs per *layout*, not per class.
- Keeping a shared prefix at a fixed offset across layouts (e.g. `big_ns`)
  lets the GC read it without switching first.
- Small sizes land in the 48- and 64-byte pool classes, already the hottest;
  check pool pressure with `bench-sizes` rather than assuming.

## Verification gates

Any change here is a memory-layout change on every allocation path, so:

- `just test262` — 43,815 / 281 (this branch's baseline)
- `just test-local` — 371 scripts, 0 failed
- `out/boomkat_gc_stress` — objects reachable only through a payload must
  survive collection; add fixtures for whatever class is being resized
- ASAN build clean — a payload freed on the wrong size class shows up here
- RSS on both a payload-heavy and a payload-light workload. For (A) both should
  improve or hold; for (B) the externalised class regresses by design, so state
  the trade explicitly rather than reporting only the favourable number.

## What this does not address

Reclaiming `ObjClass` variants. The namespace is 6-bit and **62 of 64 are
used**, with Temporal holding 10. Collapsing those into `ObjClass.HOST` with a
registered host class per type would return all 10, but it hits the same
`calendar`-slot problem plus `mark_temporal` becoming a host-class `gc_mark`.
Sequence it after the prerequisite fix.
