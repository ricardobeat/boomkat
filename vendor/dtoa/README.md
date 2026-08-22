# vendor/dtoa

Number formatting and parsing, vendored from [QuickJS](https://bellard.org/quickjs/).
`dtoa.c` is the double-to-string and string-to-double implementation the engine
uses for `Number.prototype.toString`, `toFixed`/`toPrecision`/`toExponential`,
and numeric literal parsing; `cutils.c` carries the dynamic-buffer and integer
helpers it depends on.

Upstream: QuickJS `2025-09-13` (bellard/quickjs), MIT licensed — see `LICENSE`.

## Why these files are checked in

They are **build inputs**, named in `project.json` under `c-sources`, so a fresh
clone must be able to compile without fetching anything. That is the line
between this directory and the gitignored `quickjs/`, `duktape/` and corpus
trees: those are comparison engines and test data that `just fetch-engines`
pulls on demand, and nothing in a normal build reads them.

Only the four files the build actually needs are vendored, not the whole
upstream checkout.

## Include-order hazard

`cutils.h` also exists in `vendor/libregexp/`, and the two are NOT the same file
— the libregexp copy is the larger quickjs-ng variant. Both directories sit on
the include path, and `c-include-dirs` lists `vendor/dtoa` before
`vendor/libregexp` so that `dtoa.c` and `cutils.c` resolve `#include "cutils.h"`
to the copy beside them. Reordering that list, or adding another directory that
carries a `cutils.h`, changes which header these translation units see.

## Updating

Copy the four files from a newer upstream checkout and record the version above.
Check `cutils.h` against `vendor/libregexp/cutils.h` afterwards: the two drifting
further apart is fine, but the include order above must still put each source
next to the header it was written against.
