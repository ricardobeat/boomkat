# Engine architecture

Boomkat compiles JavaScript directly to register bytecode and runs it in a C3
virtual machine. Objects use shared shapes and inline caches; memory is managed
by reference counting plus a tracing collector for cycles. This guide follows
the path from source text to execution, then explains the representations and
ownership rules that connect the parts.

Start with [How a script runs](#how-a-script-runs) for the whole path. The later
sections cover the [compiler](#from-source-to-bytecode),
[VM](#the-virtual-machine), [values and objects](#values-and-objects),
[memory](#memory-the-heap-the-collector-and-strings), and
[builtins and modules](#builtins-and-modules).

## How a script runs

Running a file containing `f("hi")` crosses these boundaries:

1. **Compile:** `compile()` creates a `CompilerContext`. The lexer supplies
   tokens on demand, and the parser emits bytecode without building an AST.
   Each function body gets a `CompiledFunction`; `finish()` optimizes its code.
2. **Enter:** The VM creates a top-level `Activation`. Its registers occupy a
   window in the shared value stack, and its scope points at the global
   environment.
3. **Execute:** `Vm.run` loads frame state into `Dispatch`. `GETVAR` resolves
   `f`, `LDCONST` loads `"hi"`, and `CALL` pushes another activation. The outer
   dispatch loop then loads the callee's state.
4. **Allocate and collect:** Objects come from the heap with a shape and a
   temporary GC root. Reference counts release most dead values; tracing at
   safepoints reclaims cycles.
5. **Drain jobs:** After the top-level execution, the VM drains promise jobs
   and resumes async continuations they schedule.

## Where the code lives

| Path | What is in it |
|---|---|
| `src/lexer.c3` | Tokenizer, driven on demand by the compiler |
| `src/compiler/` | Single-pass parser and code generator, plus the optimization passes |
| `src/bytecode.c3` | Instruction encoding, the opcode set, `CompiledFunction` |
| `src/vm/` | The dispatch loop, calls, property access, exceptions, generators |
| `src/heap.c3` | Allocation, collection, string table, shapes, job queue |
| `src/types.c3` | `TVal` and `HeapHeader`, the two universal representations |
| `src/hobject.c3` | Object layout, property storage, shapes, inline caches |
| `src/hstring.c3` | String storage, interning, and CESU-8 conversion |
| `src/env.c3` | Environment records and the scope chain |
| `src/module.c3` | The ESM lifecycle: resolve, link, evaluate |
| `src/builtins/` | The standard library, one file per area |
| `cli/` | The `boomkat` and debug binaries, and the test262 runner |

## From source to bytecode

### The lexer

The compiler requests tokens as it parses. JavaScript needs this cooperation:
`/` can begin a regexp or divide two expressions, and `}` can close a block or
resume a template literal. The lexer records line breaks for automatic
semicolon insertion and tracks nesting inside `${...}`.

The speculative helpers in `src/compiler/tokens.c3` look ahead for ambiguous
forms such as `async (x)`. They restore the lexer's position when the form does
not match, leaving the ordinary parse at the same token.

### The compiler

The parser emits bytecode while recognizing each construct. It does not retain
an AST. `CompilerContext` owns the instruction buffer, constant pool, register
allocator, scope stack, and flags for one function. A nested function gets its
own context and becomes a template in the parent's `inner_funcs` array.

Scripts and dynamic function bodies default to sloppy mode; modules default to
strict mode. A `"use strict"` directive or class body also selects strict mode.
The compiler enforces syntax rules with that context and stores the result in
`FuncFlags.is_strict` for runtime behavior. Class code is strict throughout,
including its own binding name.

Ambiguous forms require a second look. The compiler saves a lexer position and
reparses `(a, b)` if it proves to be arrow parameters, or `[a, b]` if an `=`
turns it into a destructuring target. Other constructs patch bytecode already
emitted.

For `a.b`, the parser cannot yet tell whether the member will be read, assigned,
incremented, or deleted. It records the base and key in
`CompilerContext.member` until the enclosing expression chooses the operation.
Its tagged `MemberRef` distinguishes plain, private, and `super` members and
requires producers to set every operand together.

The `boomkat_memberstrict` build traps a read of an absent member or a register
outside the live window at the point of compilation. Shipping builds omit
these checks.

### Registers and scopes

The compiler allocates temporary registers from the top of a stack and releases
them in reverse order. Parameters and locals keep their slots for the function's
lifetime. `regalloc.c3` covers expressions that need to release a register while
higher temporary registers remain live.

The compile-time scope stack mirrors runtime environments. A name uses a
register when its binding is known and local; it uses an environment lookup
when eval, `with`, closure capture, or scope rules require one. `needs_env`
tells the call path whether to allocate a function scope. A pass removes
environment writes and scope push/pop instructions when no surviving operation
needs them. Retained TDZ and const bindings keep their scope layout.

Each declaration has a binding record with its home register, scope kind, and
capture state. The compiler compares these records with name consumers in
nested functions before removing environment stores. It retains all producers
for a spelling when distinct scopes make ownership ambiguous. For eligible
unique var and parameter bindings, the compiler can prove that no child uses
the binding and keep it in a register.

An eligible reference to an enclosing binding becomes `GETCAP`, `PUTCAP`, or
`PUTCAP_SNAP`. The closure holds indexed descriptors for the shared binding
slots. A descriptor keeps its owner alive and loads the owner's current value
array, since that array can resize. If resolution crossed a scope that might
gain the name later, access checks for a nearer binding and falls back to name
lookup when one appears. GC traces descriptor owners alongside the captured
environment chain.

Eligible captured var and parameter bindings can instead share a private dense
cell array. `NEWCELLS` allocates it, and `GETCELL`, `SETCELL`, and `MOVECELL`
serve accesses in the defining function. Child descriptors point into the same
array. Its persistent register stays below temporary call windows. TDZ, const,
dynamic scope, ambiguous names, and captures without a direct mapping retain
their checked environment path.

### Classes and private names

Classes compile to a constructor function plus installation code for methods,
accessors, and fields. Instance fields become a hidden `__field_init__` function
the constructor runs after `this` is bound, which is why `CompiledFunction`
carries a direct pointer to it rather than an index.

Private names (`#x`) are compile-time resolved to hidden symbols kept in a stack
of `PrivateNameEntry` records scoped by class nesting. A class with any private
member also stamps a *brand* on its instances, so `#x in obj` and private access
on a foreign object can be checked without a property lookup.

Direct `eval` complicates this: the spec gives eval the caller's
PrivateEnvironment, but eval compiles against a fresh context. The enclosing
function therefore snapshots its private-name table into
`CompiledFunction.eval_private_names`, and `builtin_eval` passes it back in.

### Optimization passes

`finish()` optimizes the emitted instruction stream. The order in
`fusion.c3` matters:

1. `GETVAR` + `INC`/`DEC` + `PUTVAR` fuses into `INC_VAR`/`DEC_VAR`.
2. `LDCONST` + `GETPROP` fuses into `GETPROPC`.
3. A comparison feeding a branch fuses into a jump form such as `JMP_LT`. Loose
   `EQ` and `NEQ` are excluded, since they coerce and can throw.
4. Copy propagation substitutes through `LDREG` moves, exposing consumers that
   a parser-emitted move separated from their producers.
5. `LDINT` + `ADD`/`SUB` fuses into `ADDI`/`SUBI`.
6. Dead moves are removed; peephole cleanup and NOP compaction close gaps.

The fusion drivers check jump targets and register liveness before replacing a
sequence. A branch cannot land inside a sequence whose producer was removed.

The `prim_globals.c3` pre-scan proves that some script globals remain primitive
and cannot be changed through dynamic access. Those reads and writes use
opcodes without heap ownership checks; uncertainty keeps the guarded path.

## The virtual machine

### The dispatch loop

The outer loop in `Vm.run` loads the active frame's code, constants, caches,
register base, and program counter into `Dispatch`. The inner loop executes
instructions. A JS-to-JS call pushes an `Activation` and restarts the outer
loop; it does not recurse on the C stack. `MAX_CALLS` bounds this activation
array at 4096 frames.

Every compiled function ends with a return opcode, so the inner loop needs no
fall-off check. Return and generator instructions handle `halt` at their own
sites.

A builtin calling back into JS, a getter, or a coercion hook can re-enter
`Vm.run` through `vm_call_fn_impl`. These nested runs count against
`MAX_RUN_DEPTH` (128). Saved frame pointers must be relocated if the growable
value stack moves during re-entry.

### Frames

An `Activation` records its function, parent frame, variable and lexical
environments, catcher chain, program counter, and register window. Windows
share one growable value stack. `ensure_valstack_grow` must update saved
pointers after reallocating it.

Frames also carry the flags that drive spec behaviour: `ACT_FLAG_CONSTRUCT`,
`ACT_FLAG_DERIVED` for a derived constructor's return check,
`ACT_FLAG_THIS_OWNED` when the frame holds a reference to `this`, and
`ACT_FLAG_BORROWED_CALLEE` when the callee was copied from a global binding
without an incref, so the return write-back must not decref it.

For GC, `valstack_top` bounds the live stack area. The marker also scans each
frame's register span and fields that may be a value's only root: owned `this`,
`new_target`, an async promise, resumed generator state, and exceptions saved
in catchers.

### Calls

`resolve_call_var` selects the call path. An ordinary compiled function gets
an activation inline before dispatch restarts. Lightfuncs, builtins, bound
functions, generators, and class constructors use the general call path in
`vm_calls.c3`.

Construction carries `new.target` through the call chain. A derived
constructor starts with `this` uninitialized; `super()` finds and initializes
the owning frame. Reading `this` first throws, as does returning a primitive
other than `undefined` from that constructor.

### Property access

Threaded dispatch reads dense array elements and array `.length` directly when
its guards hold. Holes, other receivers, and values needing slower reference
ownership handling use the generic path. Length is read on each access so a
mutation is visible without a shape change.

`GETPROP` and `PUTPROP` consult the site cache, then the heap-wide
megamorphic cache, then perform a full lookup. An own-data read validates the
receiver's shape and loads its indexed slot; other cache entries also validate
the owner's storage pointer. Fused forms serve two-hop expressions such as
`a.b.c`.

Writes are where the exotics live. An array-index write may go to the dense part,
grow it, or fall through to the property table. A `length` write on an array
truncates. A typed-array write coerces the value first, and that coercion can run
user code that resizes or detaches the buffer, so the bounds are rechecked
afterwards.

### Array and call spread

`ARRSPRD` and `SPREAD_ARG` resolve `Symbol.iterator` first. A dense array using
the intrinsic values factory and `next` method can copy its range without
allocating iterator results. A custom factory still runs; if it returns an
intrinsic array iterator, its remaining dense range can be drained in bulk.
The destination reserves space once and owns a reference to every copied
heap value. Call spread refreshes register pointers after stack growth and
retains its source while argument slots may overwrite the source register.

Proxy iterator prototypes, custom `next` methods, and dense holes take the
generic iterator path, which can observe getters and inherited properties.
Bulk draining updates the iterator's index and releases its target on
exhaustion.

### Exceptions

`TRY` pushes a `Catcher` onto a chain rooted in the activation; `THROW` walks it
outward. The catcher records both handler PCs and the lexical environment at
entry, because an exceptional exit skips the try block's `POP_LEX` instructions
and the chain has to be rebalanced.

`finally` is the complicated part. A `return`, `break`, or `continue` crossing a
finally block is parked in the catcher as a pending completion and resumed by
`ENDFINALLY` once the block finishes, which is what lets a `return` inside the
finally body override the one that was already pending.

### Generators and async

A generator call does not run its body. It allocates a `GeneratorState`, runs
parameter initialization, and suspends at `GEN_START`, returning the generator
object.

`YIELD` saves the register window, program counter, environments, and catchers.
`.next()`, `.throw()`, and `.return()` restore them; `ResumeKind` tells the
resumed opcode which completion to inject.

Restoring heap values acquires references, then `track_restored_regs()` raises
the register watermark over the restored window. Both restore paths call it.
Any new bulk restore must do the same so frame teardown and GC scan the owned
values.

Async functions use the same suspension machinery. `AWAIT` registers a promise
reaction that resumes the saved frame from the microtask queue.

For eligible ordinary async functions, liveness analysis gives each await a
register mask. Suspension saves only live values up to the highest live slot;
resumption fills the rest with `undefined`. Generators and async functions with
handlers, captures, dynamic scope, or unsupported bytecode save full windows.

`yield*` delegation is a resumable state machine, because in an async generator
every spec `Await` inside the delegation is itself a real suspension. The
delegation's own program counter therefore lives in `ays_step` on the generator
state.

### Safepoints

A collection cannot run at an arbitrary instruction, since a builtin may hold a
fresh object in a raw local. The VM collects at backward jumps, which bounds
allocation between collections in a loop, and throttles them with
`bwd_gc_budget` so a tight loop does not thrash the collector.

## Values and objects

### TVal

Registers, property slots, and stack slots hold `TVal`s. The default build
NaN-boxes each value into eight bytes. `-D NONANBOX` selects a 16-byte tagged
union with the same JavaScript semantics.

NaN-boxing exploits the unused payload space in IEEE 754 NaNs. A double is any
value whose top 16 bits are at or below `0xFFF0`; everything above that is a
tagged non-double, with the payload in the low 48 bits:

| Tag | Payload |
|---|---|
| `0xFFF1` | 48-bit signed integer (fastint) |
| `0xFFF2` | `HBigInt*` |
| `0xFFF3`, `0xFFF4` | undefined, null (no payload) |
| `0xFFF5` | boolean, 0 or 1 |
| `0xFFF6`, `0xFFF7` | raw pointer, lightfunc |
| `0xFFF8` … `0xFFFA` | `HString*`, `HObject*`, buffer |
| `0xFFFB`, `0xFFFC`, `0xFFFF` | internal environment reference, poison, deleted-entry sentinel |

`set_number` canonicalizes NaNs whose bits overlap the tag range. Adjacent tags
make nullish and heap-value checks cheap. Fastints store signed integers in the
48-bit payload; `set_fastint_or_number` chooses that representation when the
integer fits, avoiding a double round trip in integer arithmetic.

`DELETED` and `POISON` are internal markers, never JavaScript values. `DELETED`
marks removed Map/Set entries; `POISON` exposes unwritten scanned storage.

### HeapHeader

Every collected allocation begins with a `HeapHeader`: flags, a refcount, and
the two list pointers that thread the heap together. `HString` and `HObject`
each define their own flags bitstruct whose low 7 bits mirror the header's, so a
raw cast from either to `HeapHeader*` reads the correct type and GC bits.

A refcount of `STRING_PINNED_REFCOUNT` marks a pinned string, on which incref
and decref do nothing. That sentinel is only meaningful together with
`is_string()`, since an object could legitimately reach the same count.

### HString

String bytes live next to the header, with a trailing NUL for C APIs. Published
strings are immutable. A uniquely owned, non-interned concat accumulator may
extend its spare capacity before another value can observe it.

String equality uses pointer identity when both strings are interned and
compares content otherwise. Strict equality, SameValue, and collection lookups
share that rule. Map and Set materialize a deferred content hash when needed.
Property tables use canonical keys: property-key conversion and insertion call
`Heap.ensure_interned` before relying on pointer identity.

Concatenation results defer hashing and interning. The weak string registry
tracks non-interned results, including short ones, for GC and heap teardown.

The internal encoding is **CESU-8**. JavaScript strings are sequences of
UTF-16 code units: an astral code point occupies two surrogate units, while a
lone surrogate is also a valid string element. Encoding each unit separately
preserves both cases. `normalize_to_cesu8` canonicalizes input for interning;
`write_cesu8_as_utf8` converts text for host output.

Character indexing is by UTF-16 code unit and cached. Each string remembers one
`(char_offset, byte_offset)` cursor, and `char_offset_to_byte_offset` scans from
whichever of the string start, the string end, or that cursor is nearest.
Because strings are immutable, the cache is only ever updated, never
invalidated. ASCII strings skip all of it: one byte is one character.

### HObject

An object starts with `HObjectBase`. Most classes store their subtype fields at
the following address, interpreted through `HObjectExtra`. `flags.obj_class`
selects the live member. `alloc_size_for_class()` allocates only the portion
needed by that class, rather than the whole union. `OBJECT` needs no subtype
fields; `GETTER_SETTER` uses its own smaller trailing area.

Every class but `GETTER_SETTER` also carries `INLINE_PROPS` (4) property slots
at the tail of its allocation, so an object with few properties needs no
separate property block at all.

**Property storage** has three lookup paths:

1. **The dense array part** holds nearby integer indices as bare `TVal`s.
   `dense_index_ok` prevents a distant index from allocating a huge gap.
2. **A hash table**, built once an object reaches `HASH_MIN_PROPS` (8)
   properties. It maps a key pointer to an index in the value array.
3. **A linear scan of the shape chain**, which is what small objects use.

Some numeric-string properties also live in the named table; writes keep the
dense part consistent when that index is present there.

### Shapes

An object stores property values; its `Shape` records the corresponding names
and flags. Adding a property follows a transition keyed by the parent shape,
name, and flags. Objects built in the same order can share the resulting shape.

Including the flags in that key matters: every instance of a class installing
the same private field can share a shape, while the same key added with
different attributes gets its own.

Some operations need a shape that belongs to one object alone.
`make_shape_private` flattens the chain into a standalone shape and leaves it
out of the transition table, which is how `seal`, `freeze`, and per-property
flag edits avoid leaking into every object sharing the shape.

`has_nondefault_flags` remains set after the first non-default descriptor.
Before that, `get_prop_flags` returns the default flags without walking the
shape chain.

### Inline caches

Three caches sit above property lookup:

- **`ICEntry`**, one per `GETPROP`/`PUTPROP` site, holding the last resolved
  shape, index, and a direct pointer to the value. Own-data reads use the
  current receiver's indexed slot after validating shape and generation.
  Other paths require the recorded owner's storage pointer to match.
- **`VarICEntry`** caches resolved environments and binding slots. Introducing
  an eval binding clears these caches because it can shadow an owner without
  changing the chain head. Numeric `PUTVAR_SNAP` stores validate their saved
  owner, shape, recycle epoch, writable flag, and value type before writing;
  the right-hand side cannot redirect a saved reference.
- **The megamorphic cache** on the heap, shared across all sites and keyed by
  `(shape_id, key)`. It is a lossy single-slot table, so a collision simply
  evicts, and it caches own properties only, since it cannot detect a change to
  an intermediate prototype.

### Bytecode

The compiler emits fixed-width 32-bit instructions for a register machine. An
8-bit opcode occupies the low byte, and the remaining 24 bits are read in one of
five layouts: three 8-bit operands (`ABC`), an 8-bit `A` plus a 16-bit `BC`, an
8-bit `A` plus a signed bias-encoded `sBx`, or a full 24-bit operand, signed or
unsigned.

A `CompiledFunction` is the immutable template many closures can share. It
carries the instruction stream, the constant pool, templates for nested
functions, the register budget, source metadata, and the inline-cache arrays,
which run parallel to the instruction stream so `ic_entries[pc]` serves
`code[pc]`.

`FuncFlags` records what the compiler learned about the body, and several flags
drive real fast paths. `needs_env` is the clearest: when it is false, the call
path skips creating a function scope entirely and reuses the captured parent
environment.

### Environments

A runtime scope is an `EnvRecord` with a parent, a bindings object, a heap
pointer, and flags for scope kind and GC state. The allocator groups records
into blocks of 64 cells.

Environment records have no reference count. Each tracing collection flips an
epoch bit; `mark_env_chain` stamps reachable records and marks their bindings
objects. The pool sweep recycles records with the old epoch and can release an
empty block. Environment allocation has its own collection budget so temporary
scope chains do not accumulate indefinitely.

Uninitialized `let` and `const` bindings hold a **TDZ sentinel**, encoded as
`undefined` with a non-zero payload so it is distinguishable from real
`undefined` without costing a tag. Reading one throws a `ReferenceError`.

Assignment goes through `env_try_put_lex`, which walks the lexical chain once
and returns what happened: updated, unbound and so the caller should try the var
environment, a `const` violation, or a TDZ read.

A `with` body pushes a third kind of record: one marked `is_with`, whose
bindings object is the operand. Name resolution consults that object's `has`
trap and `@@unscopables` before falling through to the declarative chain, so a
name in the body never resolves at compile time. The compiler therefore withholds
the register fast paths there and routes every read, write and increment through
the environment.

## Memory: the heap, the collector, and strings

`Heap` owns runtime objects, strings, shapes, the module cache, and the job
queue. A VM uses one heap; `Heap.reset()` prepares it for another VM after a
run.

### The allocator layer

The heap exposes allocator hooks (`alloc_func`, `realloc_func`, `free_func`, and
`fatal_func`) with an opaque user pointer. Embedders can provide them; default
hooks use the C3 allocator. Memory obtained through a hook must be released
through that heap's matching hook, including during teardown. `gs_release()`
takes an explicit heap for this reason.

Six `FixedBlockPool` allocators serve object classes with similar storage needs:

| Pool | Classes |
|------|---------|
| plain | `OBJECT`, `JSON`, `REFLECT`, `WEAKREF`, `FINALIZATION_REGISTRY` |
| array | `ARRAY`, `ARGUMENTS`, `MAP`, `SET`, `WEAKMAP`, `WEAKSET` |
| gs | `GETTER_SETTER` |
| small | boxed primitives, errors, generators, buffers, views, iterators, `REGEXP`, `PROMISE` |
| func | `FUNCTION`, `PROXY` |
| big | `ITERATOR_HELPER` and Temporal classes |

Each class reports its own logical size through `alloc_size_for_class()`, even
when its pool block is larger. `pool_for_class()` selects the physical pool.
The four collection classes keep their lookup index in a class payload, so
other objects do not pay for it in the common header. Pool pages fit within a
64 KB allocator size class. The small pool uses a measured 152-byte stride:
its smaller 144-byte layout slowed a retained-Date workload.

### Two collectors, one heap

Reference counting releases objects when their last owned reference goes away.
Tracing reclaims unreachable cycles whose members still have nonzero counts.
Refcounted objects leave `heap_allocated` before the tracing sweep can see them.
Strings use their intern table or non-interned registry rather than that object
list; their sweeps also use reachability.

During `Heap.sweep()`, teardown of one dead object must not decref another
dead object that the sweep may already have released. The `sweeping` flag
guards that case.

Marking is tri-colour with an explicit gray stack rather than recursion, so a
deep object graph cannot overflow the C stack. `mark_roots()` seeds it, and
`drain_gray()` walks to the transitive closure.

### Roots

Much of what stays alive sits outside the object graph:

- registered GC roots and every built-in prototype and intrinsic
- the VM value stack, scanned from `valstack_base` to the live top pointer
- the microtask queue, whose handler, argument, and downstream promise are held
  nowhere else until the job runs
- constant pools and inline-cache entries of every `CompiledFunction`, which live
  in their own tracking array rather than the GC heap. Property IC entries root
  their proto object; variable IC entries hold only their key strongly, and are
  pruned after marking reaches a fixed point rather than rooted
- environment records, reached through each activation's scope chains, the VM's
  global records, every cached module's environment, a catcher's saved lexical
  scope, native scoped roots, and the internal `ENVREF` register snapshots
- the symbol registry, the built-in string cache, and the cached well-known
  symbols
- generator state, including the in-flight async-generator request
- `ModuleDef` entries, which sit in a malloc'd cache the sweep never scans

### Temproots and safepoints

A freshly allocated object is anchored only in a C3 local, where the mark phase
cannot see it. `alloc_object()` therefore sets a *temproot* flag, and a
collection that happens outside a safepoint marks these roots and traces their
outgoing edges so in-flight allocations and their children survive. The mark
reset pass queues pinned objects on the gray stack; traversal starts after all
marks have been reset. This uses the existing heap walk.

Clearing them is safe only at a genuine safepoint with no native builtin frame on
the stack. A builtin that allocates a result and then re-enters the VM, to call a
user callback or a getter, holds that result in a raw local while the nested
execution reaches safepoints of its own. `native_frame_depth` tracks this and
vetoes both the temproot clear and the string sweeps. Sweep clears reachability
marks but preserves pins: appearing in a callback's registers does not end a
native local's lifetime. Pins expire in the next quiescent safepoint's mark reset
pass. A collection that retains pins records a separate quiescent request;
leaving the outermost native frame schedules it for the next VM safepoint, after
the return value is anchored. Callback collections can reset the allocation
budget without postponing pin expiry across successive native calls.

The sweep itself runs in three phases so that no teardown can touch memory
another teardown already freed:

1. unlink every dying node onto a private list, freeing nothing
2. run each node's teardown while all of that memory is still valid
3. release the header memory

### Strings

The string table is open-addressed with linear probing and tombstones, hashed
with FNV-1a seeded per heap. Taking a slot makes the table an owner: the string
is marked interned and increfed for the table's reference.

Strings longer than `MAX_INTERN_BYTES` (256) and concatenation results can
remain non-interned until a property-key operation needs a canonical pointer.
A uniquely owned concatenation accumulator can grow geometrically. The
non-interned string registry covers these strings for collection and teardown.
Each entry records a one-based index, allowing removal by swapping in the last
entry; zero means unregistered. Compaction updates surviving indices.

The intern table owns a reference; the non-interned registry does not. A low
refcount alone cannot decide that an interned string is dead because property
tables and caches can borrow its key pointer. Both sweeps therefore account
for reachability.

Both sweeps run only when `string_sweep_safe` is set, since a GC can trigger from
any allocation, including one made while an opcode holds a freshly interned
string that nothing roots yet.

Two caches sit alongside: pre-interned built-in strings, and `HString*` for the
integer keys 0 to 255. Both are *pinned*, so refcounting and sweep never free
them and incref and decref against them do nothing.

### Shapes and inline caches

The megamorphic property cache maps `(shape_id, key)` to a resolved
`(proto, prop_idx, value)`, shared across all call sites to skip repeated
prototype-chain walks. It is a lossy single-slot table, so a collision simply
evicts. It is allocated apart from the `Heap` struct to keep that struct small.

Pool allocators restart at the same addresses, so a stale cache entry can be
hit by a new object at a recycled address and return the wrong value. That is
why `Heap.reset()` clears this cache.

### Generators and async state

A suspended generator's execution context lives in a `GeneratorState`: saved
registers, program counter, environments, catcher chain, and the resume protocol
values. It is not an `HObject`, so its lifetime is managed by a small refcount
maintained by `gs_acquire()` and `gs_release()`.

That count is the *only* ownership signal.
Several `HObject`s can hold the same state: the generator instance, plus every
async reaction closure that parks the pointer in its `var_env`. The sweep tears
all of them down in a single pass, so deciding ownership by reading a field of
the state would race the siblings in that same pass. Counting makes the last
teardown, in whatever order the sweep reaches them, the one that frees.

The GC has to know about two back-edges that run against the usual direction:

- **The generator instance.** Normally the instance marks its state. But an async
  generator driven only by its own machinery has no JS-visible reference left,
  since `g().next()` drops the instance immediately and the only remaining path
  is a reaction closure on the awaited promise. Without `gs.gen_obj` the instance
  is swept while its request queue is still being serviced.
- **The in-flight request.** Once dequeued, the request is no longer on the
  queue the mark phase walks, so `gs.ag_current_request` is its only root until
  it settles.

Async generators queue concurrent `next`, `return`, and `throw` calls as
`AsyncGenRequest` records, each with its own promise, drained FIFO. Whether a
value coming back from the body settles the current request depends on how the
body suspended, which the `AWAIT` and `YIELD` opcodes record in
`ag_suspend_kind`: a `yield` settles, while an internal `await` leaves the
promise alone for a microtask resume to re-drive.

### Microtasks

Promise reaction jobs are held in a flat queue of `(handler, argument,
downstream)` triples, drained after each top-level script and after
`vm_call_fn_impl` returns. The drain walks a read cursor forward rather than
snapshotting the count, so jobs enqueued by a running handler append past the
cursor and run in the same drain, which is the ordering the spec requires.
`microtask_count` keeps counting the whole queue while this happens: resetting
it early would let new jobs overwrite the in-flight batch from slot 0 and hide
queued entries from the collector.

### Tearing down and reusing a heap

`Heap.destroy()` releases everything and frees the heap struct.
`Heap.reset()` does the same work but keeps the struct and its backing arrays,
leaving it ready to host a fresh VM. Reset exists because repeated
create/destroy cycles fragment the allocator and grow RSS, which matters for
batch runs.

Both enter a *teardown mode* by clearing the active heap, which makes
`hobject_free()` skip its refcount loop. Teardown frees everything directly, and
mixing decref with the string table's tombstone deletion would corrupt the table
for the sweep that follows.

Reset has one extra obligation: it decrefs string and bigint values held by live
objects *before* entering teardown mode, since bigint boxes have no list of their
own to drain later. It then clears every pointer that could outlive the freed
memory, including cached symbols, the megamorphic cache, generator init state,
and the environment pool, whose cells hold bindings pointing into the heap that
was just released. Pool teardown lives in `env.c3` so destroy and reset share one
block walk.

## Builtins and modules

### One declaration per builtin

Every native function has an entry in the `Builtin` enum, which carries its
JavaScript name, its arity, and a pointer to the implementation as associated
values. The dispatch table and the metadata lookup are both generated from that
one declaration, so adding a builtin means adding one line.

`builtin_fn_index` is a runtime-only field on the function object and is never
written to bytecode or disk, which means members can be appended freely with no
stable numbering to preserve.

A builtin receives a `BuiltinContext`: the VM, the register window, the argument
count, `this`, the result slot, and whether it was called as a constructor. Two
fields exist for `Function.prototype.call` and `.apply`, which rewrite their own
arguments and ask the CALL handler to re-dispatch rather than calling through
themselves.

### Lightfuncs

Most builtins are reachable without a heap object at all. A **lightfunc** is a
`TVal` whose payload is a function pointer, so `Math.max` costs no allocation.
`.name`, `.length`, and `.prototype` are synthesized from the enum metadata on
demand.

Deleting one of those virtual properties has to be recorded somewhere, since
there is no object to delete from. The heap keeps a bitset, three bits per
builtin index, for exactly that.

A lightfunc is promoted to a real `HObject` the moment code needs object
identity: assigning an own property, using it as a `WeakMap` key, or anything
else that must survive a round trip.

### Promises and the job queue

A promise's state, result, and reaction list live in its `HObjectExtra` union
slot, not in its property table, so user code cannot reach them by name. The
reaction chain links through a hidden property rather than `HeapHeader.next`,
which threads the unrelated GC list.

Reactions become microtasks in the heap's queue.

Async functions attach to this machinery directly. `AWAIT` suspends the
generator-style frame and schedules its resumption as a promise reaction, so the
microtask queue drives every async function's continuation.

### Iterators

The iterator protocol appears in three layers. Ordinary iterators are objects
with `next`; `%IteratorHelperPrototype%` backs the lazy `map`, `filter`, `take`,
`drop`, and `flatMap` results; and `%AsyncFromSyncIteratorPrototype%` adapts a
sync iterator for `for await`.

`ITER_NEXT_FAST` consumes Map, Set, and String values through a shared step
helper when the resolved `next` is the matching intrinsic. Public `.next()`
wraps the same step in an IteratorResult object. Custom methods retain the
protocol path; collection growth, exhaustion, and string code points use
the same stepping rules on both paths.

The helpers are not generators here, though the spec describes them as such. Each
is a small state machine driven off the underlying iterator's `next`, which
avoids a generator frame per helper in a chain. Only `flatMap` needs extra state,
for the inner iterator it is currently draining.

### Typed arrays and buffers

An `ArrayBuffer` owns a backing store and an intrusive list of the views over it,
so detaching or resizing can find every view that must be updated. A detached
buffer is marked with a sentinel byte length, which is distinct from a live
zero-length one.

Resizable buffers (ES2024) make length dynamic. A view created without an
explicit length tracks its buffer, so its effective length is recomputed on every
access rather than read from the view.

The subtle part is ordering. Writing to a typed array coerces the value first,
and that coercion can run user code that resizes or detaches the buffer, so
bounds are rechecked after coercion rather than before.

### Proxies

A `Proxy` holds its target and handler, both nulled on revocation. Callable
proxies dispatch through the ordinary builtin path by overlaying
`builtin_fn_index` at the same offset the function struct uses.

Because a proxy can appear anywhere on a prototype chain, the chain walkers in
`hobject.c3` need to reach the trap machinery in the builtins layer, which would
be a circular dependency. The heap holds function pointers, set at VM creation,
that bridge the two.

### The module system

A module moves through compile, resolve, link, execute, and namespace
construction, with `ModuleStatus` recording where it is. That status is also how
cycles are handled: reaching a module already `LINKING` or `EVALUATING` means a
cycle, and the recursion stops rather than looping.

Linking is what makes exports live. Rather than copying values, an importing
module's binding is an accessor that reads through to the exporting module's
environment slot, so a later assignment in the exporter is visible to every
importer, and reading before initialization still throws on TDZ.

Top-level `await` makes evaluation asynchronous, so a module carries a persistent
evaluation promise that settles once, whether the body finished synchronously or
suspended. A module waiting on an async dependency chains onto that promise
instead of polling, which is necessary because the wait often happens inside a
microtask drain that cannot pump itself.

Host integration goes through `ModuleHostHooks`: specifier resolution, source
loading, and load and evaluation callbacks, so an embedder decides what a
specifier means.
