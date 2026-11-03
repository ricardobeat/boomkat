# Plan 025: Remaining Gaps from 014 Review

**Date:** 2026-06-11
**Status:** Done, closed 2026-11-03. The items below are covered by the zero-fail
test262 gate (plans 040 and 052).

## Summary

The 014 review recommended 6 next steps. Plans 022 and 023 addressed #1 (property descriptors) and #2 (missing methods).
Three items remain entirely untouched, and the error-propagation item is only partially done.

## Untouched

### 3. for-of / iterator protocol (Phase 14)

**Estimated impact:** 700+ passes (currently 4/751)
**What's needed:** Implement `Symbol.iterator`, `.next()`, `{value, done}` for arrays, strings, Map, Set.

### 4. Class features (Phase 15)

**Estimated impact:** 59 → 500+ passes (currently 64/8,520)
**What's needed:** Private fields/methods, static blocks, class expression edge cases.

### 5. Promise microtask scheduling (Phases 17–20)

**Estimated impact:** ~100+ passes
**What's needed:** Async microtask queue; `.then`/`.catch` resolution order.

## Partially Done

### 6. Error propagation in nested call_fn

- ✅ Array callbacks propagate errors (Session 149/151)
- ❌ Sort comparator throws still swallowed
- ❌ JSON replacer throws still swallowed
