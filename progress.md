# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 174 (Object.assign [[Set]] semantics: setters, non-writable, non-extensible)
**Target:** 80% test262 pass rate on ES5/ES6 core

## Summary (after Session 174, 2026-06-14)

| Metric | Value |
|---|---|
| Total test262 tests | 42,013 |
| ES5-relevant tests | ~26,353 |
| Currently passing (phases 0-8) | ~12,677 |
| Currently failing (phases 0-8) | ~7,887 |
| Overall pass rate | ~61.4% |

## Per-Phase Status

| Phase | Total | Pass | Fail | Skip |
|---|---|---|---|---|
| 0-1: Core VM | 2,185 | 593 | 295 | 1,297 |
| 1: Calling Convention | 426 | 58 | 30 | 338 |
| 2: Basic Operators | 1,969 | 969 | 175 | 825 |
| 3: Object System | 7,766 | 3,618 | 2,181 | 1,967 |
| 4: Error Handling | 402 | 108 | 93 | 201 |
| 5: Built-in Constructors | 8,615 | 4,374 | 2,716 | 1,525 |
| 6: Prototype Methods | 4,713 | 1,883 | 1,894 | 936 |
| 7: ES5 Features | 1,240 | 193 | 100 | 947 |
| 8: ES5 Built-in Objects | 2,747 | 881 | 403 | 1,463 |
| 11: Arrow/Templates | 427 | 60 | 43 | 324 |
| 12-13: Destructuring | 19 | 0 | 0 | 19 |
| 14: for-of | 751 | 3 | 29 | 719 |
| 15: Classes | 8,520 | 62 | 200 | 8,258 |
| 17-20: Map/Set/Symbol/Promise | 1,614 | 240 | 400 | 974 |
| 21: Generators | 619 | 0 | 2 | 617 |

## Deferred Items

- Async microtask scheduling (Promise tests)
- Private class fields/methods
- Nested/advanced destructuring patterns
- Reflect, Proxy

## Test Infrastructure

- **Phase runner**: `python3 scripts/phase_runner.py 2 --workers 2 --timeout 10` (detailed failures) 
- **Quick test**: `bash test262_runner/quick.sh`
- **Phase counts**: `bash scripts/count_test262_by_phase.sh`
- **Build**: `c3c build batch_test_vm` or `c3c build test_vm`
- **Run full test262 suite**: `python3 scripts/run_test262.py` (multi-worker, parallel)

## Session Log (condensed, newest first, last 10 sessions)

| Session | Summary | test262 impact |
|---|---|---|
| 174 | Object.assign proper [[Set]] semantics (ES2015 §19.1.2.2): added `obj_assign_set` helper implementing full [[Set]] with Throw=true — invokes setters (own + prototype chain), throws TypeError on non-writable data properties, throws TypeError on non-extensible target for new properties. Source values now fetched via [[Get]] (invokes source getters). Also fixed `desc_get` error propagation: copies `error_value` to `throw_value` and clears `has_error` flag. | TBD (Phase 5: ~25-35 for Object.assign) |
| 173 | PUTPROP strict-mode TypeError for non-extensible objects (ES5 §9.1.2 step 5b): when property doesn't exist and object is not extensible, throw TypeError in strict mode. Previously silently ignored in all modes. | +236 (Phase 3: +96, Phase 5: +44, Phase 6: +10, Phase 7: +2, Phase 8: +16) |
| 172 | CompilerContext defaults to non-strict mode (ES5 §10.4.1): `this` at global scope is now the global object, not undefined. Fixes GOPD on global built-ins, property descriptor tests, and `this` binding across phases. 43 Rosetta tests pass including `this_binding.js`. | +47 net (Phase 0-1: +18, Phase 3: +58) |
| 171 | Math constant property flags: `set_num_prop_lookup` used `PROP_FLAGS_WC` (writable=true, configurable=true) for Math constants like E, PI, LN2, etc. Changed to `PROP_FLAGS_NNC` (writable=false, enumerable=false, configurable=false) per ES5 §15.8.1. Fixes 8 GOPD tests + ~11 Math prop-desc tests. | +19 (Phase 3: GOPD + Math) |
|| 170 | Lexer dot-property access: fix fractional-part parsing to distinguish `0..x` (number + property access) from `0...x` (ellipsis) by checking three-dot prefix; make fraction digits optional per ES5 §7.8.3 (`0.` is valid). Fixes 38 radix toString tests + 11 other dot-property tests. | +49 (Phase 0-1: +9, Phase 6: +40) |
| 169 | Array.prototype.sort ES2022 compliance: comparefn TypeError check before length access; temp buffer collect+sort+writeback replacing in-place compact; vm_to_string for default comparison (calls toString on objects); scoped delete_prop to clear named properties. | +8 (Phase 6 sort: 9→17) |
| 168 | Object static method non-object TypeError: Object.keys and Object.getOwnPropertyNames now throw TypeError for null/undefined (was returning undefined silently). Audit of all Object static methods confirmed seal/freeze/preventExtensions correctly return arg per ES2015 §19.1.2.x; isExtensible/isSealed/isFrozen correctly return boolean per ES5. Fixed incorrect docstring on isExtensible. | +2 (phases 3) |
| 167 | defineProperties non-configurable validation: presence-aware checks for enumerable/configurable (ES5 §8.12.9 step 8), data↔accessor type-change rejection, writable false→true rejection, accessor SameValue rejection on non-configurable properties. Fixes spurious TypeError when descriptor omits fields on non-configurable properties. | +16 (phases 3,5,6) |
| 166 | Array.prototype length validation: proper ToUint32 (ES5 §9.6) for array_get_length, eliminating UB for Infinity/NaN lengths. Added array_to_length_checked with SameValue validation that throws RangeError per ES5 §15.4.4.x. Updated forEach/map/filter/every/some/reduce/reduceRight/indexOf/lastIndexOf. | TBD |
| 165 | Assignment expression eval order fix: PUTVAR clears source register, so expression-assignment results (x=1, x+=1, x||=1, etc.) were returning undefined. Fixed by saving value to temp before PUTVAR clobber in compiler/expressions.c3. Also added Reflect global object. | +45 (phases 0-1,2,7) |
| 164 | ToString decimal precision fix: progressively trim trailing digits in decimal notation path (vm_number_to_string, builtin_to_string, Number.prototype.toString) to produce shortest round-trip representation; e.g. 123.1234567→"123.1234567" not "123.12345670000001" | +46 (phases 3,5,8) |
| 163 | NEW_OBJ lightfunc constructable check: non-constructor builtins (Object.seal/freeze/keys/etc.) now throw TypeError on `new` via `lightfunc_get_proto()` null check | +170 (phases 3,5,6) |
