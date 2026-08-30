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

## What mature engines do

Worth settling before choosing a mechanism, because neither reference engine
does what this plan first proposed.

**QuickJS** uses a union, like this engine. The difference is what goes in it:
almost every member is a **pointer to a separately allocated struct**
(`quickjs.c`, `struct JSObject`):

```c
union {
    struct JSMapState *map_state;        /* js_malloc'd */
    struct JSPromiseData *promise_data;
    struct JSProxyData *proxy_data;
    struct JSTypedArray *typed_array;
    struct { ... } func;                 /* 24 bytes, inline */
    struct { ... } array;                /* 24 bytes, inline */
    JSRegExp regexp;                     /* 16 bytes, inline */
    ...
} u;
```

Their union is **24 bytes on 64-bit** — the source comments say so per member
(`12/24 bytes`, `12/20 bytes`, `8/16 bytes`). Only small, hot payloads live
inline; anything larger is `js_malloc(ctx, sizeof(*s))` behind a pointer. The
union cannot grow, because there is an implicit ceiling on what may go in it.

**V8** does not use a union at all: separate `JSObject` subclasses, each with
its own `kHeaderSize` and instance size, dispatched on `InstanceType`. Different
mechanism, same principle — no object pays for another class's fields.

Neither uses flexible array members for this.

## The mechanism: cap the union, spill the rest

The defect here is not "we use a union". It is that a 104-byte payload was put
**inside** it. QuickJS would never have hit this, because `HObjectTemporal`
would have been a pointer from the start.

So adopt QuickJS's rule explicitly:

1. **Cap `HObjectExtra` at 32 bytes**, enforced by `$assert` so it cannot
   silently regress. The existing comment in `src/hobject.c3` — that widening
   Temporal's slots meant "every FUNCTION/REGEXP/PROMISE object now pays +20
   bytes" — describes exactly the regression a cap would have caught at compile
   time instead of in a code review.
2. **Anything over the cap becomes a pointer** to a separately allocated
   struct, freed by the owning class.
3. **Everything at or under stays inline**, where it costs nothing.

Measured against a 32-byte cap:

| Over the cap → pointer | Bytes |
|---|---|
| `HObjectTemporal` | 104 |
| `HObjectFunction` | 72 |
| `HObjectIteratorHelper` | 64 |
| `HObjectPromise` | 40 |

| At/under the cap → stays inline | Bytes |
|---|---|
| `HObjectGenerator`, `HObjectProxy`, `HObjectArrayBuffer`, `HObjectBufferView` | 32 |
| `HObjectRegExp`, `HObjectRegExpStringIterator` | 24 |
| `HObjectIterator`, `HObjectWrapForValidIterator`, `HObjectGetterSetter`, `HObjectHost` | 16 |
| `HObjectPrimitive`, `HObjectError` | 8 |

Union today 104 → 32 with the cap: **72 bytes off every object**.

Twelve of sixteen members already fit. The cap is not a redesign; it names a
rule the code mostly follows already, and flags the four places it does not.

### The cap also finds *why* a struct is oversized

`HObjectFunction` is 72 bytes where QuickJS's `func` is 24. Reading it shows
why: it carries arrow-function fields (`captured_this`, `captured_new_target`)
and bound-function fields (`bound_target`, `bound_this`, `bound_args`) inline —
5 fields, 40 bytes, dead on an ordinary function. QuickJS puts bound-function
state in a separate `JSBoundFunction*`.

So exceeding the cap is a signal, not just a size to fix: it usually means a
struct is carrying a rare variant's fields for every instance. The remedy may be
splitting the variant out rather than making the whole payload indirect — which
is the better fix for FUNCTION, the hottest allocation path in the engine.

## Rejected: flexible array members

`Ty[*]` is real and specified — the last field of a struct may be an unsized
array, contributing no size, with storage extending past the declared size.
An audit found it would be **safe** here: 3,320 `HObject*` uses and **zero**
by-value uses, no nesting, no array-of-HObject, so all three spec restrictions
(no embedding, no array element, no copy by value) already hold. The engine
already runs the pattern by hand in `HBigInt` (`header + limbs()` at
`(char*)self + HBigInt::size`) and in `HObject.extra_ptr()`.

It was rejected anyway:

- Neither QuickJS nor V8 uses it for this, so it would be a novel mechanism
  where a well-tested one exists.
- Per-class allocation sizes require the allocation path and the free path to
  agree on a computed size. A mismatch is heap corruption with no diagnostic.
  The cap has no such hazard: every object is one size.
- **The compiler does not enforce the spec's restrictions.** `struct Nested
  { Obj inner; }` compiles silently despite being forbidden. The audit would
  have to become a permanent CI guard rather than a one-time check.

Two constructs found alongside it are still worth using and are independent of
the mechanism:

**Contract-checked payload access.** `@require` becomes a runtime assertion in
safe builds and an optimizer hint in release:

```c3
<*
 @require o != null
 @require o.base.cls == $expect : "payload class mismatch"
*>
macro @pay($Type, Cls $expect, Obj* o) => ...;
```

Verified: safe mode reports `@require "o.base.cls == $expect" violated:
'payload class mismatch'`; release elides it. A union permits reading any
member of any object silently — which is how the TimeZone `HString*` pun below
went unnoticed. This turns that class of bug into a caught violation.

**Enum associated values as a size table**, derived from the structs
themselves so it cannot drift:

```c3
enum ObjClass : char (usz psize) { ARRAY { ArrP::size }, ... }
```

`c.psize` reads at runtime off the enum value, no switch.

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
