# Build and run the language-binding examples.
#
# C recipes (bindings/c/) drive cc directly so the recipe owns every
# flag and the build does not depend on a parallel Makefile in the example
# directory. The vendored C (libregexp, cutils, dtoa) is already inside the
# engine archive and shared library, so the example sources must not compile
# those files again -- doing so gives duplicate symbols at link time.
#
# The Ruby recipe (bindings/ruby/examples/) needs only the shared library plus
# any Ruby >= 2.6 (the macOS system ruby is 2.6).
#
# Path resolution: the recipes anchor sources at the cwd `just` was invoked
# from, with no expectation of an install tree. By default they read the
# header / libraries from the engine's own out/ directory, so `just
# example-c-shared` works straight after `make shared`. To link against an
# installed tree instead, set PREFIX (defaults to `/usr/local`), BK_INCDIR,
# BK_LIBDIR, or BK_STATIC_LIB -- whichever you want to override.
#
# Each binding's example builds into its own ./out/ subdirectory (gitignored
# by name), so the four binaries never share a single noisy output folder.

ROOT_DIR := `pwd`

# Default to the engine's own out/ tree; only fall back to /usr/local when the
# caller sets PREFIX.
BK_INCDIR  := env_var_or_default("BK_INCDIR", ROOT_DIR + "/include")
BK_LIBDIR  := env_var_or_default("BK_LIBDIR", ROOT_DIR + "/out")
BK_STATIC  := env_var_or_default("BK_STATIC_LIB", BK_LIBDIR + "/boomkat.a")
BK_SHARED  := env_var_or_default("BK_SHARED_LIB", BK_LIBDIR + "/boomkat." + shared_ext)

# macOS gets libm and libdl from libSystem; ELF platforms need them spelled out.
# The engine's BigInt path needs __muloti4 from LLVM's compiler-rt, which lives
# outside libgcc. Only the static link is affected; the shared library already
# resolved it at its own link. Probe the platform-specific path on ELF.
[private]
clang-rt-archive:
    @firstword /usr/lib/llvm-*/lib/clang/*/lib/linux/libclang_rt.builtins-`uname -m`.a 2>/dev/null || true

clang_rt := if os() == "macos" { "" } else { `just clang-rt-archive` }
ldlibs_static := if os() == "macos" { "" } else { if clang_rt == "" { "-lm -ldl" } else { "-lm -ldl " + clang_rt } }

ldlibs_shared := if os() == "macos" { "" } else { "-lm -ldl" }

shared_ext := if os() == "macos" { "dylib" } else { "so" }

# Make the rpath absolute, because just does not chdir into the directory the
# way `make -C bindings/c` would.
shared_rpath := absolute_path(BK_LIBDIR)

# === C embedding examples ===================================================

[doc("Build the static-link C example (links against libbk.a)")]
example-c-static:
    mkdir -p {{ROOT_DIR}}/bindings/c/out
    cc -std=c99 -Wall -Wextra -pedantic -I{{BK_INCDIR}} \
        {{ROOT_DIR}}/bindings/c/main.c {{BK_STATIC}} {{ldlibs_static}} \
        -o {{ROOT_DIR}}/bindings/c/out/example
    {{ROOT_DIR}}/bindings/c/out/example

[doc("Build the shared-link C example (links against boomkat.dylib/.so)")]
example-c-shared:
    mkdir -p {{ROOT_DIR}}/bindings/c/out
    cc -std=c99 -Wall -Wextra -pedantic -I{{BK_INCDIR}} \
        {{ROOT_DIR}}/bindings/c/main.c \
        {{BK_SHARED}} -Wl,-rpath,{{shared_rpath}} {{ldlibs_shared}} \
        -o {{ROOT_DIR}}/bindings/c/out/example-shared
    {{ROOT_DIR}}/bindings/c/out/example-shared

[doc("Build the multi-runtime C examples (host callbacks + two runtimes)")]
example-c-multiple: example-c-static example-c-shared
    cc -std=c99 -Wall -Wextra -pedantic -I{{BK_INCDIR}} \
        {{ROOT_DIR}}/bindings/c/host_fn.c {{BK_STATIC}} {{ldlibs_static}} \
        -o {{ROOT_DIR}}/bindings/c/out/host-fn
    {{ROOT_DIR}}/bindings/c/out/host-fn
    cc -std=c99 -Wall -Wextra -pedantic -I{{BK_INCDIR}} \
        {{ROOT_DIR}}/bindings/c/two_runtimes.c {{BK_STATIC}} {{ldlibs_static}} \
        -o {{ROOT_DIR}}/bindings/c/out/two-runtimes
    {{ROOT_DIR}}/bindings/c/out/two-runtimes

# === Ruby binding example ===================================================

[doc("Run the Ruby fiddle embedding example")]
example-ruby:
    @command -v ruby >/dev/null || { echo "ruby not installed" >&2; exit 1; }
    ruby {{ROOT_DIR}}/bindings/ruby/examples/example.rb

# === Cleanup ================================================================

[doc("Remove built example binaries")]
example-clean:
    rm -rf {{ROOT_DIR}}/bindings/c/out