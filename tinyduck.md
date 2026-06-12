# TinyDuck — A Minimal Non-Conforming JavaScript Engine

> **No prototypes. No descriptors. No cruft. Real JS, trimmed to essentials.**

## What Is This?

A deliberate non-conforming JS runtime that drops the ~60,000 LOC of Duktape down to an estimated ~11,000 LOC by removing features that add massive implementation complexity but are rarely needed in embedded scripting (game logic, config, device control).

The guiding principle: **everything you need, nothing you don't**.

---

## What's In

| Feature | Notes |
|---|---|
| Primitives | `number` (double), `string`, `bool`, `null`, `undefined` |
| Variables | `var`, `let` |
| Control flow | `if/else`, `while`, `for`, `do...while`, `switch/case`, `break`, `continue`, `return` |
| Functions | First-class, closures, arrow functions, `this` binding (obj.method + new) |
| **Classes** | `class`, `new`, `super`, instance fields, getters/setters in literals |
| **Promises** | `new Promise`, `.then`, `.catch`, `Promise.all`, `Promise.race` |
| **async/await** | Desugars to promise chains via state machine |
| **for...of** | Duck-typed: calls `.next()` until `{done: true}` |
| **Modules** | Static `import`/`export` only, resolved at parse time |
| Template literals | No tagged templates |
| Destructuring | `var {a, b} = obj`, `var [x, y] = arr` |
| Spread | `[...arr]`, `...args` in calls |
| Getters/setters | Object literal syntax only (`get x() {}`, `set x(v) {}`) |
| `typeof`, `instanceof` | Basic forms |
| `try/catch/finally` | Standard error handling |
| Equality | `===` / `!==` everywhere; `==`/`!=` only for null/undefined coalescing |
| Builtins | `Array`, `Object`, `Math`, `JSON`, `String`, `Number`, `Date`, `RegExp`, `Error`, `console` |

## What's Out

