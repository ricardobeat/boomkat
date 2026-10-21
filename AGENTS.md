# Boomkat

Boomkat is an embeddable JavaScript engine written in C3, targeting correctness,
low memory use, and good performance on low-powered devices.

## Codebase

- `src/`: engine, compiler, VM, builtins, and C embedding API.
- `cli/`: command-line entry points; `include/`: public C headers.
- `project.json`: C3 targets and feature flags; `justfile` and `Makefile`: build
  and test entry points. Run `just list` to discover recipes.
- `docs/architecture.md`: engine design; `docs/engine-scope.md`: supported features.
- `test/`: local regressions; `test/modules/`: ESM fixtures;
  `test262/`: upstream conformance submodule; `scripts/`: test runners and tooling.

## Execution and builds

The CLI evaluates modules by default. Use `--script` for classic scripts, which
are sloppy unless they contain `"use strict"`. Modules and class code are strict.
The C API's `bk_eval` defaults to sloppy scripts; `BK_EVAL_STRICT` selects strict
scripts. Preserve both execution modes when changing parser or runtime behavior.

| Task | Command |
|------|---------|
| Build a target | `just build <target>` |
| Build default targets | `just all` |
| Run a module | `just run <file>` |
| Run a script | `just run-script <file>` |
| Local regressions | `just test-local` |
| Language-feature regressions | `just rosetta` |
| ESM regressions | `just modules` |
| Narrow conformance run | `just test262-dir <path-under-test262/test>` |

Default, slim, and tiny builds omit Intl and Temporal. `boomkat-full-icu` enables
bundled Intl data, Collator, and Temporal. Build overrides are available through
`just build`, for example:

```sh
just build boomkat --intl=small --collator=true --temporal=false
```

Values use NaN-boxing by default. `just build-nonanbox` exercises the alternate
representation. Check C3's stdlib before adding infrastructure; parenthesize
bitwise operations mixed with comparisons because C3's precedence differs from C.

## Testing

Use a focused repro or narrow suite during iteration, then run broader checks
appropriate to the change. Plain-script fixtures live in `test/`; ESM fixtures
live in `test/modules/<name>/main.js` with dependencies alongside them.

Test262 selection is exhaustive. Scope exclusions and their reasons live in
`scripts/run_test262.py`. Enable excluded features after validating parser and
runtime support; preserve deliberate scope exclusions. The runner handles the
strict/sloppy and module variants required by each test's metadata.

```sh
python3 scripts/run_test262.py --single <path-under-test262/test>
python3 scripts/run_test262.py --dir <path-under-test262/test> --log <file>
```

Check `--single`'s suite-exclusion warning before treating a failure as a
regression. Compile errors are expected for parse-negative tests. `--log` writes
per-test verdicts for failure clustering.

TypeScript stripping uses `just ts-conformance [phase-dir]`, with
`tsc --erasableSyntaxOnly` as the compilation oracle. Fetch the corpus with
`python3 scripts/fetch_ts_conformance.py` if it is missing. Runner options and
exclusions are in `scripts/run_ts_conformance.py`.

## Debugging

Minimize failures to a local script and reproduce with `just run-script`.
Use `just build-debug <target>` for an unoptimized build. For bytecode inspection,
run `just build-trace`, then `./out/boomkat_debug -c <file>`.
Test262's `--debug` runs the combined harness under the CLI; `--keep` retains it
for debugger use.

For suspected memory corruption, rebuild the ASAN runner after source changes;
it is excluded from default builds:

```sh
just build-asan
echo test262/test/<path>.js | ./out/test262_runner_asan --worker
```

Debug targets use full debug info because the configured toolchain's Linux
DWARF emitter crashes with `"debug-info": "line-tables"`.

## Plans

Plans live in `plans/` on the `plans/archive` branch. Commit new plans there using
the next numeric prefix. Inspect them from any checkout with
`git ls-tree -r --name-only plans/archive plans` and
`git show plans/archive:plans/<filename>`.
