# Plan 022: Property Descriptor Correctness

**Date:** 2026-06-10
**Status:** PENDING
**Estimated impact:** 2,000–4,000 new test262 passes

## Motivation

Property descriptor correctness is the single largest remaining failure category, accounting for ~3,000+ failing tests across Phases 3 (Object System), 5 (Built-in Constructors), 6 (Prototype Methods), and 8 (ES5 Built-in Objects). Fixing it would roughly double the current pass rate.

## Root Cause Analysis

### Bug A: `seal()`/`freeze()` skip dense array parts

**File:** `src/hobject.c3:495-514`

`HObject.seal()` and `HObject.freeze()` iterate only `prop_count` (named properties), ignoring `array_part` elements. After `Object.seal([1,2,3])`, the dense elements remain writable and configurable. `isSealed()` and `isFrozen()` in `src/builtins/object.c3:1667-1731` make the same mistake — they return `true` for arrays with only dense elements even though those elements are not actually sealed/frozen.

**Tests affected:** ~240 directly (seal/freeze/isSealed/isFrozen), cascading to ~400-800 total.

### Bug B: `defineProperty` ES5 §8.12.9 algorithm incomplete

**File:** `src/builtins/object.c3:1114-1228`

The current implementation:
- Correctly rejects `configurable`/`enumerable` changes on non-configurable properties
- Correctly rejects type changes (accessor↔data) on non-configurable properties
- Correctly rejects writable→non-writable→writable transition on non-configurable data properties
- But does **not** correctly handle partial descriptor updates per the full §8.12.9 algorithm, especially:
  - Accessor→data conversion during non-configurable update
  - Generic descriptor merging edge cases
  - Validation order for combined data+accessor descriptors

**Tests affected:** ~1,131 `defineProperty` + ~632 `defineProperties` + cascading = ~1,500-2,000 total.

### Bug C: `getOwnPropertyDescriptor` hardcodes dense array flags

**File:** `src/builtins/object.c3:658-697`

When a key matches a dense array index (not found in named props), the code hardcodes `{writable: true, enumerable: true, configurable: true}` instead of reading the actual property flags from the array part. After `seal()` or `freeze()`, these flags should reflect the restricted state.

**Tests affected:** ~310 + cascading = ~350-400 total.

### Bug D: `Object.assign` uses `put_prop` instead of `[[Set]]`

**File:** `src/builtins/object.c3:1943`

Per ES2015 §19.1.2.2, `Object.assign` must use `[[Set]](P, val, receiver)` which invokes setters and respects non-writable data properties. The current implementation calls `put_prop` directly, bypassing these checks.

**Tests affected:** ~38 directly + cascading (setter chains, non-writable targets) = ~100-200 total.

### Bug E: `for-in` enumeration order

**File:** `src/vm.c3:884-954`

`collect_forin_keys` enumerates: string exotic indices → named props → dense indices. ES2020 §13.7.5.15 specifies: integer indices ascending → string keys in creation order → Symbol keys. The mismatch causes order-dependent test failures.

**Tests affected:** ~115-150 total.

### Bug F: Builtin method `.writable`/`.configurable` flags

Builtin methods registered with `PROP_FLAGS_NWC` where ES5 §15.3.5.1 requires `.length` to be non-writable but configurable. Session 137 fixed the most impactful cases but some edge cases remain (e.g., specific builtin methods, constructor properties).

**Tests affected:** ~300-500 total.

## Implementation Plan

### Step 1: Fix `seal()`/`freeze()` dense array handling

**Files:** `src/hobject.c3`, `src/builtins/object.c3`

Extend `seal()` to set array elements non-configurable. Extend `freeze()` to set array elements non-writable and non-configurable. Fix `isSealed()` and `isFrozen()` to verify array element states.

**Difficulty:** Easy (1-2 sessions)
**Impact:** ~400-800 new passes

### Step 2: Fix `getOwnPropertyDescriptor` dense array flags

**File:** `src/builtins/object.c3`

Read actual `HObject.array_part` flags instead of hardcoding. After Step 1, seal/freeze will set these correctly, so this step will produce correct output.

**Difficulty:** Easy (1 session)
**Impact:** ~350-400 new passes

### Step 3: Complete `defineProperty` ES5 §8.12.9 algorithm (or at least the bugs in it)

**File:** `src/builtins/object.c3`

Implement the full `[[DefineOwnProperty]]` algorithm. This is the most complex step — the algorithm has 7 validation steps with specific ordering. The key gaps found in the current code:
- Partial descriptor merging for accessor↔data transitions
- Validation order when both `Get` and `[[Value]]`/`[[Writable]]` are present in a descriptor

**Difficulty:** Complex (3-4 sessions)
**Impact:** ~1,500-2,000 new passes

### Step 4: Fix `Object.assign` to use `[[Set]]`

**File:** `src/builtins/object.c3`

Replace `put_prop` with a call to `[[Set]]` (via `vm_set_prop` or equivalent). This needs to handle the receiver argument correctly.

**Difficulty:** Medium (1-2 sessions)
**Impact:** ~100-200 new passes

### Step 5: Fix `for-in` enumeration order

**File:** `src/vm.c3`

Reconstruct `collect_forin_keys` to emit keys in ES2020 order: integer indices (ascending by numeric value), string keys (insertion order), Symbol keys (insertion order).

**Difficulty:** Medium (1-2 sessions)
**Impact:** ~115-150 new passes

### Step 6: Audit builtin method flags

**File:** `src/core.c3`, `src/builtins/*.c3`

Audit all builtin method registrations for correct `.writable`, `.configurable`, `.enumerable` flags per ES5 §15. Fix any that are wrong.

**Difficulty:** Medium (2 sessions)
**Impact:** ~300-500 new passes

## Total Estimated Impact

| Step | Direct | Cascading | Total |
|------|-------:|----------:|------:|
| 1 | ~240 | ~160-560 | ~400-800 |
| 2 | ~310 | ~40-90 | ~350-400 |
| 3 | ~1,131 | ~370-800 | ~1,500-2,000 |
| 4 | ~38 | ~60-160 | ~100-200 |
| 5 | ~115 | ~0-35 | ~115-150 |
| 6 | ~200 | ~100-300 | ~300-500 |
| **Total** | **~2,034** | **~730-1,945** | **~2,765-4,050** |

Pass rate would increase from ~53% to ~63-70%.

## Dependencies

Steps 1-2 must precede Step 3 (defineProperty depends on correct array flag state for validation tests). Steps 4-6 are independent.

## Testing

After each step, run:
```
python3 scripts/run_test262.py --phase 3
python3 scripts/run_test262.py --phase 5
python3 scripts/run_test262.py --phase 6
python3 scripts/run_test262.py --phase 8
```

Full validation:
```
python3 scripts/run_test262.py
```
