# Building a C99 program against the installed jse engine.
#
#   make                 # static link (the default; one self-contained binary)
#   make shared          # shared link, resolved at run time via rpath
#   make run             # build and run the static binary
#   make run-shared      # build and run the shared binary
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
endif

SRCS := main.c jse_util.c

.PHONY: all static shared run run-shared clean
all: static
static: jse-example
shared: jse-example-shared

# --- static link -------------------------------------------------------------
# The archive already contains the vendored C (libregexp, cutils, dtoa), so it
# must not be compiled or linked separately -- doing so gives duplicate symbols.
jse-example: $(SRCS) jse_util.h
	$(CC) $(CFLAGS) $(CPPFLAGS) $(SRCS) $(JSE_STATIC_LIB) $(LDLIBS_EXTRA) -o $@

# --- shared link -------------------------------------------------------------
# The dylib carries an @rpath install name, so the consumer supplies the rpath.
# Without it the loader cannot find libjse at startup.
jse-example-shared: $(SRCS) jse_util.h
	$(CC) $(CFLAGS) $(CPPFLAGS) $(SRCS) \
	    -L$(JSE_LIBDIR) -ljse -Wl,-rpath,$(abspath $(JSE_LIBDIR)) \
	    $(LDLIBS_EXTRA) -o $@

run: jse-example
	./jse-example

run-shared: jse-example-shared
	./jse-example-shared

clean:
	rm -f jse-example jse-example-shared
