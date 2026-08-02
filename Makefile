# Incremental wrapper around `c3c build` — c3c always fully recompiles and
# relinks even when nothing changed (~19s), so gate each target on mtimes
# and skip the c3c invocation entirely when the binary is already newer
# than every source file that feeds it.
#
# Prerequisites are pulled from project.json at execute time (c-sources +
# the target's own "sources", expanding directory entries to their .c3
# files) so this file never drifts from what c3c itself actually builds.

target_sources = $(shell jq -r '.["c-sources"][]' project.json) \
                 $(shell jq -r '.targets.$(1).sources[]' project.json | while read -r s; do \
                     if [ -d "$$s" ]; then find "$$s" -name '*.c3'; else echo "$$s"; fi; \
                 done)

# ---- C embedding ABI (include/jse.h + src/capi.c3) --------------------------
# Shared-library suffix and the link flags a C consumer needs. macOS resolves
# libm/libdl from libSystem; ELF platforms need them named explicitly.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  SHLIB_EXT := dylib
  JSE_LDLIBS :=
else
  SHLIB_EXT := so
  JSE_LDLIBS := -lm -ldl
endif

# The BigInt path multiplies int128 values, which LLVM lowers to the
# overflow-checked builtin __muloti4. Apple's libSystem carries it, but GNU
# libgcc does not -- it lives only in LLVM's compiler-rt -- so on Linux the
# link fails with "undefined reference to `__muloti4'" unless that archive is
# named explicitly. This bites twice: once when c3c links the engine (c3c's -z
# forwards the path to the linker) and again when a *consumer* links the static
# archive, since the archive carries the undefined reference outward. It does
# not affect the shared library, which resolves it at its own link.
# Override C3C_RT_LIB to point at a different compiler-rt build.
ifneq ($(UNAME_S),Darwin)
  C3C_RT_LIB ?= $(firstword $(wildcard \
      /usr/lib/llvm-*/lib/clang/*/lib/linux/libclang_rt.builtins-$(shell uname -m).a))
  ifneq ($(C3C_RT_LIB),)
    C3C_LDFLAGS := -z $(C3C_RT_LIB)
    JSE_LDLIBS += $(C3C_RT_LIB)
  endif
endif

# C3C_LDFLAGS trails the target name: c3c rejects -z before it.
C3C ?= c3c

# Every target compiles the c-sources into <build-dir>/obj/<arch>/tmp_c_compile
# and deletes them once the link is done. With the default build dir that path
# is shared, so two builds in the same checkout race: one removes the objects
# the other is about to link, and the link fails with "no such file or
# directory: .../libregexp.o". Each recipe therefore gets its own build dir.
#
# The directory is created inside the recipe's shell rather than by a $(shell)
# assignment: the latter runs once at parse time, on every make invocation,
# including the no-op runs the mtime gate above is there to make free.
#
# --build-dir has to trail the target name for the same reason C3C_LDFLAGS does,
# so recipes read `$(C3C_BUILD) <target> $(C3C_BUILDFLAGS) $(C3C_LDFLAGS)`.
C3C_BUILD = d=$$(mktemp -d "$${TMPDIR:-/tmp}/duk-c3-build.XXXXXX"); trap 'rm -rf "$$d"' EXIT; $(C3C) build
C3C_BUILDFLAGS = --build-dir "$$d"

PREFIX ?= /usr/local

.PHONY: all lib lib-full test262_runner test262_runner_asan duktape_c3 duktape_c3_debug duktape_c3_gc_stress clean \
        shared jse jse-stress example-c example-ruby smoke install

all: lib-full test262_runner duktape_c3

# `lib` builds the jse_* embedding archive (see the C ABI section below).
# `lib-full` is the original unoptimised whole-engine archive.
lib-full: out/lib.a
test262_runner: out/test262_runner
# Deliberately not in `all`: the ASAN build is -O0 + sanitizer instrumentation
# and would slow every default build. Build it explicitly when chasing a
# lifetime bug, otherwise a stale binary reports clean results for code it
# does not contain.
test262_runner_asan: out/test262_runner_asan
duktape_c3: out/duktape_c3
duktape_c3_debug: out/duktape_c3_debug
# Also deliberately out of `all`: GC_STRESS collects at every allocation, which
# makes the binary orders of magnitude slower. It is the only build that turns a
# missed GC root into a deterministic failure instead of a rare field crash.
duktape_c3_gc_stress: out/duktape_c3_gc_stress

out/lib.a: project.json $(call target_sources,lib)
	$(C3C_BUILD) lib $(C3C_BUILDFLAGS) $(C3C_LDFLAGS)

out/test262_runner: project.json $(call target_sources,test262_runner)
	$(C3C_BUILD) test262_runner $(C3C_BUILDFLAGS) $(C3C_LDFLAGS)

out/test262_runner_asan: project.json $(call target_sources,test262_runner_asan)
	$(C3C_BUILD) test262_runner_asan $(C3C_BUILDFLAGS) $(C3C_LDFLAGS)

out/duktape_c3: project.json $(call target_sources,duktape_c3)
	$(C3C_BUILD) duktape_c3 $(C3C_BUILDFLAGS) $(C3C_LDFLAGS)

out/duktape_c3_debug: project.json $(call target_sources,duktape_c3_debug)
	$(C3C_BUILD) duktape_c3_debug $(C3C_BUILDFLAGS) $(C3C_LDFLAGS)

out/duktape_c3_gc_stress: project.json $(call target_sources,duktape_c3_gc_stress)
	$(C3C_BUILD) duktape_c3_gc_stress $(C3C_BUILDFLAGS) $(C3C_LDFLAGS)

# ---- C embedding ABI targets ------------------------------------------------

# Static archive carrying the jse_* ABI. Built with the same flags as the
# shipped executables so an embedder gets the engine the test suite exercised.
lib: out/jse_static.a
out/jse_static.a: project.json include/jse.h $(call target_sources,jse_static)
	$(C3C_BUILD) jse_static $(C3C_BUILDFLAGS) $(C3C_LDFLAGS)

# Shared library. c3c stamps a *relative* install name ("out/jse.dylib"), so a
# consumer launched from any other directory fails to resolve it in dyld; the
# install_name_tool step rewrites it to @rpath. The libjse.$(SHLIB_EXT) copy
# exists so `-ljse` and ctypes/fiddle find_library lookups both work.
shared jse: out/libjse.$(SHLIB_EXT)
out/libjse.$(SHLIB_EXT): project.json include/jse.h $(call target_sources,jse)
	$(C3C_BUILD) jse $(C3C_BUILDFLAGS) $(C3C_LDFLAGS)
ifeq ($(UNAME_S),Darwin)
	install_name_tool -id "@rpath/libjse.dylib" out/jse.dylib
endif
	cp out/jse.$(SHLIB_EXT) out/libjse.$(SHLIB_EXT)

# GC_STRESS + ASan shared build: collects at every allocation, which is what
# turns a missing GC root in the slot registry into a deterministic failure.
jse-stress:
	$(C3C_BUILD) jse_stress $(C3C_BUILDFLAGS) $(C3C_LDFLAGS)

# Smoke test: links the STATIC archive, so it validates the archive path rather
# than only the dylib. Vendored C (libregexp, cutils, dtoa) is already inside
# the archive -- compiling it again here would produce duplicate symbols.
out/smoke: examples/c/smoke.c include/jse.h out/jse_static.a
	cc -std=c99 -Wall -Wextra -pedantic -Iinclude examples/c/smoke.c \
	   out/jse_static.a $(JSE_LDLIBS) -o out/smoke

smoke: out/smoke
	./out/smoke

# Host-function ABI tests: registration, argument access, throwing, and
# calling JS from a callback, all through include/jse.h only.
out/host_fn_abi: test/capi/host_fn_abi.c include/jse.h out/jse_static.a
	cc -std=c99 -Wall -Wextra -pedantic -Iinclude test/capi/host_fn_abi.c \
	   out/jse_static.a $(JSE_LDLIBS) -o out/host_fn_abi

.PHONY: test-host-abi
test-host-abi: out/host_fn_abi
	./out/host_fn_abi

# Value-registry GC tests under GC_STRESS + ASan: a collection at every
# allocation, so a registry the mark phase does not walk fails deterministically
# instead of rarely.
.PHONY: test-registry-gc
test-registry-gc:
	$(C3C_BUILD) value_registry_gc_stress $(C3C_LDFLAGS)
	./out/value_registry_gc_stress

# Multiple runtimes in one process: independent globals, objects, shapes and
# interned strings; a host function in one calling into another; and handles
# refused across runtimes. None of this could run before the process-global heap
# pointer was removed.
out/two_runtimes: test/capi/two_runtimes.c include/jse.h out/jse_static.a
	cc -std=c99 -Wall -Wextra -pedantic -Iinclude test/capi/two_runtimes.c \
	   out/jse_static.a $(JSE_LDLIBS) -o out/two_runtimes

.PHONY: test-two-runtimes
test-two-runtimes: out/two_runtimes
	./out/two_runtimes

# Heap teardown under GC_STRESS + ASan. Heap.destroy frees every object
# directly and sets tearing_down so object teardown skips its decref pass;
# decrefing there would touch the string table the sweep is walking. The JS
# suites run one destroy per process, so this drives 40 full heap lifecycles.
.PHONY: test-runtime-cycles
test-runtime-cycles: jse-stress
	cc -std=c99 -Wall -Wextra -pedantic -Iinclude test/capi/runtime_cycles.c \
	   out/jse_stress.$(SHLIB_EXT) -Wl,-rpath,$(CURDIR)/out $(JSE_LDLIBS) \
	   -o out/runtime_cycles
	ASAN_OPTIONS=detect_leaks=0 ./out/runtime_cycles

# Larger example, linked against the shared library via rpath.
out/hello: examples/c/hello.c include/jse.h out/libjse.$(SHLIB_EXT)
	cc -std=c99 -Wall -Wextra -pedantic -Iinclude examples/c/hello.c \
	   out/libjse.$(SHLIB_EXT) -Wl,-rpath,$(CURDIR)/out $(JSE_LDLIBS) -o out/hello

example-c: out/hello
	./out/hello

# Ruby binding example. Pure stdlib fiddle -- nothing to compile, so this only
# needs the shared library and any ruby >= 2.6 (the macOS system ruby is 2.6).
example-ruby: out/libjse.$(SHLIB_EXT)
	ruby bindings/ruby/examples/example.rb
	ruby bindings/ruby/examples/two_runtimes.rb

# make install PREFIX=/usr/local -- header + both libraries.
# The dylib keeps its @rpath install name rather than being restamped with an
# absolute one: install_name_tool cannot grow the load command past the header
# padding c3c emitted, so a long PREFIX would fail the install. Consumers link
# with -Wl,-rpath,$(PREFIX)/lib; ctypes/fiddle load the path directly.
install: out/jse_static.a out/libjse.$(SHLIB_EXT)
	install -d $(DESTDIR)$(PREFIX)/include $(DESTDIR)$(PREFIX)/lib
	install -m 644 include/jse.h $(DESTDIR)$(PREFIX)/include/jse.h
	install -m 644 out/jse_static.a $(DESTDIR)$(PREFIX)/lib/libjse.a
	install -m 755 out/libjse.$(SHLIB_EXT) $(DESTDIR)$(PREFIX)/lib/libjse.$(SHLIB_EXT)

# ---- Linux CI ---------------------------------------------------------------
# Build the Linux image and run the whole build/test/link-validation suite in
# it. Uses Apple's `container` CLI (not docker). See ci/linux/README.md.
#
# quickjs/ is gitignored and is usually a symlink into another checkout. It is
# bind-mounted separately because the container needs real files there, and the
# symlink must be out of the way first: mounting onto an existing symlink fails
# with "errno 17: failed to create directory 'quickjs'". The symlink is removed
# before the run and restored after, so host builds keep working either way.
LINUX_IMAGE ?= jse-linux-ci
LINUX_ARCH  ?= arm64
QUICKJS_DIR ?= $(realpath quickjs)

# The default 2 GB container is not enough: `zig build` gets OOM-killed
# (SIGKILL, reported only as "process terminated with signal KILL") and the
# c3c/LLVM builds are slow. Raise both explicitly.
LINUX_MEMORY ?= 8g
LINUX_CPUS   ?= 6

CONTAINER_RUN = container run --rm --arch $(LINUX_ARCH) \
	    --memory $(LINUX_MEMORY) --cpus $(LINUX_CPUS) \
	    -v "$(CURDIR):/work" -v "$(QUICKJS_DIR):/work/quickjs" $(LINUX_IMAGE)

# Drop a quickjs symlink for the duration of the run, then put it back.
define with_quickjs_unlinked
	@if [ -L quickjs ]; then mv quickjs .quickjs.link; fi
	$(1); rc=$$?; \
	if [ -e .quickjs.link ]; then rmdir quickjs 2>/dev/null || true; mv .quickjs.link quickjs; fi; \
	exit $$rc
endef

.PHONY: linux-ci linux-ci-image linux-ci-shell

linux-ci-image:
	container build --arch $(LINUX_ARCH) -t $(LINUX_IMAGE) -f ci/linux/Dockerfile ci/linux

linux-ci:
	$(call with_quickjs_unlinked,$(CONTAINER_RUN) bash ci/linux/run.sh $(PHASES))

# Interactive shell in the same environment, for debugging a failing phase.
linux-ci-shell:
	$(call with_quickjs_unlinked,container run --rm -it --arch $(LINUX_ARCH) \
	    --memory $(LINUX_MEMORY) --cpus $(LINUX_CPUS) \
	    -v "$(CURDIR):/work" -v "$(QUICKJS_DIR):/work/quickjs" $(LINUX_IMAGE) bash)

clean:
	c3c clean
	@rm -rf "$${TMPDIR:-/tmp}"/duk-c3-build.*
