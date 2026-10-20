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

## Template JIT

`just build-jit` builds `out/boomkat_jit` with the same size optimization and
language features as `boomkat`, plus the vendored SLJIT backend. The `SLJIT`
feature enables native compilation of hot template-rendering loops on 64-bit
NaN-boxing builds. The default CLI and library builds omit it.

Eligible functions take one array argument, loop over its indices, append one
untagged template per row, and return the accumulated string. Substitutions read
own data properties from ordinary records with a stable shape and contain
strings or fastints. A native call handles up to 4,096 rows, sixteen template
parts, and 4 MiB of reserved output. Other inputs use the interpreter. Template
interpolation preserves its ordinary verbatim semantics; escaping helpers and
tagged templates run through normal execution.

`SLJIT_STATS` enables compilation and hit diagnostics on stderr. It is omitted
from `boomkat_jit`. Generated code shares each compiled function's lifetime;
the executable allocator packs functions into shared chunks. Interrupt checks
bound native work, and custom interrupt callbacks retain the interpreter path.
