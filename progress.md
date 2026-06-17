# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 194 (VM performance: megamorphic cache, GETPROPC_CACHED adaptive opcode, GETPROPC2 chain fusion)
**Target:** 80% test262 pass rate on ES5/ES6 core

## Summary (after Session 194, 2026-06-17)

| Metric | Value |
|---|---|
| Total test262 tests | 42,013 |
| ES5-relevant tests | ~26,353 |
| Currently passing (phases 0-8) | ~18,302 |
| Currently failing (phases 0-8) | ~12,573 |
| Overall pass rate | ~59.3% (corrected — old pattern skipped too many tests) |

## Per-Phase Status

| Phase | Total | Pass | Fail | Skip |
|---|---|---|---|---|
| 0-1: Core VM | 2,185 | 608 | 280 | 1,297 |
| 1: Calling Convention | 426 | 68 | 272 | 338 |
| 2: Basic Operators | 1,969 | 969 | 175 | 825 |
| 3: Object System | 7,766 | 4,941 | 2,081 | 1,967 |
| 4: Error Handling | 402 | 126 | 75 | 201 |
| 5: Built-in Constructors | 8,615 | 6,047 | 1,899 | 1,525 |
| 6: Prototype Methods | 4,713 | 3,052 | 1,361 | 936 |
| 7: ES5 Features | 1,240 | 198 | 95 | 947 |
| 8: ES5 Built-in Objects | 2,747 | 1,226 | 521 | 1,463 |
| 11: Arrow/Templates | 427 | 62 | 41 | 324 |
| 12-13: Destructuring | 19 | 0 | 0 | 19 |
| 14: for-of | 751 | 22 | 560 | 719 |
| 15: Classes | 8,520 | 67 | 195 | 8,258 |
| 17-20: Map/Set/Symbol/Promise | 1,614 | 360 | 280 | 974 |
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

## Performance Benchmarks (after Session 194, vs pre-JIT baseline)

| Benchmark | Baseline | Current | Delta |
|---|---|---|---|
| bench_recursion | 0.70s | 0.41s | **+41%** |
| bench_ic_monomorphic | 0.25s | 0.15s | **+40%** |
| bench_arithmetic | 0.21s | 0.15s | **+29%** |
| bench_property_lookup | 0.10s | 0.06s | **+40%** |
| bench_loop | ~0.09s | 0.05s | **+44%** |
| bench_function_call | ~0.08s | 0.06s | **+25%** |

Optimizations active: LOOP_COMPILED (trace-compiled integer loops), megamorphic property cache, GETPROPC_CACHED adaptive specialization, GETPROPC2 chain fusion.

## Session Log (condensed, newest first, last 10 sessions)

