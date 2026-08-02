# Building a C99 program against the installed jse engine.
#
#   make                 # static link (the default; one self-contained binary)
#   make shared          # shared link, resolved at run time via rpath
#   make run             # build and run the static binary
#   make run-shared      # build and run the shared binary
#   make run-host-fn     # build and run the host-function example
#   make run-two-runtimes # build and run the two-runtime example
#   make clean
#
# PREFIX points at the tree `make install` produced in the engine repo:
#
#   make -C ../.. install PREFIX=/usr/local
#   make PREFIX=/usr/local run
#
# To build straight from the engine's out/ directory without installing:
#
#   make JSE_INCDIR=../../include JSE_LIBDIR=../../out JSE_STATIC_LIB=../../out/jse_static.a run

PREFIX ?= /usr/local

JSE_INCDIR ?= $(PREFIX)/include
JSE_LIBDIR ?= $(PREFIX)/lib

# `make install` writes the static archive as libjse.a; the engine's own out/
# directory calls it jse_static.a. Override JSE_STATIC_LIB for the latter.
JSE_STATIC_LIB ?= $(JSE_LIBDIR)/libjse.a

CC      ?= cc
CFLAGS  ?= -std=c99 -Wall -Wextra -pedantic -O2
CPPFLAGS = -I$(JSE_INCDIR)

# The shared library suffix and the libraries a C consumer must name.
# macOS gets libm and libdl from libSystem; ELF platforms need them spelled out.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  SHLIB_EXT := dylib
  LDLIBS_EXTRA :=
else
  SHLIB_EXT := so
  LDLIBS_EXTRA := -lm -ldl
  # The engine's BigInt path needs __muloti4, which lives in LLVM's compiler-rt
  # and not in libgcc, so a GCC-driven static link of the archive fails without
  # it. Only the static link is affected: the shared library resolved it at its
  # own link. Override JSE_RT_LIB for a different compiler-rt location.
  JSE_RT_LIB ?= $(firstword $(wildcard \
      /usr/lib/llvm-*/lib/clang/*/lib/linux/libclang_rt.builtins-$(shell uname -m).a))
  LDLIBS_STATIC_EXTRA := $(JSE_RT_LIB)
endif

SRCS := main.c jse_util.c

# The host-function example: C callbacks registered as JS globals.
HOST_FN_SRCS := host_fn.c jse_util.c

# The two-runtime example: two independent runtimes open at once.
TWO_RT_SRCS := two_runtimes.c jse_util.c

.PHONY: all static shared host-fn two-runtimes run run-shared run-host-fn \
        run-two-runtimes clean
all: static host-fn two-runtimes
static: jse-example
shared: jse-example-shared
host-fn: jse-host-fn
two-runtimes: jse-two-runtimes

# --- static link -------------------------------------------------------------
# The archive already contains the vendored C (libregexp, cutils, dtoa), so it
# must not be compiled or linked separately -- doing so gives duplicate symbols.
jse-example: $(SRCS) jse_util.h
	$(CC) $(CFLAGS) $(CPPFLAGS) $(SRCS) $(JSE_STATIC_LIB) $(LDLIBS_EXTRA) \
	    $(LDLIBS_STATIC_EXTRA) -o $@

# --- shared link -------------------------------------------------------------
# The dylib carries an @rpath install name, so the consumer supplies the rpath.
# Without it the loader cannot find libjse at startup.
jse-example-shared: $(SRCS) jse_util.h
	$(CC) $(CFLAGS) $(CPPFLAGS) $(SRCS) \
	    -L$(JSE_LIBDIR) -ljse -Wl,-rpath,$(abspath $(JSE_LIBDIR)) \
	    $(LDLIBS_EXTRA) -o $@

# --- host functions ----------------------------------------------------------
# Statically linked like jse-example; nothing extra is needed to expose C
# callbacks to JS, since jse_register_fn is part of the same ABI.
jse-host-fn: $(HOST_FN_SRCS) jse_util.h
	$(CC) $(CFLAGS) $(CPPFLAGS) $(HOST_FN_SRCS) $(JSE_STATIC_LIB) $(LDLIBS_EXTRA) \
	    $(LDLIBS_STATIC_EXTRA) -o $@

# --- two runtimes ------------------------------------------------------------
# Statically linked like the others; opening more than one runtime needs no
# special build, since the engine keeps no process-global state.
jse-two-runtimes: $(TWO_RT_SRCS) jse_util.h
	$(CC) $(CFLAGS) $(CPPFLAGS) $(TWO_RT_SRCS) $(JSE_STATIC_LIB) $(LDLIBS_EXTRA) \
	    $(LDLIBS_STATIC_EXTRA) -o $@

run: jse-example
	./jse-example

run-shared: jse-example-shared
	./jse-example-shared

run-host-fn: jse-host-fn
	./jse-host-fn

run-two-runtimes: jse-two-runtimes
	./jse-two-runtimes

clean:
	rm -f jse-example jse-example-shared jse-host-fn jse-two-runtimes
