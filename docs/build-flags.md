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

The `SLJIT` feature compiles the native backend into the CLI and the C
libraries; native compilation itself stays off until it is switched on.
`boomkat --jit file.js` enables it for one run, and `--jit-stress` also
compiles every function on its first call (a test setting). Embedders call
`bk_set_jit(runtime, 1)` or, in C3, `runtime.set_jit(true)`; zero or false
disables it again. The setting is shared by every context in the runtime.

The backend runs on 64-bit NaN-boxing builds with threaded dispatch, which the
slim and tiny profiles are not. Where it is unavailable, `--jit` reports an
error and exits with status 2, the C setter returns `BK_ERR_INVALID`, and the
C3 setter returns false; disabling always succeeds.

A source build with `SLJIT` also compiles `vendor/sljit/sljit_src/sljitLir.c`
and `src/jit/sljit_shim.c` with `vendor/sljit/sljit_src` on the include path;
the `boomkat` target in `project.json` shows the settings.
