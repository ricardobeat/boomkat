| Flag | Purpose |
|---|---|
| `NONANBOX` | Disable NaN-boxing and use the 16-byte tagged union `TVal` (`just build-nonanbox`) |
| `NOSHAPECACHE` | Stale README entry; the flag and `just build-noshape` recipe are absent from the current source |
| `HEAP_VERIFY` | Validate GC roots at yield/resume (`just build-verify`) |
| `GC_STRESS` | Force frequent collection for stress runs |
| `ENV_STRICT` | Validate VM environment access for functions compiled with register-local bindings (`boomkat_envstrict` target) |
| `THREADED_DISPATCH` | Enable threaded VM dispatch; enabled in the default CLI target |
| `NO_INSPECT` | Use the smaller console value formatter |
| `INTL` | Enable native Intl services with English formatting |
| `INTL_FULL` | Add bundled formatting locales and full collation data |
| `INTL_COLLATOR` | Enable Collator; requires Intl, uses root data without INTL_FULL |
| `NO_INTL_DATE` | Disable Intl date formatting |
| `TEMPORAL` | Enable Temporal |
| `TRACE_VM` | Enable bytecode disassembly and VM tracing |
| `OP_PROFILE` | Enable opcode profiling |
| `GC_PROFILE` | Enable GC profiling |
| `RELEX_STATS` | Count lexer rescanning |
| `MEMBER_STRICT` | Validate compiler member-expression tracking |
| `GC_VERIFY` | Check incremental GC reachability and ownership |
| `SCAN_POISON` | Poison freed scanned storage and detect stale references |
| `POOL_BYPASS` | Bypass allocation pools so ASan can detect freed-block access |
| `PRINT` | Register global `print` |
| `CONSOLE` | Register `console` |
| `TEST262_HELPERS` | Enable test262 harness helpers |
| `-O0` | Disable optimization for debugging (`just build-debug <target>`) |
| `"sanitize": "address"` | Enable AddressSanitizer in a build target (`just build-asan` builds the test262 runner) |
| `"debug-info": "full"` | Emit full debug information; used by the debug and profiling targets |

## JIT

The standard CLI and C libraries include the SLJIT backend, with native
compilation disabled by default. Use `boomkat --jit file.js` to enable it for
one CLI run. Embedders call `bk_set_jit(runtime, 1)` or
`runtime.set_jit(true)` in C3; passing zero/false disables it again. The setting
is shared by every context in that runtime. Cached native code remains owned
by its compiled function and can be reused after re-enabling JIT.

The `SLJIT` build feature enables backend support on 64-bit NaN-boxing builds
with threaded dispatch. Slim and tiny profiles omit it. CLI `--jit` reports an
error when support is unavailable; the C setter returns `BK_ERR_INVALID`, and
the C3 setter returns false. Disabling JIT succeeds in builds without support.

Custom source embedders enabling `SLJIT` also compile
`vendor/sljit/sljit_src/sljitLir.c` and `src/jit/sljit_shim.c`, with the SLJIT
include directory; the standard library targets show the build settings.

Eligible template functions take one array argument, loop over its indices, append one
untagged template per row, and return the accumulated string. Substitutions read
own data properties from ordinary records with a stable shape and contain
strings or fastints. A native call handles up to 4,096 rows, sixteen template
parts, and 4 MiB of reserved output. Other inputs use the interpreter. Template
interpolation preserves its ordinary verbatim semantics; escaping helpers and
tagged templates run through normal execution.

The loop compiler handles numeric arithmetic, comparisons, bitwise operations,
and indexed loads and stores on dense arrays and fixed, attached, non-shared
Int8/Uint8/Int16/Uint16/Int32/Uint32/Float32/Float64 typed arrays. It also inlines
ASCII `charCodeAt` scans and `Math.imul` with builtin identity guards. Guards
return to the exact bytecode instruction with completed stores and register
updates preserved. Unicode strings, holes, accessors, proxies, coercion, and
unsupported operations use the interpreter.

Each region contains at most 128 instructions and uses at most 64 VM registers,
eight memory sources, and sixteen invariant bindings. Compiled functions cache
up to four regions or input specializations. Generated loop and function code share a
256 KiB cap per runtime; metadata is allocated only for compiled regions. Native
chunks stop at the interpreter's GC and interrupt budgets. No allocation, JS
callback, or collection runs inside a native chunk.

The function compiler combines data-property accesses, primitive field stores,
integer capture updates, arithmetic and forward branches in hot functions of
up to 512 instructions, 64 registers and eight captures. It warms after 64
calls and caches four frequently used registers. Calls and allocations use the
interpreter; eligible continuations resume native execution afterward. Shape,
prototype, capture and value guards preserve completed updates on fallback.
Generators, async functions, direct eval and mapped arguments stay interpreted.
Plans store at most 32 guarded shapes and one mutable capture; repeated short
guard exits disable the affected native entry. Metadata scales with the
function's instruction count and is released with its generated code.

`SLJIT_STATS` enables compilation and hit diagnostics on stderr. It is omitted
from the standard builds. Generated code shares each compiled function's lifetime;
the executable allocator packs functions into shared chunks. Template functions
with custom interrupt callbacks use the interpreter; numeric loops preserve the
ordinary interrupt polling cadence.
