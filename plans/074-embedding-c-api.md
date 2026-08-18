# Embedding C-API: interrupt control, property access, construction, source locations

Design for the embedding gaps plan 070 found in `include/jse.h` (its "E1" and
"E2" sections). This plan names the work for what it is, a C embedding API, and
uses QuickJS as the reference design. It ends with the phasing to land the
surface; implementation starts only after this document is reviewed.

## 1. Goal and non-goals

The API should let a host:

- interrupt a runaway script (the `while(true){}` hang, plan 070 E1) and keep
  the runtime usable afterwards;
- inspect and build object graphs: read and write properties, enumerate keys,
  construct objects and arrays;
- learn where a failure happened: which script, which line, which column;
- call JS functions from host code outside a host-function callback.

What it should not do, in this pass:

- bytecode serialisation. It is a compile-pipeline concern with its own
  version-coupling risks (QuickJS's own docs warn the format is version-locked
  and must never be loaded from untrusted sources), and it does not block any
  other item here. Deferred, with a sketch in section 10.
- a memory limit. The heap allocator would need a budget that interacts with GC
  pressure, which is a real feature rather than a surface addition. Deferred,
  sketched in section 10.
- BigInt and Symbol value access (no `jse_get_bigint` exists today, and symbol
  keys in enumeration). Deferred.
- `error.stack` (plan 070 B4). Property access here is a prerequisite for a
  host to read a thrown error's fields, but building real stack traces is a
  separate project.

## 2. Reference: QuickJS

The surface below mirrors QuickJS function for function where the existing ABI
allows it. The mapping, with the deviations that follow from this engine's
handle model:

| QuickJS | This plan |
|---------|-----------|
| `JS_SetInterruptHandler(rt, cb, opaque)` | `jse_set_interrupt_handler(rt, cb, opaque)` |
| `JS_GetPropertyStr` / `JS_GetPropertyUint32` | `jse_get_prop` / `jse_get_prop_index` |
| `JS_SetPropertyStr` / `JS_SetPropertyUint32` | `jse_set_prop` / `jse_set_prop_index` |
| `JS_HasProperty` / `JS_DeleteProperty` | `jse_has_prop` / `jse_delete_prop` |
| `JS_GetOwnPropertyNames` | `jse_own_prop_names` (returns a JS array, not a C array) |
| `JS_NewObject` / `JS_NewArray` / `JS_NewStringLen` | `jse_new_object` / `jse_new_array` / `jse_new_string` |
| `JS_GetGlobalObject` | `jse_get_global` |
| `JS_Eval(ctx, src, len, filename, flags)` | `jse_eval_with_name` (new) |
| `JS_IsUncatchableError` | `JSE_ERR_INTERRUPT` status |
| `JS_Call(ctx, ...)` | `jse_call_rt` (new; the existing `jse_call` is callback-only) |

Two reference behaviors deserve explicit study, both verified against the
vendored quickjs-ng sources in `quickjs/quickjs.c`:

