# Duktape-C3

A port of the [Duktape JavaScript engine](https://duktape.org/) from C to [C3](https://c3-lang.org/).

## Status

**Work in Progress** — A functional JavaScript engine running real workloads.

- **71.8% test262 pass rate** on the targeted subset (21,121 of 29,459 executable tests, session 250); roadmap to 100% in `plans/040-test262-100-percent.md`
- **100/100 Rosetta Code tests** pass
- **Benchmarks competitive** with original Duktape v2.7.0 and QuickJS on most workloads
- **Memory usage on par** with Duktape/QuickJS for light workloads; remaining gap on heavy object/array workloads is tracked in `plans/033-memory-next-steps.md`

### Completed Modules ✅

- **`src/types.c3`** — Tagged value representation (`TVal`), NaN-boxing, heap headers, reference counting
- **`src/heap.c3`** — Heap allocation, string interning, mark-and-sweep GC, GC safe points
- **`src/hstring.c3`** — Interned UTF-8 strings, hashing, iteration, operations
- **`src/hobject.c3`** — JavaScript objects, shapes, property storage, dense arrays, prototypes
- **`src/env.c3`** — Lexical and variable environment records
- **`src/bytecode.c3`** — Instruction formats, opcodes, constant pools, disassembler
- **`src/lexer.c3`** — Full ES2015+ tokenizer (numbers, strings, templates, punctuators, strict mode)
- **`src/compiler/`** — Bytecode compiler: parser, AST, register allocation, scope management, control flow, classes, destructuring
- **`src/vm.c3`** — Register-based bytecode interpreter, call stack, inline caches, exception handling
- **`src/builtins/`** — Built-in objects and functions: Object, Array, Function, String, Number, Boolean, Date, RegExp, JSON, Math, Error, Map, Set, WeakMap, WeakSet, Symbol, Promise, Generator, Iterator, Global
- **`src/re_bindings.c3`** — RegExp engine bindings (libregexp)

### Build

**Runtime:** [C3 v0.8.0+](https://c3-lang.org/) — the only requirement to build and run the engine itself.

**Dev tooling** (only needed for the test262 conformance suite, benchmarks, and `just` recipes):
- [`just`](https://github.com/casey/just) — task runner wrapping the commands below
- Python 3.6+ — orchestrates `scripts/run_test262.py` (parallel workers, RSS sampling, skip list, retry passes); stdlib only, no `pip install`
- `jq` — Makefile parses `project.json` for target sources
- `bash` — shell recipes under `scripts/` and the `justfile`
- `cc` — builds the vendored Duktape v2.7.0 CLI used for benchmark comparisons

```bash
# Default build (NaN-boxing)
c3c build

# Plain JS runner
c3c build duktape_c3
./out/duktape_c3 test/simple.js

# Inspection build (bytecode disassembly, tracing): duktape_c3_debug
c3c build duktape_c3_debug
./out/duktape_c3_debug -c test/simple.js       # disassemble, don't run

# test262 conformance suite
c3c build test262_runner
python3 scripts/run_test262.py                 # full suite
python3 scripts/run_test262.py --phase 2       # single phase (~1 min)

# Benchmark CLI
c3c build duktape_c3
just bench-memory
```

### Useful Commands

See `justfile` for all tasks. Common ones:

| Command | Description |
|---|---|
| `just build` | Build static library |
| `just test262` | Run full test262 suite |
| `just test262-phase 2` | Run a single test262 phase |
| `just bench-memory` | Peak RSS comparison vs Duktape/QuickJS |
| `just bench` | Speed benchmarks vs Duktape/QuickJS |
| `just rosetta` | Rosetta Code tests |

### Build Flags

- `-D NONANBOX` — Disable NaN-boxing; use 16-byte tagged union `TVal`. Useful for 16-bit ESP32 targets.
- `-D NOSHAPECACHE` — Disable the per-object 8-byte shape pointer cache to save memory.

## Project Structure

```
duktape-c3/
├── src/              # Core engine
│   ├── types.c3          # Value representation and heap headers
│   ├── heap.c3           # Memory management and GC
│   ├── hstring.c3        # String interning
│   ├── hobject.c3        # Objects, shapes, properties, arrays
│   ├── env.c3            # Environment records
│   ├── bytecode.c3       # VM instructions
│   ├── lexer.c3          # Tokenizer
│   ├── compiler/         # Parser and bytecode compiler
│   ├── builtins/         # Built-in objects and functions
│   ├── vm.c3             # Bytecode interpreter
│   └── re_bindings.c3    # RegExp bindings
├── cli/              # CLI frontends: duktape_c3 (plain JS) + duktape_c3_debug (inspect) + test262_runner (test262 harness)
├── benchmarks/       # Performance and memory benchmarks
├── test/             # Unit tests and JS test scripts
├── scripts/          # Automation scripts
├── plans/            # Design and optimization plans
├── progress.md       # test262 conformance tracker
└── project.json      # C3 project config
```

## Design Notes

### Tagged Values

Like original Duktape, the default build uses NaN-boxing for efficient value representation:
- 64-bit doubles for numbers
- Special NaN bit patterns for undefined, null, bool, pointer
- 48-bit fast integers and pointer tagging for heap objects

Pass `-D NONANBOX` to use an explicit 16-byte tagged union instead.

### Memory Management

Hybrid approach:
- **Reference counting** for immediate reclamation
- **Mark-and-sweep GC** for cycles and bulk cleanup
- **String interning** with selective interning to avoid concat bloat
- **Fixed-block object pools** for common object sizes

### Bytecode VM

Register-based VM with:
- Fixed 32-bit instructions and multiple operand formats
- Direct constant-pool access
- Inline property/variable caches
- Fused opcodes for hot paths

## License

MIT (following original Duktape license)

## References

- [Duktape](https://duktape.org/) — Original C implementation
- [C3 Language](https://c3-lang.org/) — C3 docs and spec
- [ECMAScript 2015+](https://262.ecma-international.org/) — JavaScript spec