| Dropped Feature | Why | Est. LOC Saved |
|---|---|---|
| **Prototypes** | No proto chain, no `__proto__`, no `Object.create`, no `Object.getPrototypeOf` | ~1500 |
| **Object.defineProperty** | No descriptors, no configurable/enumerable/writable | ~3000 |
| **Proxies, Reflect** | Intercept every internal method | ~2000 |
| **Symbols** | New primitive, well-known symbols on every protocol | ~600 |
| **eval()** | Runtime parser dependency | ~500 |
| **with** | Runtime scope chain walking | ~300 |
| **arguments** | Aliasing, slicing, non-strict mapping; use `...rest` | ~800 |
| **Strict vs sloppy mode** | Doubles many code paths; everything is "strict-ish" by default | pervasive |
| **Private fields (#x)** | Syntax + enforcement complexity | ~400 |
| **Generators/iterators** | Stackful coroutines, protocol overhead | ~1500 |
| **WeakMap/WeakSet/WeakRef** | GC finalizer interaction | ~500 |
| **Tail call optimization** | Interacts with every call path | ~200 |
| **ASI (auto semicolon insertion)** | Parser complexity, ambiguity | pervasive |
| **Property enumerability** | Every for...in/Object.keys must check | ~300 |
| **Dynamic import()** | Runtime module loading | ~200 |
| **import.meta** | Module metadata | ~50 |

---

## Design Decisions

### 1. No Prototypes — Flat Class Tables

This is the single biggest win. Duktape's property lookup is:

```
obj → obj.__proto__ → obj.__proto__.__proto__ → ... → Object.prototype → null
```

Every `obj.x` walks this chain. TinyDuck replaces this with:

```
obj own property → class method table → done
```

**Concrete model:**

```javascript
class Vec2 {
  var x: double;
  var y: double;

  fn length() -> double {
    return Math.sqrt(this.x * this.x + this.y * this.y);
  }
}

var v = Vec2{1.0, 2.0};
v.length();  // resolved from Vec2's method table, not a chain
```

- Instance methods live in a per-class flat method table, shared by reference
- `v instanceof Vec2` → single tag/ID check, no chain walk
- `for (var k in v)` → own properties only
- Monkey-patching (`v.foo = ...`) works for own properties, not across instances
- No `Object.create`, no `__proto__`, no prototype assignment

### 2. Duck-Typed for...of (No Symbol.iterator)

```javascript
// Arrays — built-in iterator
for (var x of [1, 2, 3]) { print(x); }

// Custom iterables — just needs .next()
class Range {
  var end: number;
  var cur: number;

  fn next() {
    if (this.cur >= this.end) return { value: undefined, done: true };
    return { value: this.cur++, done: false };
  }
}

for (var i of Range{10, 0}) { print(i); }
```

The `for...of` bytecode checks: does this value have a `.next()` method? If yes, call it in a loop. No Symbol, no `@@iterator`, no protocol indirection. ~200 LOC instead of ~1500.

### 3. Promises + async/await

```javascript
var p = new Promise(function(resolve, reject) {
  resolve(42);
});
p.then(function(val) { print(val); });

async fn fetchData() {
  var resp = await httpGet("/api/data");
  return JSON.parse(resp);
}
```

- Microtask queue: simple linked list drained after each macro task
- async/await: bytecode state machine transform
- `Promise.all`, `Promise.race` included
- No `Promise.allSettled`, `Promise.any`

### 4. Static Modules

```javascript
// math.tdjs
export fn add(a, b) { return a + b; }
export class Vec2 { ... }

// main.tdjs
import { add } from "./math.tdjs";
```

Static imports only. No dynamic `import()`. The linker resolves everything at parse time via topological sort, then compiles each module into a closure.

### 5. Always Strict

No strict/sloppy mode toggle. TinyDuck is always strict-ish:
- No octal literals (use `0o` prefix)
- No `this`-coercion to global
- No `delete` on plain variables
- No duplicate parameters

This eliminates pervasive dual code paths.

---

## Architecture

```
lexer.c3       ~900 LOC   strings, numbers, tokens, regex, template literals
parser.c3      ~3000 LOC  recursive descent, classes, async/await, destructuring,
                           import/export recognition
bytecode.c3    ~500 LOC   opcodes, constants, module table
vm.c3          ~3500 LOC  interpreter, calls, classes, for...of, promises,
                           microtask queue, async state machines
gc.c3          ~800 LOC   mark-sweep, closures, upvalues
builtins.c3    ~2000 LOC  Array, Object, Math, JSON, String, Number,
                           RegExp, Error, Promise, console
modules.c3     ~300 LOC   topological sort, linking
types.c3       ~400 LOC   values, objects, arrays, functions, classes
               --------
               ~11,400 LOC total (est.)
```

---

## Complexity Comparison

| Component | Duktape | TinyDuck |
|---|---|---|
| Property lookup | proto chain + descriptor + proxy + symbol | own prop → class table → done |
| Method call | resolve via chain, check strict, create arguments | direct call + simple this |
| for...of | Symbol.iterator → protocol → generator → iterator | duck-typed .next() loop |
| Class model | prototype chain + constructor + new.target + class | flat class table + constructor |
| Modules | static + dynamic + namespace objects | static only |
| Async | Promises + microtask | same, simpler |
| eval | full parser at runtime | gone |
| strict/sloppy | dual code paths everywhere | always strict-ish |
| **Total** | **~60,000 LOC** | **~11,400 LOC** |

---

## What Breaks

- Anything using `Object.create`, `__proto__`, `prototype`
- `for...in` walks only own properties
- Dynamic `import()` (no runtime module loading)
- Monkey-patching methods across instances (methods are per-class)
- `eval()`, `with`, `arguments` object
- WeakMap/WeakSet/WeakRef
- Generators, iterators, Symbol
- Private fields (`#x`)
- Proxy, Reflect

## What Still Works

- Real class-based OOP with `new`, `super`, getters/setters, `instanceof`
- Async/await for network, timers, device I/O
- `for (var x of arr)` and custom iterables
- Module system for splitting code across files
- Template strings, destructuring, spread, arrow functions
- Full closures and first-class functions
- The subset of JS that real humans actually write
