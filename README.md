# TinyDuck

A deliberate non-conforming JavaScript engine written in [C3](https://c3-lang.org/). Drops the parts of Duktape that add massive implementation cost but are rarely needed in embedded scripting (game logic, config, device control). Target: ~11K LOC, down from Duktape's ~60K.

> **See `tinyduck.md` for the full design spec** (what's in, what's out, complexity comparison, architecture).
> **See `AGENTS.md` for working guidance.**
> **See `progress.md` for current phase status.**

## Quick Start

```bash
just build          # build the tinyduck engine
just build-test     # build the test runner (with JS execution)
just test           # run the rosetta suite
just run file=...   # run a single JS file
```

## Status

Rebooting from a Duktape C3 port. See `progress.md`.

- **Phase 0 (cleanup)**: done — test262, Duktape-comparison infra, debug/temp tests, old reports all removed.
- **Phase 1 (rosetta)**: done — 4 irredeemable tests deleted, 7 rewritten to fit the supported subset.
- **Phase 2 (engine cuts)**: in progress — `with` removed (parser rejects, VM/bytecode/env cleaned up, build green). Next: `import.meta` + dynamic `import()`, `WeakMap`/`WeakSet`/`WeakRef`, `Symbol`, `eval`, `arguments`, generators, `Object.defineProperty`, strict/sloppy, prototypes.

## License

MIT.