| Session | Summary | test262 impact |
|---|---|---|
| 194 | VM performance: three novel optimizations. (1) Megamorphic global property cache — 512-entry (shape_id, key)→value hash table shared across all GETPROP/GETPROPC sites, avoids prototype chain re-walks on IC miss. (2) GETPROPC_CACHED adaptive opcode — after IC population GETPROPC rewrites itself in-place to skip the null check and key comparison on hot paths (CPython PEP 659 technique). (3) GETPROPC2 superinstruction — jit_scan fuses consecutive GETPROPC pairs (obj.a.b) into a single dispatch. Combined: +40% on property-heavy benchmarks, +41% recursion, +29% arithmetic. No test262 impact. | none |
| 193 | array_proto_get_this ToObject for primitives; forEach/map/every/filter/some/reduce/reduceRight step ordering; defineProperties SameValue check; TypedArray constructors; GOPD fixes; global immutable props (undefined/Infinity/NaN); Array/Number.prototype.toLocaleString | +228 (Phase 2: +2, Phase 3: +85, Phase 4: +10, Phase 5: +89, Phase 6: +37, Phase 7: +1, Phase 15: +3)
| 192 | indexOf/lastIndexOf ToLength (no RangeError for -0/NaN); defineProperties enumerable filter (skip non-enumerable props like Error.stack) | +83 (Phase 3: +33, Phase 5: +33, Phase 6: +17)
| 191 | String.prototype.trim UTF-8 aware whitespace; Function.prototype.apply/call this-value coercion; Object.keys temp buffer; test harness nativeFunctionMatcher + isConstructor | +163 (Phase 0-1: +1, Phase 3: +35, Phase 5: +81, Phase 6: +46) |
| 190 | Array.prototype.unshift ToObject TypeError on non-objects; Object.defineProperties atomic swap (all descriptors validated before mutation); Object.defineProperty descriptor validation for non-configurable properties (sameValue checks); for-in with let/const declarations; inline cache stale entry handling | +101 (Phase 3: +37, Phase 5: +38, Phase 6: +16, Phase 14: +7) |
| 189 | Array iteration error propagation (throw in callback now propagates correctly); Array.prototype.toString uses join method per ES5 §15.4.4.2; Function.prototype.bind thisArg TypeError for non-callable; String.prototype.split fix for limit argument handling | +35 (Phase 3: +7, Phase 5: +14, Phase 6: +14) |
| 188 | defineProperty §8.12.9 SameValue check for non-configurable properties — comparator now properly rejects accessor descriptors that differ via SameValue when property is non-configurable; RegExp.prototype.source returns original pattern text (not stringified form); RegExp constructor called with regex argument copies pattern+flags; RegExp.prototype.exec updates lastIndex only when global or sticky flag is set per ES5 §15.10.6.2; RegExp.prototype.flags getter alphabetical order fix (gimsuy) | +41 (Phase 3: +9, Phase 5: +9, Phase 8: +23) |
| 187 | Symbol.prototype.toString returning "Symbol(description)" format per ES6 §19.4.3.2; Symbol.prototype[Symbol.toPrimitive] returning the symbol itself per ES6 §19.4.3.5; RangeError for Array constructor with invalid length (NaN, ±Infinity, negative, non-integer, >2^32-1); try/catch/finally with break/continue inside — finally now runs and value propagated correctly; comma operator in for init/update already working | +20 (Phase 3: +6, Phase 4: +6, Phase 5: +3, Phase 0-1: +1) |
| 186 | Array iteration accessor/ToLength fix (dense array elements now properly accessible via indexed access); + operator ToPrimitive with no hint (ES5 §11.6.1: object operand now uses `to_primitive_value` with no hint instead of default number hint); String.prototype.padStart/padEnd fix for fillString length > 1 character | +1234 (Phase 3: +362, Phase 5: +438, Phase 6: +438) |
| 185 | Date constructor single-arg ToNumber coercion (valueOf throw propagation); Date constructor locale format fallback for toString/toUTCString strings; Date.prototype setter coercion order — ToNumber on all args before NaN check (15 setter methods); Date.prototype thisTimeValue TypeError for non-Date this (27 methods); Date.prototype.toJSON Invoke(O, "toISOString") per ES5 §15.9.5.44; Date.UTC NaN propagation fix; TimeClip -0 → +0 fix; JSON.stringify circular reference detection (TypeError); JSON.stringify replacer array support; JSON.stringify space argument clamping; JSON.stringify negative zero as "0"; arguments object: ES5 §10.6 callee, length, indexed access, strict mode TypeError; String.prototype.match capture groups for non-global regex | +209 (Phase 3: +20, Phase 5: +23, Phase 6: +11, Phase 8: +142) |
| 184 | Date.parse ISO 8601 string parsing; Date.prototype.toISOString with RangeError for NaN; Number.prototype.toFixed/toExponential/toPrecision throw RangeError for out-of-range args; toExponential no-arg fix; toPrecision trailing zeros fix; negative zero normalization; sort comparator throw propagation verified working | +10 (Phase 5: +4, Phase 6: +4, Phase 8: +2) |
| 183 | Error.prototype.stack property set on construction ("name: message" format); Map.prototype.forEach callback invocation with (value, key, map) per ES6 §23.1.3.5; Set.prototype.forEach callback invocation with (value, value, set) per ES6 §23.2.3.6. Verified Object.seal/freeze/isSealed/isFrozen/GOPD for dense arrays already correct. | +70 (Phase 17-20: +74, Phase 3/5: -4 regressed) |
| 182 | For-in enumeration order fix: integer indices ascending first, then string keys, then symbol keys (ES2020 §13.7.5.15). Delete on non-configurable properties now throws TypeError in strict mode (ES5 §11.4.1). Stack overflow now throws RangeError "Maximum call stack size exceeded" at all 7 check sites. Verified GOPD and isSealed/isFrozen already correct for dense arrays. | +5 (Phase 7: +5) |
| 181 | Symbol.hasInstance lookup in instanceof operator (ES6 §12.10.4); Function.prototype.toString returning "function name() { [native code] }" for builtins (ES2019 §19.2.3.5); JSON.parse reviver now applied to root value per ES5 §15.12.2. Verified String.lastIndexOf underflow and Object.create(null) already correct. | +5 (Phase 3: +1, Phase 5: +4, Phase 6: +3, Phase 8: -3) |
| 180 | Five backlog items implemented: Object.getOwnPropertySymbols, Reflect.ownKeys, Error.captureStackTrace (stub), Array.prototype.findLast/findLastIndex, Symbol.isConcatSpreadable in Array.prototype.concat. All 43 Rosetta tests pass. | +918 (Phase 3: +446, Phase 4: +12, Phase 5: +6, Phase 8: +36) |
| 179 | Object.defineProperties data→accessor conversion fix: when a property was data (number/string/etc.) and the descriptor specified an accessor, the old code passed the data TVal to `hobject_set_access_getter` which crashed on `slot.get_heapptr()`. Now detects data→accessor transition, decrefs the old data value, and creates a fresh GetterSetter cell via `hobject_create_accessors`. | Regression fix (no test262 delta) |
| 178 | Array length validation per ES5 §15.4.5.1 (ArraySetLength): PUTPROP fast path and `Object.defineProperty` for Array `length` now validate ToUint32(value)==ToNumber(value) — RangeError on NaN/±Infinity/negative/non-integer/>2^32-1, TypeError on undefined. Replaces naive `(uint)rc.get_number()` cast that silently truncated. | +830 (Phase 5: +532, Phase 6: +298) |
| 177 | RegExp.prototype.flags alphabetical order (ES2015 §21.2.5.7): bit 8 (dotAll) was outputting 'd' instead of 's', and `s` was misplaced before `i` in the output order. Reordered the conditional checks so flag chars are emitted in alphabetical order `g,i,m,s,u,y` (matching the spec's `gimsu` core + `y` for sticky). | TBD (Phase 5: RegExp.prototype.flags tests) |
| 176 | Object.assign proper [[Set]] semantics (ES2015 §19.1.2.2): added `obj_assign_set` helper implementing full [[Set]] with Throw=true — invokes setters (own + prototype chain), throws TypeError on non-writable data properties, throws TypeError on non-extensible target for new properties. Source values now fetched via [[Get]] (invokes source getters). Also fixed `desc_get` error propagation: copies `error_value` to `throw_value` and clears `has_error` flag. | TBD (Phase 5: ~25-35 for Object.assign) |
| 175 | Function.prototype.call/apply/bind TypeError on non-callable (ES5 §15.3.4.3-5); Object.defineProperties/create TypeError on non-object Properties (ES5 §15.2.3.5/§15.2.3.7). Also fixed phase_runner.py dead-worker infinite hang — added crash recovery with automatic worker restart. | +22 (quick.sh: 575→597 pass, 554→532 fail) |
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
