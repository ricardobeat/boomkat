# Plan 051: Parallel Fix Batch — Targeting ~350 Tests

**Status:** Active (session 277)
**Baseline:** 28,590 pass / 2,023 fail / 167 CE = 92.9%
**Target:** ~350 additional passes

## Analysis

Full test262 failure analysis via 4 parallel explore agents. Root causes identified across all clusters.

## Tasks (5 parallel agents)

### T1: Class method enumerable flag + constructor-call check (~80 tests)

**Files:** `src/compiler/class.c3`, `src/vm/vm.c3` or `src/vm/vm_control.c3`

1. **Class methods non-enumerable** (11 FAILs): Class methods use PUTPROP/INITPROP with `{e:true}`. Per ES2015 §14.5.14 step 9, class methods must be `{writable:true, enumerable:false, configurable:true}`. In `class.c3:640` (non-static) and static method paths, change the property flags to non-enumerable. Accessor names (getter/setter) also need `{e:false}`.

2. **Class constructor callable without `new`** (25 FAILs): Calling a class constructor without `new` must throw TypeError. The VM call dispatch must check `is_class_ctor` flag on the function and throw TypeError if `new` was not used.

3. **Async class methods** (56 FAILs): Ensure async class methods compile with `is_async=true` and the resulting function is callable. Check that the method body compilation path propagates the async flag.

### T2: Symbol protocol guard on String.prototype methods (~70 tests)

**Files:** `src/builtins/string.c3`

When `match`, `matchAll`, `replace`, `replaceAll`, `search`, `split` are called with a primitive searchValue/separator (number, boolean, string), the spec says to skip `@@match`/`@@replace`/etc. Symbol dispatch and go straight to ToString. The engine currently tries to access Symbol-keyed properties on primitives, hitting "Cannot convert a Symbol value to a string".

Fix: In each of the 6 methods, guard Symbol dispatch with `search_val.is_object()` check. If the search value is a primitive, skip Symbol dispatch entirely.

Additionally fix:
- `startsWith`/`endsWith`/`includes`: Add `IsRegExp` check before ToString (6 tests)
- `String.prototype.valueOf`/`toString`: Throw TypeError for non-String `this` via `thisStringValue` (2 tests)
- `padStart`/`padEnd` length metadata: Change arity from 2 to 1 in `builtin_get_metadata` (2 tests)
- `localeCompare` missing metadata: Add case 300 to `builtin_get_metadata` (5 tests)
- `slice` Infinity-to-integer UB: Add `is_inf` bounds check before `(int)(long)` cast (3 tests)

### T3: Object literal super + reserved words as property names (~80 tests)

**Files:** `src/compiler/expressions.c3`, `src/compiler/parser.c3`

1. **`super.property` in object literal methods** (23 CEs + ~3 FAILs): Set `has_super_binding = true` before compiling object literal method bodies (`function_expr_body`), restore after. Object literal concise methods must inherit `__super__` from the enclosing scope's prototype chain.

2. **Reserved words as property names** (24 CEs from `language/identifiers` + related): In object literal property names, member access after `.`, class method names, and getter/setter names, accept any keyword token and treat its lexeme as a string key. Per ES5 §7.6, property-name and member-access positions accept any IdentifierName (including reserved words).

3. **Duplicate data properties in object literals** (2 CEs): Remove the duplicate data property rejection in `object_literal()`. Per ES2015+, duplicate data properties are permitted (later value wins).

### T4: Array.prototype quick wins + Object.entries/values order (~60 tests)

**Files:** `src/builtins/array.c3`, `src/builtins/object.c3`

1. **Array.prototype[Symbol.iterator] === Array.prototype.values** (1 test + TypedArray equivalent): Set `Symbol.iterator` to the same function object as `values` during prototype initialization.

2. **Object.entries/values enumeration order** (8 tests): Integer-index properties must sort before string properties. Fix the entries/values implementation to use the same code path as `Object.keys`.

3. **Object.isFrozen/isSealed for built-in constructors** (14 tests): Built-in constructor objects (TypeError, ReferenceError, etc.) are NOT frozen. The engine incorrectly reports them as frozen. Fix the isFrozen/isSealed implementation.

4. **Object.getPrototypeOf for Error subclasses** (7 tests): `Object.getPrototypeOf(ReferenceError)` should return `Error`. Fix the prototype chain for NativeError constructors.

5. **Array.prototype.concat TypedArray spreading** (2 tests): TypedArrays with `Symbol.isConcatSpreadable = true` must be spread by concat.

### T5: Function.prototype quick wins + arguments-object fixes (~60 tests)

**Files:** `src/builtins/function.c3`, `src/compiler/parser.c3`, `src/compiler/statements.c3`

1. **Function.prototype.call/apply thisArg boxing** (8 tests): `ToObject(thisArg)` when thisArg is a primitive (e.g., `f.apply(1)` should box to `Number(1)`).

2. **Function.prototype.caller/arguments accessors** (3 tests): Implement `AddRestrictedFunctionProperties` — define `caller` and `arguments` as accessor properties on `Function.prototype` using `%ThrowTypeError%`.

3. **Function.prototype.name property** (2 tests): Add `name=""` property with correct descriptor (non-writable, non-enumerable, configurable).

4. **Trailing comma + spread arguments** (14 tests): Fix argument counting when trailing comma follows spread element.

5. **`new Expr()()` — calling result of `new`** (3 CEs): After parsing `new MemberExpression Arguments`, let the outer call-expression loop handle trailing `()`.

## Verification

After all 5 agents complete:
1. Build: `c3c build test_vm && c3c build boomkat`
2. Rosetta: `just rosetta` (must be 99/100)
3. Test each fix with specific test262 tests
4. Commit all, update progress.md with new numbers
