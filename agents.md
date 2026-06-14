# TinyDuck

> **See `tinyduck.md` for the full design spec.**
> **Phase status and progress are tracked in `progress.md`.**
> Check it before starting work to understand where we are and what's next.

A deliberate non-conforming JavaScript engine written in C3. Drops the parts of Duktape that add massive implementation cost but are rarely needed in embedded scripting (game logic, config, device control). Target: ~11K LOC, down from Duktape's ~60K.

**Guiding principle**: everything you need, nothing you don't. If a feature isn't in the "What's In" list in `tinyduck.md`, do not implement it.

## Build & Test

- `just build` — default nanboxing build
- `just test` — run rosetta + unit tests
- See `justfile` for the full command list

## Build Flags

- `-D NONANBOX` — disable NaN-boxing, use the 16-byte tagged union `TVal` instead. Use `just build-nonanbox` / `just test-nonanbox` for 16-bit targets.

## Target Architecture (~11K LOC)

```
src/
  lexer.c3       ~900 LOC   strings, numbers, tokens, regex, template literals
  parser.c3      ~3000 LOC  recursive descent, classes, async/await, destructuring
  bytecode.c3    ~500 LOC   opcodes, constants
  vm.c3          ~3500 LOC  interpreter, calls, classes, for...of, promises
  gc.c3          ~800 LOC   mark-sweep, closures, upvalues
  builtins.c3    ~2000 LOC  Array, Object, Math, JSON, String, Number, Date, RegExp, Error, Promise, console
  modules.c3     ~300 LOC   topological sort, linking
  types.c3       ~400 LOC   values, objects, arrays, functions, classes
```

## When Adding a Feature

1. Confirm it's in the "What's In" list in `tinyduck.md`.
2. For removed features, ensure no leftover code paths remain.
3. Keep an eye on the LOC budget.
4. Add a rosetta test in `test/rosetta/` for any new language feature.