- **The interrupt is uncatchable.** `JS_SetInterruptHandler` (line 2227) stores
  a callback the interpreter polls (`js_poll_interrupts`, line 7868, every
  `JS_INTERRUPT_COUNTER_INIT` = 10000 poll points). Returning non-zero raises
  "interrupted" and marks the exception uncatchable
  (`JS_ThrowInterrupted`, line 7849: `JS_ThrowInternalError` plus
  `JS_SetUncatchableException(TRUE)`). A JS `try/catch` cannot intercept it;
  it unwinds straight to the host, which drains it with `JS_GetException`. That
  is the property plan 070 demands ("a `try`/`catch` in script must not be able
  to swallow it and resume looping"), and it is the reason the plan does not
  offer a catchable interrupt: any design where a catch handler runs at all
  lets the script after the catch execute, including another loop.
- **The handler is polled, not preemptive.** It runs on the engine thread at
  interpreter safepoints. It must not call back into the engine (no eval, no
  call, no value manipulation). Cross-thread interruption is done by the host
  setting a flag in the handler's `opaque` data and the handler returning it.
  This plan keeps both contracts and documents them in the header.

## 3. Constraints carried from the current ABI

Plan 070 lists what works and must survive the additions:

- errors never unwind through C (no longjmp, no aborts across the boundary);
- `jse_last_error` never re-enters the VM, so a throwing user `toString`
  cannot recurse on the unwind path;
- readers clear the error on entry, so stale messages do not leak between
  calls;
- the runtime stays usable after an ignored error;
- the handle registry is a GC root, and freed slots are retired by generation
  so a stale handle can never resolve to a later value.

Two more constraints this plan adds:

- The VM dispatch loop must stay hot. `Vm.run`'s inner loop
  (`src/vm/vm_execute.c3:1915`) deliberately tests no per-instruction
  condition; the interrupt poll must ride the existing backward-branch
  safepoint sites, not add a branch to every instruction.
- `vm_execute` must not import `capi`. The poll site needs the handler, but
  `capi` imports `vm`, so the handler state lives on the Heap next to the
  existing capi hooks (`capi_roots`, `capi_runtime`, `capi_mark` in
  `src/capi.c3:176-178`), which `vm_execute` already reaches through
  `vm.heap`.

## 4. API surface

New declarations in `include/jse.h`, grouped by concern. Every function that
can fail follows the existing status-code contract (0 is success, negative is
an error, `jse_last_error`/`jse_last_error_info` carries the detail, readers
clear on entry).

### 4.1 Interrupt control

```c
/* Return non-zero to abort the running script. Runs on the engine thread at
 * VM safepoints. Must not call back into the engine; set a flag in `opaque`
 * from another thread instead. */
typedef int (*jse_interrupt_handler)(jse_runtime rt, void *opaque);

/* Install or replace the handler. Pass NULL for `cb` to clear. Never fails;
 * a NULL runtime is a no-op. */
JSE_API void jse_set_interrupt_handler(jse_runtime rt,
                                       jse_interrupt_handler cb,
                                       void *opaque);
```

`JSE_ERR_INTERRUPT` is added to the status enum, after `JSE_ERR_FULL`:

```c
JSE_ERR_INTERRUPT = -8  /* aborted by the interrupt handler; see error info */
```

The interrupt surfaces as `JSE_ERR_INTERRUPT` from any call that runs the VM
(`jse_eval`, `jse_eval_with_name`, `jse_call_rt`, the callback-context
`jse_call`, `jse_drain_microtasks`), with `jse_last_error` returning
"interrupted". A dedicated code beats `JSE_ERR_THROW` plus a flag: the host's
first reaction to an interrupted eval (stop the process work, report a
timeout) is different from its reaction to a script error, and it should not
have to parse a message to tell them apart. QuickJS draws the same distinction
with `JS_IsUncatchableError`.

`jse_drain_microtasks` changes from `void` to `int` to report an interrupt
fired during the drain: the host needs to know its abort happened, and the
reader-style error state would be wiped by the next call. Existing callers
that ignore the return value still compile and link unchanged.

### 4.2 Eval with a script name

```c
/* Like jse_eval, with `name` (UTF-8, `name_len` bytes) recorded as the script
 * name for error reporting. The name is copied into runtime storage. NULL
 * `name` is accepted and behaves like an empty name. */
JSE_API int jse_eval_with_name(jse_runtime rt, const char *src, size_t len,
                               const char *name, size_t name_len,
                               jse_value *out_val);
```

`jse_eval` stays with its current signature and becomes a thin wrapper that
forwards with name `"<eval>"`, so existing callers and binaries are
unaffected. The name matters for the error info below; it also becomes the
script name a future `error.stack` would print.

### 4.3 Error location and kind

```c
typedef struct {
    int   code;          /* JSE_ERR_* of the failure, JSE_OK if none */
    int   line;          /* 1-based line, 0 if unknown */
    int   col;           /* 1-based column, 0 if unknown */
    const char *script_name; /* name from jse_eval_with_name, or NULL */
} jse_error_info;

/* Fill *out with the details of the most recent failure on this runtime.
 * `script_name` points to runtime-owned storage with the same lifetime as
 * jse_last_error. Returns JSE_OK, or JSE_ERR_INVALID for a NULL `out`. */
JSE_API int jse_last_error_info(jse_runtime rt, jse_error_info *out);
```

The compiler already knows the position: the Lexer records `err_line` /
`err_col` (`src/lexer.c3:502`), and the CLI prints them as
`SyntaxError: ... (line 1, col 20)` (`cli/boomkat.c3:100`). `jse_eval`'s
compile-failure path copies `lex.err_msg` into the runtime buffer today
(`src/capi.c3:340-352`) but drops the position; this adds `line`/`col` to the
Runtime alongside `errmsg` and copies them in the same place. Runtime-throw
positions use the per-function `line_table` (`src/bytecode.c3:1430`,
`get_line_for_pc`) where the throw site is known; the thrown value's own
recorded position is a later refinement once `error.stack` work (plan 070 B4)
needs it.

`script_name` answers plan 070's "cannot tell a user which file or line
failed" without waiting for stack traces.

### 4.4 Value construction

Handles returned by these are caller-owned and must be `jse_value_free`d,
like `jse_eval` results.

```c
JSE_API int jse_new_number(jse_runtime rt, double d, jse_value *out);
JSE_API int jse_new_bool(jse_runtime rt, int b, jse_value *out);
JSE_API int jse_new_null(jse_runtime rt, jse_value *out);
JSE_API int jse_new_undefined(jse_runtime rt, jse_value *out);
/* Fresh JS string from `len` bytes of UTF-8 (converted to the engine's
 * internal CESU-8, mirroring jse_return_string). */
JSE_API int jse_new_string(jse_runtime rt, const char *utf8, size_t len,
                           jse_value *out);
JSE_API int jse_new_object(jse_runtime rt, jse_value *out);
JSE_API int jse_new_array(jse_runtime rt, jse_value *out);
/* Fresh array whose elements are the first `n` of `elems`. Caller keeps
 * ownership of the input handles. */
JSE_API int jse_new_array_from(jse_runtime rt, const jse_value *elems,
                               unsigned int n, jse_value *out);
```

These mirror the `jse_return_*` helpers but live on the runtime side, for
hosts outside a callback. `jse_new_undefined`/`jse_new_null` still allocate a
registry slot (the slot registry is the only value transport; a handle must be
releasable), and they report `JSE_ERR_FULL` on exhaustion like everything
else. Error codes: `JSE_OK`, `JSE_ERR_INVALID` (null out), `JSE_ERR_FULL`
(slot table), `JSE_ERR_NOMEM` (heap).

### 4.5 Property access and enumeration

```c
/* Read a property, following the prototype chain. A missing property yields
 * JSE_OK with *out set to a handle of undefined, matching JS_GetPropertyStr.
 * A getter or Proxy trap that throws returns JSE_ERR_THROW. */
JSE_API int jse_get_prop(jse_runtime rt, jse_value obj,
                         const char *key, size_t key_len, jse_value *out);
JSE_API int jse_get_prop_index(jse_runtime rt, jse_value obj,
                               unsigned int idx, jse_value *out);

/* Write a property with full Set semantics (own or inherited writable
 * data/accessor). The value is copied into the object; the handle remains
 * caller-owned. A setter or a strict-mode write failure throws, reported as
 * JSE_ERR_THROW. */
JSE_API int jse_set_prop(jse_runtime rt, jse_value obj,
                         const char *key, size_t key_len, jse_value val);
JSE_API int jse_set_prop_index(jse_runtime rt, jse_value obj,
                               unsigned int idx, jse_value val);

/* `key in obj`, chain included. Sets *out to 0 or 1. */
JSE_API int jse_has_prop(jse_runtime rt, jse_value obj,
                         const char *key, size_t key_len, int *out);

/* `delete obj.key`. Sets *out to 1 if deleted, 0 if the property was not
 * found or not deletable. A strict-mode delete of a non-configurable property
 * throws, reported as JSE_ERR_THROW. */
JSE_API int jse_delete_prop(jse_runtime rt, jse_value obj,
                            const char *key, size_t key_len, int *out);

/* Fresh array of the object's own string property names (enumerable and not;
 * symbol keys deferred). The host walks it with jse_get_prop_index. */
JSE_API int jse_own_prop_names(jse_runtime rt, jse_value obj, jse_value *out);
```

Returning the key list as a JS array instead of a C array (QuickJS allocates a
`JSPropertyEnum*` the caller frees with `JS_FreePropertyEnum`) keeps the ABI
free of heap-ownership rules: the array is an ordinary handle with the
existing free protocol, and walking it reuses `jse_get_prop_index`. All five
return `JSE_ERR_TYPE` for a non-object `obj`, `JSE_ERR_THROW` for a trap or
accessor throw, `JSE_ERR_INVALID` for bad handles, `JSE_ERR_FULL`/`NOMEM`
where allocation happens. `jse_get_prop` never fails on a missing property:
absence is undefined, matching JS.

With these, a host can also inspect a thrown error object (`err.message`,
`err.name`, `err.stack` once it exists) instead of relying on the formatted
`jse_last_error` string.

### 4.6 Global object and calling JS from the host

```c
/* Handle to the global object (globalThis). Caller owns it. */
JSE_API int jse_get_global(jse_runtime rt, jse_value *out);

/* Call a JS function from outside a callback. `argv`/`argc` (NULL/0 for
 * none), `this_val` (0 for undefined). On JSE_OK, *out_val receives a
 * caller-owned handle. A thrown callee returns JSE_ERR_THROW (or
 * JSE_ERR_INTERRUPT for an interrupt); the exception is recorded on the
 * runtime, not unwound through C. */
JSE_API int jse_call_rt(jse_runtime rt, jse_value func,
                        const jse_value *argv, unsigned int argc,
                        jse_value this_val, jse_value *out_val);
```

`jse_call_rt` is named apart from `jse_call` because C has no overloading and
the two share a symbol namespace: the existing `jse_call` takes a
`jse_call_ctx` (scope-handle resolution for arguments) and is valid only
inside a host callback; `jse_call_rt` takes a runtime and resolves everything
through the registry. If the callee is a host function, the engine constructs
a fresh call context for it, so a host-function callback invoked this way sees
normal `jse_arg`/`jse_this` semantics. The recursion bound that limits
host-to-JS nesting applies to the new path too.

## 5. Interrupt mechanism

### 5.1 Where the poll goes

The handler is polled at VM safepoints, matching the existing
`bwd_gc_budget` pattern (`src/vm/vm_execute.c3:2979,3025,3314,3323,3332,4680`):
a per-heap counter is decremented on backward branches and triggers the poll at
zero. State placement follows the no-import-cycle rule: `vm.heap` carries
`capi_interrupt_fn`, `capi_interrupt_opaque`, and `interrupt_budget`, set by
`jse_set_interrupt_handler` (which reaches the heap through the runtime) and
polled from the dispatch loop, exactly as `capi_mark` is set by capi and
invoked by the heap's mark phase.

Poll sites, in order of coverage:

1. the five backward-branch sites above, shared with the GC budget check. A
   runaway loop always hits one of these, which is the case plan 070 cares
   about;
2. the top of the inner dispatch loop (`ds.needs_restart` re-entry), which
   covers recursion: `function f(){ f() }` spends most of its time in
   call/restart, not back-edges;
3. the threaded-dispatch burst must remain bounded below the interrupt
   interval, so a burst cannot starve the poll. The existing cold-path bail
   already bounds bursts; the implementer verifies the bound and forces a
   bail if a burst can exceed the interval.

The budget is reset to `INTERRUPT_BUDGET_INIT` (a power of two, matching
QuickJS's counter-reset semantics at line 7858) after each handler call, and
also at `jse_eval`/`jse_eval_with_name` entry, so a near-zero budget from a
previous interrupted run cannot cause an immediate unprompted callback.

No handler installed means a single null compare per poll point; the counter
decrement rides the existing GC-budget decrement site, so uninterrupted
execution pays one compare-and-branch at the same cadence it already pays for
GC. That satisfies plan 070's "uninterrupted scripts must be unaffected".

### 5.2 The throw is uncatchable

When the handler returns non-zero, the VM raises an internal Error with
message "interrupted" and sets a VM-level flag `uncatchable_throw`. The throw
machinery (`vm_throw_value`, `src/vm/vm_throw.c3:31`) skips catch catchers
while the flag is set but still routes through finally catchers, so `finally`
blocks run during the unwind exactly as they do for an ordinary throw. A JS
`try/catch` cannot intercept the error, which is the requirement; `finally`
running is what makes the interrupt observable in script, and it cannot resume
the loop.

The flag, not a marker value, carries the uncatchability, and the thrown value
is a genuine Error instance. A value marker would be invisible to JS, which
matters if the interrupt ever unwinds through promise machinery: a promise
settled with a marker value would expose an internal tag to script. An Error
object is safe everywhere. The flag is cleared only when the host receives the
failure, at the fault paths of the jse_* entry points that run the VM, never
inside the engine.

Edge to audit during implementation: an interrupt raised while a promise
reaction or a generator step is executing must propagate to the caller of the
drain (jse_eval's automatic drain, `jse_drain_microtasks`) as
`JSE_ERR_INTERRUPT` rather than settling a promise with the error. Phase 1's
tests cover the plain and try/catch cases; the async-drain variant gets a
dedicated test once that path is reviewed.

### 5.3 Runtime stays usable

The interrupt unwind uses the existing throw path: activations pop, catcher
chains free, the interrupted frame's registers release. The flag clears at the
host boundary, the budget resets, and the runtime is a normal runtime again. A
host that wants to keep running scripts can leave the handler installed (the
next eval starts with a fresh budget) or clear it with
`jse_set_interrupt_handler(rt, NULL, NULL)`. Nothing about the interrupt
poisons the heap or the registry; the regression test asserts this directly.

### 5.4 Threading contract

The handler runs on the thread executing the VM, like every other engine
entry. It must not call any jse_* function (the header documents this beside
the typedef). A host that wants to interrupt from another thread stores a flag
in `opaque` (volatile or atomics per the host's own needs) and the handler
returns it; the engine never touches `opaque`. This mirrors QuickJS's
contract: `JS_SetInterruptHandler` is exactly how qjs implements Ctrl-C.

## 6. Sample usages

### 6.1 Interrupt and recover

The plan 070 E1 shape: install a handler, run `while(true){}`, assert the
eval returns the interrupt status within a bounded number of callbacks, then
prove the runtime still works.

```c
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "jse.h"

static volatile sig_atomic_t g_calls;

/* Runs on the engine thread at VM safepoints. Never calls back into the
 * engine. */
static int my_interrupt(jse_runtime rt, void *opaque) {
    (void)rt; (void)opaque;
    return ++g_calls >= 1000;   /* abort after 1000 polls */
}

static void on_alarm(int sig) {
    (void)sig;
    write(2, "FAIL: engine never polled the interrupt handler\n", 47);
    _exit(1);
}

int main(void) {
    jse_runtime rt = NULL;
    jse_value v;
    if (jse_open(&rt) != JSE_OK) return 1;

    jse_set_interrupt_handler(rt, my_interrupt, NULL);

    signal(SIGALRM, on_alarm);
    alarm(30);                  /* in-suite watchdog: no external timeout */

    const char *src = "while(true){}";
    int rc = jse_eval(rt, src, strlen(src), &v);
    alarm(0);

    if (rc != JSE_ERR_INTERRUPT) {
        printf("FAIL: expected interrupt, got %d (%s)\n", rc, jse_last_error(rt));
        jse_close(rt);
        return 1;
    }

    /* The runtime must remain usable: a plain eval succeeds. */
    rc = jse_eval(rt, "1+1", 3, &v);
    if (rc != JSE_OK) {
        printf("FAIL: runtime not usable after interrupt: %s\n", jse_last_error(rt));
        jse_close(rt);
        return 1;
    }
    double d;
    jse_get_number(rt, v, &d);
    jse_value_free(rt, v);
    if (d != 2.0) return 1;

    jse_close(rt);
    printf("interrupt: ok (%ld polls)\n", (long)g_calls);
    return 0;
}
```

A companion snippet asserts the uncatchable property, run in the same test
binary:

```c
static const char *swallow = "try { while(true){} } catch (e) { /* must not run */ }";
rc = jse_eval(rt, swallow, strlen(swallow), &v);
/* Still JSE_ERR_INTERRUPT; the catch did not swallow the abort. */
```

### 6.2 Build a config object and read it back

```c
static int make_config(jse_runtime rt, jse_value *out) {
    jse_value obj, host, port, arr, s1, s2;
    int rc;
    if ((rc = jse_new_object(rt, &obj)) != JSE_OK) return rc;
    if ((rc = jse_new_string(rt, "example.com", 11, &host)) != JSE_OK) goto fail;
    if ((rc = jse_set_prop(rt, obj, "host", 4, host)) != JSE_OK) goto fail;
    if ((rc = jse_new_number(rt, 8080, &port)) != JSE_OK) goto fail;
    if ((rc = jse_set_prop(rt, obj, "port", 4, port)) != JSE_OK) goto fail;
    if ((rc = jse_new_array(rt, &arr)) != JSE_OK) goto fail;
    if ((rc = jse_new_string(rt, "fast", 4, &s1)) != JSE_OK) goto fail;
    if ((rc = jse_new_string(rt, "strict", 6, &s2)) != JSE_OK) goto fail;
    if ((rc = jse_set_prop_index(rt, arr, 0, s1)) != JSE_OK) goto fail;
    if ((rc = jse_set_prop_index(rt, arr, 1, s2)) != JSE_OK) goto fail;
    if ((rc = jse_set_prop(rt, obj, "opts", 4, arr)) != JSE_OK) goto fail;
    jse_value_free(rt, host);
    jse_value_free(rt, port);
    jse_value_free(rt, s1);
    jse_value_free(rt, s2);
    jse_value_free(rt, arr);    /* set_prop copied; the handle is now ours */
    *out = obj;
    return JSE_OK;
fail:
    jse_value_free(rt, obj);
    return rc;
}

/* ... jse_eval(rt, "config.port", 11, &v); then: */
static void read_port(jse_runtime rt, jse_value v) {
    jse_value port;
    if (jse_get_prop(rt, v, "port", 4, &port) != JSE_OK) return;
    double d;
    jse_get_number(rt, port, &d);
    jse_value_free(rt, port);
    printf("port = %.0f\n", d);
}
```

### 6.3 Enumerate keys and report an error with its location

```c
static void dump_keys(jse_runtime rt, jse_value obj) {
    jse_value keys, lenv, k, sv;
    if (jse_own_prop_names(rt, obj, &keys) != JSE_OK) return;
    jse_get_prop(rt, keys, "length", 6, &lenv);
    double n;
    jse_get_number(rt, lenv, &n);
    jse_value_free(rt, lenv);
    char buf[256];
    size_t got;
    for (int i = 0; i < (int)n; i++) {
        if (jse_get_prop_index(rt, keys, (unsigned)i, &k) != JSE_OK) continue;
        if (jse_get_string(rt, k, buf, sizeof buf, &got) == JSE_OK) {
            printf("  %s\n", buf);
        }
        jse_value_free(rt, k);
    }
    jse_value_free(rt, keys);
}

static int run_script(jse_runtime rt, const char *name, const char *src) {
    jse_value v;
    int rc = jse_eval_with_name(rt, src, strlen(src), name, strlen(name), &v);
    if (rc != JSE_OK) {
        jse_error_info info;
        jse_last_error_info(rt, &info);
        fprintf(stderr, "%s:%d:%d: %s\n",
                info.script_name ? info.script_name : "<eval>",
                info.line, info.col, jse_last_error(rt));
        return rc;
    }
    jse_value_free(rt, v);
    return JSE_OK;
}
```

## 7. Header and ABI changes

All additions to `include/jse.h`:

- `JSE_ERR_INTERRUPT = -8` appended to the status enum (ABI-safe, existing
  values unchanged);
- the `jse_interrupt_handler` typedef and `jse_set_interrupt_handler`;
- the `jse_error_info` struct and `jse_last_error_info`;
- `jse_eval_with_name`, `jse_new_*` (7 functions), `jse_get_global`;
- the property family: `jse_get_prop`, `jse_get_prop_index`, `jse_set_prop`,
  `jse_set_prop_index`, `jse_has_prop`, `jse_delete_prop`,
  `jse_own_prop_names`;
- `jse_call_rt`.

No existing signature changes except `jse_drain_microtasks` returning `int`
instead of `void` (section 4.1). `jse_eval` becomes an internal forward to the
named variant but keeps its exported symbol and behavior, so binaries linked
against the current archive keep working. `jse_version` gets a minor bump when
the surface lands.

## 8. Validation

New C test `test/capi/embed_api.c`, built and run through a Makefile target
`test-embed-api` in the style of `test-host-abi` (cc, `-std=c99 -Wall
-Wextra -pedantic -Iinclude`, link `out/jse_static.a $(JSE_LDLIBS)`). It
covers, in order:

- interrupt: the 6.1 flow including the `try/catch` swallow attempt and the
  post-interrupt `1+1`; the SIGALRM watchdog is part of the binary, so the
  test exits on its own with no external `timeout` (plan 070: "an in-suite
  watchdog is the whole point"). The alarm path is POSIX-only; the file
  guards it with `#ifndef _WIN32` and relies on the CI timeout there.
- construction and properties: build the 6.2 config object, hand it to JS
  (`eval("config.port")` returns 8080), read properties back, exercise
  `jse_has_prop` on present and absent keys, `jse_delete_prop` on an own
  property and on a prototype property, and a Proxy whose get trap throws
  (asserting `JSE_ERR_THROW`, proving traps surface rather than crash).
- enumeration: `jse_own_prop_names` on an object with enumerable and
  non-enumerable own keys (via `Object.defineProperty`), asserting both
  appear.
- source locations: `jse_eval_with_name` of a bad source asserts
  `JSE_ERR_SYNTAX`, `info.line`/`info.col` match the CLI's values for the
  same source, and `info.script_name` matches. A runtime throw (eval
  `throw new TypeError("x")`) asserts `JSE_ERR_THROW` and, once the
  line_table path lands, a line.
- `jse_call_rt`: eval defines `function add(a,b){return a+b;}`, persist it,
  call with two numbers from C, check the result. Also a host-registered
  function called via `jse_call_rt` (exercising the fresh-call-context path).
- reuse after errors: after each failure above, `jse_eval("1")` succeeds.

Each section prints a PASS line and the binary exits non-zero on the first
failure, matching the other `test/capi` binaries.

Regression checks: `just test-local` and `just rosetta` (the poll adds a
branch to hot backward-branch sites; both suites exercise loops heavily), one
`just test262-phase` run, and a perf sanity check against the previous
baseline to confirm the no-handler path costs nothing measurable.

## 9. Phasing

- **Phase 1: interrupt.** `jse_set_interrupt_handler`, `JSE_ERR_INTERRUPT`,
  the Heap-side handler state, the poll sites, the uncatchable throw, the
  async-drain audit, and the interrupt section of `embed_api.c`. This is the
  critical gap: without it a host cannot run untrusted or buggy script at
  all.
- **Phase 2: object graph.** `jse_new_*`, `jse_get_global`, the property
  family, `jse_call_rt`, and their test sections. Landed together because
  construction without property access is inert.
- **Phase 3: source locations.** `jse_eval_with_name` (which also rewires
  `jse_eval`), `jse_last_error_info`, Runtime-side `line`/`col`/`script_name`
  storage, syntax-error positions first (the lexer already tracks them),
  then the line_table path for runtime throws where the site is known.
- **Phase 4: hardening.** GC_STRESS/ASan run of the construction and
  enumeration paths (new values flow through the registry mark), and the
  non-nanbox build (`just build-nonanbox` / `test-nonanbox`) since the
  property machinery touches TVal internals.

## 10. Deferred

- **Bytecode serialisation.** Separate compile-pipeline project. The risks
  are version coupling (a serialized function is only valid for the exact
  opcode set that produced it) and security (QuickJS refuses to load
  untrusted bytecode for exactly this reason). When it lands it should reuse
  the existing `CompiledFunction` dump surface in `src/bytecode.c3`.
- **Memory limit.** `jse_set_memory_limit(rt, bytes)` would put a budget on
  the Heap allocator and throw a catchable out-of-memory error when the
  budget is hit, after forcing a GC so the limit cannot be dodged by garbage.
  The GC-pressure interaction (when to collect vs. when to fail) is the real
  design work; the API itself is one function.
- **BigInt/Symbol values and symbol keys in `jse_own_prop_names`.** Follows
  the same shape as the numeric/string constructors once the engine's own
  BigInt surface is settled.
- **`error.stack` (plan 070 B4).** Property access is now available for a
  host to read error fields; building real stack traces stays separate.
