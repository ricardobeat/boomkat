# Linux CI

Builds the engine, runs the test suite, and validates the `bk_` embedding ABI's
linking and language bindings on Linux, inside a container on a macOS host.

Uses **Apple's `container` CLI**, not Docker.

## Running it

```sh
container system start          # once per boot
make linux-ci-image             # build the image (~15 min: c3c is built from source)
make linux-ci                   # run every phase
```

Individual phases:

```sh
make linux-ci PHASES="build tests"
make linux-ci PHASES=link
make linux-ci-shell             # interactive shell in the same environment
```

Phases: `build`, `tests`, `test262`, `libs`, `smoke`, `link`, `initarray`,
`install`, `bindings`. The runner exits non-zero if any phase fails.

## What it checks

| Phase | Checks |
|---|---|
| `build` | `c3c build boomkat` produces a working binary |
| `tests` | `bash test/run_local.sh`, the whole engine suite |
| `test262` | `bash scripts/test262_gate.sh`, the full test262 suite with a zero-fail gate (needs the `test262/` submodule; ~15 min) |
| `libs` | `make lib` and `make shared` produce `boomkat.a` and `boomkat.so` |
| `smoke` | `make smoke` prints 42 (links the **static** archive) |
| `link` | `ldd` has no unresolved deps; `nm -D` exports all 12 `bk_` symbols; the static archive links from plain `cc`; whether compiler-rt is required |
| `initarray` | Static archive linked by **Zig** and by **rustc** — the ELF counterpart of the macOS init hazard |
| `install` | `make install PREFIX=…`, then static and shared compiles against the prefix, and that the rpath is load-bearing |
| `bindings` | C99 (static + shared), Python, Ruby, Zig, Rust, C3 |

## Architecture: arm64, not amd64

The image is **linux/arm64**, native on Apple Silicon.

amd64 was tried first, because c3c 0.8.3 ships an official x86-64 Linux binary
and no arm64 one. It does not work. Under `container`'s amd64 emulation, c3c's
`posix_spawn` of the C compiler fails before `exec`, so every C-source compile
and every link dies with:

```
Failed to compile c sources using command 'cc -I quickjs -I libregexp -fPIE -c -O2 libregexp/libregexp.c -o build/obj/linux-x64/tmp_c_compile/libregexp.o'.
```

even though c3c has already written all its `.o` files and the identical command
succeeds when run by hand in the same shell. A `cc` shim confirmed the compiler
is never invoked at all (0 shim invocations). Emulated `posix_spawn` also
reports `errno 38` (ENOSYS) where native arm64 reports the usual value. Both the
static and the dynamic c3c tarballs fail identically, so it is the emulation,
not the binary.

Consequently the image builds **c3c 0.8.3 from source** against the distro's
LLVM 19. That matches the host's c3c version and git hash
(`9516a396c25782cd5616572c9bc3d77e13919218`); the LLVM differs (19.1.7 in the
container, 22.1.8 on the host).

## Resources

`make linux-ci` passes `--memory 8g --cpus 6`. The 2 GB default is not enough:
`zig build` is OOM-killed and reports only `process terminated with signal
KILL`. The image build needs a larger *builder*, which is separate:

```sh
container builder stop
container builder start --cpus 6 --memory 12g
```

Without this the `apt-get install` of the LLVM dev packages dies with
`cannot allocate memory`.

## C dependencies

Nothing outside the worktree has to be mounted. Every C source the build
compiles is checked in: `libregexp/` and `vendor/dtoa/`.

`quickjs/` and `duktape/` are comparison engines, fetched on demand by
`just fetch-engines` and built from source (`just build-quickjs` runs
`make -C quickjs qjs`). The benchmarks and the differential library checks run
them as an oracle, but no CI phase here does, so the container never needs
them.

## Cross-platform build artifacts

The working tree is bind-mounted from macOS, so `out/`, `bindings/rust/target/`,
`bindings/zig/.zig-cache/` and `bindings/c/out/example` may hold Mach-O files.
The `bindings` phase clears the binding caches, but **`out/` is not cleared** —
run `rm -rf out build` when switching platforms, or the suite will validate a
stale macOS archive and report confusing failures. A macOS `boomkat.a`
contains no `bk_`-prefixed ELF symbols, so it surfaces as "undefined reference
to `bk_open`" from Rust rather than as an obvious platform error.
