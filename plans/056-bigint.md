# Plan 056: BigInt (proper implementation)

> **Status (2026-07-19):** **All four phases landed on `main`.**
> - Phase 1+2 (primitive, constructor, methods): `f93c597`, `ac6d2ba`,
>   `6b13c34`, `60d5a5b`; test262 wiring `87933ee`. `test/bigint.js` 69/69;
>   `built-ins/BigInt` ~73/77 (rest are out-of-scope arbitrary-precision +
>   `Reflect.construct`). Code reviewed; 3 bugs fixed.
> - TA class descriptor-table refactor: `2b12e4b` (design C — TA_INFO +
>   predicates replace the open-coded ordinal range across 12 sites/7 files).
> - Phase 3 (BigInt64Array/BigUint64Array): `0cd084a` element access +
>   constructors; `d75f2b3` element-type-agnostic prototype methods.
> - Phase 4 (DataView BigInt64): `1127a9a`; also fixed ToBoolean(BigInt) and
>   corrupted DataView/species builtin metadata.
>
> - GC use-after-free fix: `48a35af` — drain_gray did not mark
>   BigInt64Array/BigUint64Array backing buffers (missing from the mark case
>   list, a sibling of the descriptor-refactor range checks). Live BigInt arrays
>   had their ArrayBuffer swept under allocation pressure → reads returned
>   undefined then SIGSEGV. Caught the 3 remaining phase-22 BigInt segfaults.
>
> **Phase 22 (Buffers): 1518 → 2197 pass (+679), 0 unexpected CE.** Remaining 3
> fails: two pre-existing non-BigInt (`ctors/no-species`,
> `ctors/object-arg/iterated-array-with-modified-array-iterator`, the latter
> Float64Array) and one shared `set` ToObject-on-primitive edge case (not
> BigInt-specific). Design principle established: `ta_load_element` /
> `ta_write_element` are the only element-type-aware boundaries; methods carry
> element TVals, never re-derive the type. When adding a TA ObjClass, extend
> both the range checks AND the explicit case-lists (GC mark, dv_elem_size).

## Goal

Turn BigInt from a `typeof`-only stub into a working primitive: literals,
arithmetic, comparison, `BigInt()` / `BigInt.asIntN` / `asUintN`, `toString`,
and the two consumers that motivated this work — `BigInt64Array` /
`BigUint64Array` and `DataView.prototype.{get,set}BigInt64/BigUint64`.

Unblocks ~1718 BigInt-gated test262 tests, including the **476 BigInt
TypedArray fails** that "fix typed arrays" bottomed out in.

## Representation decision — **fixed-width i128** (not arbitrary precision)

BigInt is stored as a native **`int128`** boxed on the heap. Rationale:

- C3 has full native `int128`/`uint128` arithmetic (verified: add/sub/mul/div,
  the whole `±(2¹²⁷−1)` range, correct `printf`). No bignum library needed.
- The 64-bit consumers (`BigInt64Array`, `BigUint64Array`, DataView 64-bit)
  never exceed 64 bits — i128 covers them with headroom, and gives 128-bit
  intermediate space for `asIntN`/`asUintN` wraparound math.
- Covers the overwhelming majority of small-value arithmetic/comparison tests.

### Deliberate limitation (out of scope)

Values beyond **±(2¹²⁷−1)** are not representable. Tests using arbitrary
precision — `2n ** 128n`, large factorials, `asUintN(200, …)`, big
string-constructor cases — are **out of scope**: documented expected-fails /
skip-list, NOT bugs. The `HBigInt` box is deliberately designed so the payload
could later be swapped for a limb array (`sign + ulong[]`) behind the same
interface if the arbitrary-precision tail is ever wanted, without touching
callers.

