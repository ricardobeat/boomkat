# Linux/amd64 CI

Builds the engine and runs the local test suite and the test262 zero-fail gate
on **linux/amd64**, inside an emulated container on an Apple Silicon host. This
is the arch GitHub Actions runs, so it reproduces x86-64-specific failures that
the native arm64 image in `scripts/linux/arm64/` cannot (dtoa rounding, 80-bit long double,
and other places the two architectures differ).

## Running it

```sh
podman machine start            # once; needs a few GB of RAM
make linux-x86-ci-image         # build the image (fast: prebuilt c3c, no source build)
make linux-x86-ci               # build + tests + test262
```

Individual phases and an interactive shell:

```sh
make linux-x86-ci PHASES="build tests"
make linux-x86-ci PHASES=test262
make linux-x86-ci-shell
```

Phases: `build`, `tests`, `test262`. The runner exits non-zero if any fails.

## Engine: podman, not Apple's `container`

The container engine must run a real Linux VM with working binfmt so the
prebuilt x86-64 c3c can compile and link under emulation. Podman (the default)
and Docker both do. Set `X86_ENGINE=docker` to use Docker instead:

```sh
make linux-x86-ci X86_ENGINE=docker
```

Apple's `container` CLI is **not** usable here: under its amd64 emulation c3c's
`posix_spawn` of the C compiler fails before exec (errno 38, ENOSYS), so every
link dies even though the compile commands succeed by hand. That is the whole
reason `scripts/linux/arm64/` went arm64 and builds c3c from source. A real Linux VM does
not have that problem, so this image just downloads the x86-64 binary.

## Emulation is slow

Every instruction is emulated, so the full run (especially test262) takes far
longer than native. Give the podman machine several cores and a few GB of RAM:

```sh
podman machine set --cpus 6 --memory 8192
podman machine stop && podman machine start
```

## Stale artifacts

The working tree is bind-mounted from macOS, so `out/` and the c3c build cache
may hold Mach-O files. The `build` phase runs `rm -rf out build` first, so a
stale macOS archive does not fail the x86-64 build with a confusing error.
