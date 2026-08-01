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
	c3c build lib

out/test262_runner: project.json $(call target_sources,test262_runner)
	c3c build test262_runner

out/test262_runner_asan: project.json $(call target_sources,test262_runner_asan)
	c3c build test262_runner_asan

out/duktape_c3: project.json $(call target_sources,duktape_c3)
	c3c build duktape_c3

out/duktape_c3_debug: project.json $(call target_sources,duktape_c3_debug)
	c3c build duktape_c3_debug

out/duktape_c3_gc_stress: project.json $(call target_sources,duktape_c3_gc_stress)
	c3c build duktape_c3_gc_stress

# ---- C embedding ABI targets ------------------------------------------------

# Static archive carrying the jse_* ABI. Built with the same flags as the
# shipped executables so an embedder gets the engine the test suite exercised.
lib: out/jse_static.a
out/jse_static.a: project.json include/jse.h $(call target_sources,jse_static)
	c3c build jse_static

# Shared library. c3c stamps a *relative* install name ("out/jse.dylib"), so a
# consumer launched from any other directory fails to resolve it in dyld; the
# install_name_tool step rewrites it to @rpath. The libjse.$(SHLIB_EXT) copy
# exists so `-ljse` and ctypes/fiddle find_library lookups both work.
shared jse: out/libjse.$(SHLIB_EXT)
out/libjse.$(SHLIB_EXT): project.json include/jse.h $(call target_sources,jse)
	c3c build jse
ifeq ($(UNAME_S),Darwin)
	install_name_tool -id "@rpath/libjse.dylib" out/jse.dylib
endif
	cp out/jse.$(SHLIB_EXT) out/libjse.$(SHLIB_EXT)

# GC_STRESS + ASan shared build: collects at every allocation, which is what
# turns a missing GC root in the slot registry into a deterministic failure.
jse-stress:
	c3c build jse_stress

# Smoke test: links the STATIC archive, so it validates the archive path rather
# than only the dylib. Vendored C (libregexp, cutils, dtoa) is already inside
# the archive -- compiling it again here would produce duplicate symbols.
out/smoke: examples/c/smoke.c include/jse.h out/jse_static.a
	cc -std=c99 -Wall -Wextra -pedantic -Iinclude examples/c/smoke.c \
	   out/jse_static.a $(JSE_LDLIBS) -o out/smoke

smoke: out/smoke
	./out/smoke

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

clean:
	c3c clean