Overflow policy: an operation whose true mathematical result exceeds i128
range **throws a RangeError** ("BigInt value exceeds supported precision") at
the operation site, rather than silently wrapping. This keeps wrong answers out
of the suite (a wrap would score as a bogus PASS/FAIL); the affected tests fail
cleanly and land on the documented out-of-scope list. (Exception: `asIntN`/
`asUintN` and the TypedArray/DataView element writes wrap by definition — that
is their spec'd modular behavior, not overflow.)

## Current state (what exists)

- `src/types.c3` — `TAG_BIGINT` (0xFFF2), nan-boxed pointer; `is_bigint()`,
  `set_bigint(void*)`. Today the pointer is an **interned `HString*` of decimal
  digits**. This changes to point at an `HBigInt` box.
- `src/lexer.c3` — `123n` / `0xFFn` / `0b..n` / `0o..n` already tokenize as
  `TokenType.BIGINT` (lines ~867, 905, 943, 1065). String value carries digits.
- `src/compiler/constants.c3:141` `add_bigint_constant(digits)` — interns the
  digit string, wraps as BIGINT TVal. **Rewrite** to parse digits → i128 →
  `HBigInt` box constant.
- `src/compiler/expressions.c3:2397` — emits the bigint literal constant.
- `src/heap.c3:1621` — GC marks BIGINT like a string (leaf, `HeapHeader` only).
  `HBigInt` follows the same leaf-mark shape.
- `src/builtins/dataview.c3:403-415` — `getBigInt64`/`setBigInt64`/… are stubs
  that throw `dv_bigint_unsupported`. Builtin IDs 448-451 already reserved;
  dispatch table wired.
- No `BigInt` global, no arithmetic opcodes handle BIGINT operands.

## Phase 1 — Representation + core arithmetic

### Files
- `src/hbigint.c3` (new) — `struct HBigInt { HeapHeader header; int128 value; }`,
  `hbigint_alloc(Heap*, int128) -> HBigInt*`, `hbigint_value(TVal) -> int128`.
- `src/types.c3` — keep `TAG_BIGINT`; `set_bigint` now points at an `HBigInt`.
  Add `TVal.get_bigint() -> int128` helper.
- `src/heap.c3` — allocation + GC leaf-mark for `HBigInt` (mirror the
  `is_bigint()` branch in `mark_tval`; sweep frees the box).
- `src/vm/vm_execute.c3` — arithmetic/comparison opcodes: when **both** operands
  are BIGINT, compute in i128 (`+ - * / % **`, unary `-`, `~`, `& | ^ << >>`,
  `< <= > >= == ===`). Mixed BigInt+Number → **TypeError** (per spec), except
  `==`/`<`/etc. relational which compare by mathematical value.
  Division/modulo by 0n → RangeError. Overflow → RangeError (see policy above).
- `src/compiler/constants.c3` — `add_bigint_constant`: parse the token's digit
  text (decimal/hex/octal/binary, honoring the radix already in the token) into
  `int128`; on out-of-range literal, this is a compile-time RangeError-equivalent
  (the literal is out of scope — surface a clean error).

### Validation
- `test/bigint.js` extended: `10n+20n`, `100n*3n`, `7n/2n`===`3n`, `7n%2n`,
  `2n**10n`, `-5n`, `~5n`, `5n & 3n`, `1n << 10n`, comparisons, `1n == 1`
  (true), `1n === 1` (false), `1n + 1` throws TypeError, `1n/0n` throws.
- No rosetta/corpus regressions.

## Phase 2 — Constructor, methods, conversions

### Files
- `src/builtins/bigint.c3` (new) — `BigInt(x)` (Number/string/boolean →
  BigInt; non-integral Number → RangeError; ToBigInt semantics),
  `BigInt.asIntN(bits, x)`, `BigInt.asUintN(bits, x)` (modular wrap in i128),
  `BigInt.prototype.toString([radix])`, `.valueOf()`, `Symbol.toStringTag`.
- `src/builtins/core.c3` — register `BigInt` global + prototype; reserve builtin
  IDs (append after 453; bump `BUILTIN_COUNT`).
- `src/builtins/number.c3` / ToString path — `String(bigint)` /
  `` `${bigint}` `` produce the decimal string (i128 → digits).
- `typeof` already returns "bigint" — verify still true post-migration.

### Validation
- `built-ins/BigInt/**` (phase excluded today — un-exclude), `asIntN`, `asUintN`,
  `language/literals/bigint/**`, `language/expressions/**` BigInt operand cases.
- Diff phase logs vs baseline: **0 regressions**, count gains.

## Phase 3 — BigInt64Array / BigUint64Array

### Files
- `src/hobject.c3` — add `BIGINT64ARRAY`, `BIGUINT64ARRAY` to `ObjClass`,
  **immediately after `FLOAT64ARRAY`**, so the typed-array range check stays
  contiguous. Audit every `INT8ARRAY..FLOAT64ARRAY` range check
  (`is_typed_array_class`, arraybuffer.c3:126, etc.) → extend upper bound.
- `src/builtins/typedarray.c3` — extend `TA_ELEM_SIZES`/`TA_ELEM_SHIFT`
  (`[9]`→`[11]`, both new = size 8 / shift 3), `ta_class_name`, element
  get/set: BigInt kinds read/write an 8-byte two's-complement i64 ↔ `HBigInt`
  (reuse the Phase-4 primitive). Constructors `builtin_bigint64array` /
  `builtin_biguint64array`; a "content type" check so `set`/constructor reject
  mixing BigInt and non-BigInt arrays (spec throws TypeError).
- `src/builtins/core.c3` — register the two constructors + prototypes.

### Validation
- `built-ins/TypedArray/**/BigInt/**` (476 target fails),
  `built-ins/TypedArrayConstructors/BigInt64Array/**`, `ctors-bigint/**`.
- Full phase-22 (Buffers) diff vs baseline: **0 regressions** (the 766-lesson —
  this touches shared TA element access; verify the TypedArray harness canary).

## Phase 4 — DataView BigInt64

### Files
- `src/builtins/dataview.c3` — replace the four `dv_bigint_unsupported` stubs
  with real `getBigInt64`/`getBigUint64`/`setBigInt64`/`setBigUint64`:
  read/write 8 bytes little/big-endian ↔ i64 ↔ `HBigInt`. The i64↔bytes
  primitive is shared with Phase 3 (factor into `hbigint.c3` or a shared helper).

### Validation
- `built-ins/DataView/prototype/getBigInt64/**`, `setBigInt64/**`, and Uint
  variants. 0 regressions in phase 22.

## Out of scope (documented expected-fails)

- Arbitrary-precision values > i128 (`2n**128n`, big factorials,
  `asUintN(>128, …)`, large string constructors).
- `Atomics` on BigInt arrays (platform/SAB-excluded already).
- `intl402/BigInt` (Intl out of scope).

## Global validation gate (each phase)

1. Clean rebuild of **both** binaries (`rm -rf build/obj`; `boomkat` AND
   `test262_runner` — stale-runner faked results before).
2. Run the affected phase(s) with `--log`, diff PASS set vs baseline:
   **require 0 regressions.**
3. Re-baseline (`sNNN`) at the end; confirm net-positive.
4. Add arbitrary-precision out-of-scope tests to the skip-list with a comment.
