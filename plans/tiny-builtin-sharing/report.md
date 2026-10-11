# TINY builtin sharing probes

This audit uses `embedded-bytecode-runtime` in isolated source snapshots under
`/tmp/boomkat-builtin-sharing`. The main checkout and the worktree's `src/`
directory are untouched. The three patches beside this report are independent
prototypes, not production changes.

All builds use `c3c build boomkat_tiny`, `O2`, `optsize=tiny`, macOS ARM64,
`--macos-min-version 27.0`, `-Wl,-exported_symbols_list,scripts/no_exports.exp`,
`-Wl,-x`, and `-Wl,-dead_strip`. File sizes are after `xcrun strip`. The shared
baseline measures 612,396 `__text` bytes and 784,080 stripped file bytes.

| Prototype | Shared code | `__text` bytes | `__text` saved | Stripped file bytes | File saved |
| --- | --- | ---: | ---: | ---: | ---: |
| [pad.patch](pad.patch) | `String.prototype.padStart` and `padEnd` | 611,852 | 544 | 784,080 | 0 |
| [find.patch](find.patch) | `Array.prototype.find`, `findLast`, `findIndex`, `findLastIndex` | 611,708 | 688 | 784,080 | 0 |
| [date.patch](date.patch) | Local/UTC `setMilliseconds`, `setSeconds`, `setMinutes`, `setHours` | 610,356 | 2,040 | 784,064 | 16 |

The file-size result is coarse because Mach-O rounds segments. The probes were
built separately; the savings are not established as additive. The Date worker
is marked `@noinline` in the prototype. A production refactor must benchmark
normal Array and Date performance or restrict that call policy to TINY.

Validation: one compiled Module-goal bytecode probe with **10 assertions**
passed on baseline, pad and find runners. It covers both padding directions,
UTF-16 fill, four Array find variants, holes and traversal order. A second
compiled probe produced **120 output rows** on each of baseline and Date
runners, with byte-for-byte identical output. It covers all eight Date setters
with 0-4 arguments, NaN and Infinity arguments, invalid clocks, and `valueOf`
call order. These are focused checks, not a full test262 or performance run.

## Larger retained candidate

`src/builtins/promise.c3` retains four combinators: `builtin_promise_all`
(line 3150), `builtin_promise_allsettled` (3410), `builtin_promise_any` (3621)
and `builtin_promise_race` (3878). Their capability setup, `C.resolve` lookup,
iterator advancement and abrupt-completion paths repeat across roughly 877
source lines. Existing helpers already share `promise_get_iterator`,
`promise_iterator_step`, `promise_iterator_close` and `promise_invoke_then`.
The remaining setup/iteration driver is a high-complexity candidate: live
remaining counts can change under synchronous thenables, and different abrupt
steps require different IteratorClose behavior.

A diagnostic baseline build omitted only the symbol-stripping linker flags;
its `__text` size remained **612,396 bytes**. Address spans between successive
`__text` symbols bound the four combinator bodies at **7,596 bytes total**:
`all` 1,928, `race` 1,464, `allSettled` 1,672 and `any` 2,532. The six
associated element callback symbols span another **2,616 bytes**. These spans
include any alignment and represent retained code size, **not potential
savings**. No Promise sharing prototype was measured.

`HObject.is_proxy()` folds to false under TINY's `NO_PROXY`, so the Proxy
branch in `json_serialize_object` is removed. JSON's retained duplication is
in the replacer-array and ordinary-own-key loops. Sharing their property
Get/check/emit sequence is a smaller, unmeasured opportunity; key snapshots
and getter order must remain intact.
