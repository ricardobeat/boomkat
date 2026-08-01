# Engine architecture

A guide to how this JavaScript engine fits together: what the major pieces are,
how a value moves through them, and which invariants hold everything in place.
It is written for someone reading or changing the code, so it concentrates on
what is hard to work out from any single file.

The engine is a register-based bytecode interpreter written in C3, with a
single-pass compiler, a hybrid refcounting and mark-and-sweep collector, hidden
classes with inline caches, and ES2015-and-later features including generators,
async functions, proxies, typed arrays, and ES modules.

## How a script runs

Before the details, the shape of the whole thing. Running `f("hi")` from a file
involves every layer:

1. **Compile.** `compile()` sets up a `CompilerContext` and parses. The lexer
   hands over tokens on demand, and bytecode is emitted as each construct is
   recognized. There is no AST. Function bodies become nested
   `CompiledFunction`s, string literals are interned into the constant pool, and
   `finish()` runs the fusion and move-elimination passes over the finished
   instruction stream.

2. **Set up.** The VM pushes an activation for the top-level code, pointing its
   register window into the valstack and its environment at the global scope.

3. **Execute.** `Vm.run` loads the frame into a `Dispatch` struct and enters the
   inner loop. `GETVAR` resolves `f` through an inline cache; `LDCONST` loads
   the interned `"hi"`; `CALL` finds a plain compiled function, pushes an
   activation, and signals a restart so the outer loop reloads state for the new
   frame.

4. **Allocate.** Anything the body constructs comes from the heap: an object
   gets a pooled `HObject` header, a shape describing its layout, and a temproot
   flag so a collection running before it is anchored cannot free it.

5. **Collect.** Refcounting reclaims most values as registers are overwritten.
   At a backward jump the VM may reach a safepoint, where mark-and-sweep runs to
   collect the cycles refcounting cannot.

6. **Drain.** When the script returns, the microtask queue runs, settling
   promises and resuming any async function that was awaiting.

Each section below expands one of those steps.

## Where the code lives

| Path | What is in it |
|---|---|
| `src/lexer.c3` | Tokenizer, driven on demand by the compiler |
| `src/compiler/` | Single-pass parser and code generator, plus the optimization passes |
| `src/bytecode.c3` | Instruction encoding, the opcode set, `CompiledFunction` |
| `src/vm/` | The dispatch loop, calls, property access, exceptions, generators |
| `src/heap.c3` | Allocation, both collectors, the string table, shapes |
| `src/types.c3` | `TVal` and `HeapHeader`, the two universal representations |
| `src/hobject.c3` | Object layout, property storage, shapes, inline caches |
| `src/hstring.c3` | Immutable interned strings and the CESU-8 encoding |
| `src/env.c3` | Environment records and the scope chain |
| `src/module.c3` | The ESM lifecycle: resolve, link, evaluate |
| `src/builtins/` | The standard library, one file per area |
| `cli/` | The `duktape_c3` and debug binaries, and the test262 runner |

## From source to bytecode

### The lexer

The lexer is on-demand rather than a separate pass: the compiler asks for the
next token as it parses. That matters because JavaScript cannot be tokenized
context-free. Whether `/` starts a regexp or is division depends on what came
before, and a `}` may close a block or resume a template literal.

Automatic semicolon insertion needs line-break information, so the lexer records
whether a newline preceded each token. It also tracks template-substitution
nesting, since a `}` inside `${...}` is not a block close.

Lookahead is the other reason the two stay coupled. Deciding whether `async (x)`
begins an async arrow or a call to a function named `async` requires peeking past
several tokens, and `tokens.c3` holds those speculative helpers. They restore
lexer state on a miss, so the peek is invisible to the parse.

### The compiler

Parsing and code generation happen together in one pass. There is no AST: the
parser emits bytecode as it recognizes each construct, which keeps compilation
fast and memory use flat, and shapes everything else about the design.

`CompilerContext` holds the state for one function being compiled: the code
buffer, constant pool, register allocator, scope stack, and the flags that end up
in `FuncFlags`. Nested functions get their own context, and the inner
`CompiledFunction` is added to the parent's `inner_funcs`.

Working without an AST does cost something. Some constructs are only recognizable
after their opening tokens have been consumed and code emitted, so the compiler
either patches emitted instructions later or re-parses from a saved lexer
position. Arrow functions and destructuring assignment both use the second
approach: `(a, b)` might be a parenthesized expression or an arrow's parameter
list, and `[a, b] = c` is an array literal until the `=` arrives.

### Registers and scopes

Registers are allocated as a stack. Expressions take temporaries from the top and
release them in reverse, while parameters and locals get permanent slots for the
function's lifetime.

Some sequences need a register freed in the middle of an expression, which the
straightforward stack discipline cannot express without stranding higher slots.
`regalloc.c3` documents where that happens and how those cases are handled.

Scopes are a compile-time stack mirroring the runtime environment chain. The
compiler resolves a name to a register where it can, and falls back to an
environment lookup where it cannot. `needs_env` records the outcome for the whole
function: when it stays false, the VM skips creating a scope on every call, which
is one of the larger wins available to a one-pass compiler.

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

After a function body is compiled, `finish()` runs several passes over the
instruction stream. Their order is deliberate and documented in `fusion.c3`:

1. `GETVAR` + `INC`/`DEC` + `PUTVAR` fuses into `INC_VAR`/`DEC_VAR`.
2. `LDCONST` + `GETPROP` fuses into `GETPROPC`.
3. A comparison feeding a branch fuses into a jump form such as `JMP_LT`. Loose
   `EQ` and `NEQ` are excluded, since they coerce and can throw.
4. Copy propagation substitutes through `LDREG` moves. This must run before any
   pass whose trigger and consumer can be separated by a parser-emitted move.
5. Move elimination removes the moves copy propagation made dead.
6. Peephole cleanup and NOP compaction close the stream up.

Two facts make this safe. Every fusion consumes instructions the compiler itself
emitted in a known shape, and the jump-aware passes maintain a whole-function
bitset of jump targets, so no fusion can span a label another branch lands on.

A separate pass, `prim_globals.c3`, proves that certain globals are never
observed through `eval`, `with`, `delete`, or a getter, which lets global reads
and writes compile to guard-free opcodes.

## The virtual machine

### The dispatch loop

`Vm.run` is a loop inside a loop. The outer one loads all per-frame state into a
`Dispatch` struct: the code base, constant pool, inline-cache arrays, register
base, and program counter. The inner one dispatches instructions.

A JS-to-JS call does not recurse into the interpreter. It pushes an activation
and sets `needs_restart`, which breaks back to the outer loop to reload state for
the new frame. Deep JavaScript recursion therefore costs activation slots rather
than C stack, and `MAX_CALLS` (512) bounds it.

Two invariants keep the inner loop tight. The compiler ends every function with
an explicit `RET`, so there is no fall-off-the-end check, and only the return and
generator opcodes set `halt`, so it is tested at those sites rather than once per
instruction.

Some paths do need real re-entry, and `vm_call_fn_impl` handles them: a builtin
calling back into JS, a getter, a `Symbol.toPrimitive`. These run a nested
`Vm.run`, which is why the VM tracks `run_depth` and why saved frames need
relocating if the valstack moves underneath them.

### Frames

An `Activation` is one call frame: the function, the parent activation, the var
and lex environments, the catcher chain, the program counter, and where in the
valstack its registers start.

Registers are a window into a single growable valstack rather than a per-frame
allocation. That makes calls cheap and makes `ensure_valstack_grow` delicate,
since a realloc invalidates every absolute pointer into it.

Frames also carry the flags that drive spec behaviour: `ACT_FLAG_CONSTRUCT`,
`ACT_FLAG_DERIVED` for a derived constructor's return check,
`ACT_FLAG_THIS_OWNED` when the frame holds a reference to `this`, and
`ACT_FLAG_BORROWED_CALLEE` when the callee was copied from a global binding
without an incref, so the return write-back must not decref it.

The GC's view of a frame is deliberately explicit. `mark_roots` only scans the
valstack up to `valstack_top`, a high-water mark for the deepest frame, so each
live frame's own register span is marked separately, along with the fields that
can be a value's only root: an owned `this`, `new_target`, an async function's
promise, the generator state being resumed, and every in-flight exception parked
in a catcher.

### Calls

`resolve_call_var` picks the path. The fast path is a plain compiled function
that is neither a generator nor a class constructor, which is the common case; it
sets up the activation inline and restarts the outer loop. Everything else,
meaning lightfuncs, builtins, bound functions, generators, and class
constructors, goes through the slower dispatch in `vm_calls.c3`.

Constructors add the `new.target` chain and, for a derived class, the deferred
`this`. A derived constructor starts with `this` in TDZ, and `super()` walks up
the activation chain to find the frame whose binding it must initialize.
Reading `this` before that throws, and returning a non-object non-undefined from
a derived constructor throws too.

### Property access

`GETPROP` and `PUTPROP` try, in order: the per-site inline cache, the
megamorphic cache, then a full lookup. An IC hit needs the shape to match and the
owner's `prop_alloc` to be unchanged. Fused two-hop forms exist for `a.b.c`, and
string primitives auto-box on the first hop.

Writes are where the exotics live. An array-index write may go to the dense part,
grow it, or fall through to the property table. A `length` write on an array
truncates. A typed-array write coerces the value first, and that coercion can run
user code that resizes or detaches the buffer, so the bounds are rechecked
afterwards.

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

`YIELD` copies the live registers, program counter, environments, and catcher
chain into that state and returns to the caller. `.next()`, `.throw()`, and
`.return()` restore them and resume, with `ResumeKind` telling `YIELD` whether to
return a value, inject an exception, or inject a return.

Restoring the registers takes a reference per heap value, and the copy bypasses
the usual `track_heap_store` accounting while `activation_begin` has just reset
`heap_reg_count`. Both restore sites, in `vm_call_fn_impl` and
`dispatch_calls`, therefore call `track_restored_regs()` to raise the watermark
over the restored window, which keeps the `decref_callee_regs` sweep and the
`vm_mark_activations` scan sound. A bulk register restore added later owes the
same call, or it leaks the references and leaves stale pointer bits for a frame
that reuses that valstack address.

Async functions reuse the same machinery: `AWAIT` is a suspension whose
continuation is a promise reaction, so an async function is a generator whose
resumptions are driven by the microtask queue rather than by user calls.

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

The two sections above described how code is compiled and executed. This one and
the next describe what it operates on: how a value is represented, how an object
stores its properties, and how both are allocated and reclaimed.

### TVal

Every register, property slot, and stack slot holds a `TVal`. The default build
NaN-boxes it into a single 8-byte `ulong`; passing `-D NONANBOX` switches to a
16-byte tagged union with identical semantics, which is useful when debugging.

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
| `0xFFFF` | deleted-slot sentinel |

Two consequences are worth knowing. `set_number` normalizes any NaN it stores to
a canonical positive NaN, because a negative NaN's bits would collide with the
tag range. And the tag layout is deliberate: undefined and null are adjacent so
`is_nullish` is one range check, and numbers and fastints sit below every
pointer tag so `is_numeric` and `is_heap_allocated` are also single comparisons.

**Fastints** are the integer fast path. An integer that fits in 48 bits is
stored as a fastint rather than a double, so integer arithmetic avoids
float round-tripping. `set_fastint_or_number` is the one place that decides,
and arithmetic opcodes write their results through it rather than repeating the
range check.

The `DELETED` tag is internal and never a JavaScript value. It marks an array
slot that was deleted, which the dense array part cannot express with
`undefined` alone.

### HeapHeader

Every collected allocation begins with a `HeapHeader`: flags, a refcount, and
the two list pointers that thread the heap together. `HString` and `HObject`
each define their own flags bitstruct whose low 7 bits mirror the header's, so a
raw cast from either to `HeapHeader*` reads the correct type and GC bits.

A refcount of `STRING_PINNED_REFCOUNT` marks a pinned string, on which incref
and decref do nothing. That sentinel is only meaningful together with
`is_string()`, since an object could legitimately reach the same count.

### HString

Strings are immutable, and their bytes live in the same allocation as the
header, so `get_data()` is pointer arithmetic. A NUL always follows the last
byte, letting the data pointer go straight to a C API.

The invariant that matters most: **string equality is pointer identity**.
Interning is what makes that true, so any path that produces an `HString` which
escapes without interning will silently break strict equality, `indexOf`, and
property-key lookup. The exception is deliberate: strings over
`MAX_INTERN_BYTES` are left un-interned and compared by content, which
`equals_hstring` handles by falling back when either side is not interned.

Internally the bytes are **CESU-8**, not standard UTF-8. An ECMAScript string is
a sequence of UTF-16 code units, so every astral codepoint is split into its two
surrogate halves and each half encoded separately as a 3-byte sequence. That is
what makes `"\u{1F600}".length === 2` come out right, and it lets lone
surrogates round-trip, which the spec permits. `normalize_to_cesu8` is the only
normalization point, called at intern time so one logical string cannot reach
the table under two different encodings. `write_cesu8_as_utf8` inverts it at
every host-visible boundary, so nothing outside the engine sees a surrogate
half.

Character indexing is by UTF-16 code unit and cached. Each string remembers one
`(char_offset, byte_offset)` cursor, and `char_offset_to_byte_offset` scans from
whichever of the string start, the string end, or that cursor is nearest.
Because strings are immutable, the cache is only ever updated, never
invalidated. ASCII strings skip all of it: one byte is one character.

### HObject

An object is a `HObjectBase` prefix followed, for most classes, by an
`HObjectExtra` union holding subtype fields. `flags.obj_class` says which
variant is live, and `alloc_size_for_class` decides how much space to allocate:

- `OBJECT` and `ARGUMENTS` need no union at all.
- `ARRAY` keeps its `array_length` in the union's first four bytes.
- Everything else, `ERROR` and `PROXY` included, gets the full union.

Every class but `GETTER_SETTER` also carries `INLINE_PROPS` (4) property slots
at the tail of its allocation, so an object with few properties needs no
separate property block at all.

**Property storage** has three layers, and a lookup tries them in order:

1. **The dense array part**, for integer-indexed properties. It holds bare
   `TVal`s with no per-element flags, and `undefined` doubles as the hole
   sentinel. `dense_index_ok` keeps it dense only while an index stays near the
   current size, so `a[2**31] = x` cannot allocate billions of empty slots.
2. **A hash table**, built once an object reaches `HASH_MIN_PROPS` (8)
   properties. It maps a key pointer to an index in the value array.
3. **A linear scan of the shape chain**, which is what small objects use.

Because array builtins like `push` write only to the dense part while `PUTPROP`
writes the property table, `put_prop` syncs numeric-string keys into both.

### Shapes

Names and flags do not live on the object. They live in a shared `Shape`, and
the object stores only values. Adding a property moves the object from a parent
shape to a child, so shapes form a transition tree, and a transition table keyed
on `(parent, key, flags)` makes objects that add the same properties in the same
order converge on one shape.

Including the flags in that key matters: every instance of a class installing
the same private field can share a shape, while the same key added with
different attributes gets its own.

Some operations need a shape that belongs to one object alone.
`make_shape_private` flattens the chain into a standalone shape and leaves it
out of the transition table, which is how `seal`, `freeze`, and per-property
flag edits avoid leaking into every object sharing the shape.

One optimization is worth calling out because it changes the complexity of
ordinary reads. `has_nondefault_flags` is set the moment any non-default
property is installed and never cleared. While it is false, `get_prop_flags`
returns the default descriptor in O(1) instead of walking a shape chain that,
for a dictionary-mode object, is one node deep per property.

### Inline caches

Three caches sit above property lookup:

- **`ICEntry`**, one per `GETPROP`/`PUTPROP` site, holding the last resolved
  shape, index, and a direct pointer to the value. A hit requires the shape to
  match and the owner's `prop_alloc` to be unchanged, which is one pointer
  comparison.
- **`VarICEntry`**, one per `GETVAR`/`TYPEOFIDENT` site, caching the resolved
  environment record so the scope-chain walk can be skipped.
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

A scope is an `EnvRecord`: a parent pointer, a bindings object, and two booleans
marking whether it is declarative and whether it is a function boundary. Records
come from a pool, since they are created and discarded constantly.

Uninitialized `let` and `const` bindings hold a **TDZ sentinel**, encoded as
`undefined` with a non-zero payload so it is distinguishable from real
`undefined` without costing a tag. Reading one throws a `ReferenceError`.

Assignment goes through `env_try_put_lex`, which walks the lexical chain once
and returns what happened: updated, unbound and so the caller should try the var
environment, a `const` violation, or a TDZ read.

## Memory: the heap, the collector, and strings

Everything the engine allocates at runtime belongs to a `Heap`. One heap holds
the object graph, the string tables, the shape system, the module cache, and the
microtask queue, and it owns the allocator those all draw from. A VM is created
against a heap, and a heap can outlive one VM and host another, which is what
`Heap.reset()` exists for.

### The allocator layer

The heap never calls `malloc` directly. It holds four function pointers set at
creation time (`alloc_func`, `realloc_func`, `free_func`, `fatal_func`), each
taking an opaque `udata` pointer, so an embedder can supply its own allocator.
Passing null selects defaults that route through the C3 thread allocator.

This matters more than it looks. Anything allocated through the heap must be
released through the same heap, including during teardown. `gs_release()` takes
an explicit heap pointer for exactly this reason: teardown clears the active-heap
global but still has to free through the heap's own allocator, and releasing to
libc instead would be a cross-allocator free.

On top of that sit three `FixedBlockPool` allocators for HObject headers, one per
size class, which avoid a malloc per object:

| Pool  | Classes                                | Why |
|-------|----------------------------------------|-----|
| plain | `OBJECT`, `ARGUMENTS`                  | no `HObjectExtra` needed |
| array | `ARRAY`                                | `array_length` lives in the union |
| func  | everything else, including `ERROR` and `PROXY` | carries subtype fields |

`alloc_size_for_class()` in `hobject.c3` is the authority on which class goes
where.

### Two collectors, one heap

The engine reclaims memory two ways at once, and knowing which one owns a given
object is the key to reading the memory code.

**Reference counting** handles the common case. Every `HeapHeader` carries a
refcount; `decref()` frees the object when it hits zero, unlinking it from the
`heap_allocated` list on the way. Strings are purely refcounted and are never on
that list at all.

**Mark-and-sweep** exists to collect what refcounting cannot: cycles. An object
in a cycle keeps a non-zero refcount forever, so the tracing collector finds the
objects no root can reach and frees them regardless of count.

The two interact carefully. Objects freed by refcounting are already off the
list, so the sweep never sees them. Conversely, while `Heap.sweep()` runs, the
`sweeping` flag makes `decref()` skip references into unmarked nodes: a dying
object's teardown can reference a sibling that the same sweep is also collecting,
and touching its header would be a use-after-free.

Marking is tri-colour with an explicit gray stack rather than recursion, so a
deep object graph cannot overflow the C stack. `mark_roots()` seeds it, and
`drain_gray()` walks to the transitive closure.

### Roots

Reachability is only as good as the root set, and a surprising amount lives
outside the object graph:

- registered GC roots and every built-in prototype and intrinsic
- the VM value stack, scanned from `valstack_base` to the live top pointer
- the microtask queue, whose handler, argument, and downstream promise are held
  nowhere else until the job runs
- constant pools and inline-cache entries of every `CompiledFunction`, which live
  in their own tracking array rather than the GC heap
- the symbol registry, the built-in string cache, and the cached well-known
  symbols
- generator state, including the in-flight async-generator request
- `ModuleDef` entries, which sit in a malloc'd cache the sweep never scans

### Temproots and safepoints

A freshly allocated object is anchored only in a C3 local, where the mark phase
cannot see it. `alloc_object()` therefore sets a *temproot* flag, and a
collection that happens outside a safepoint keeps temproots set so in-flight
allocations survive.

Clearing them is safe only at a genuine safepoint with no native builtin frame on
the stack. A builtin that allocates a result and then re-enters the VM, to call a
user callback or a getter, holds that result in a raw local while the nested
execution reaches safepoints of its own. `native_frame_depth` tracks this and
vetoes both the temproot clear and the string sweeps.

The sweep itself runs in three phases so that no teardown can touch memory
another teardown already freed:

1. unlink every dying node onto a private list, freeing nothing
2. run each node's teardown while all of that memory is still valid
3. release the header memory

### Strings

String equality in this engine is pointer identity, which makes interning an
engine-wide invariant rather than an optimisation. Any path that produces an
`HString` which escapes without interning will silently break `indexOf`, strict
equality, and property-key lookup.

The string table is open-addressed with linear probing and tombstones, hashed
with FNV-1a seeded per heap. Taking a slot makes the table an owner: the string
is marked interned and increfed for the table's reference.

Strings longer than `MAX_INTERN_BYTES` (256) are deliberately *not* interned.
They are almost never property keys, and interning them piles dead strings into
the table until the next GC, which gives O(n^2) growth in loops like `s += chunk`.
Because such a string is in neither the string table nor `heap_allocated`, a
separate **large-string registry** tracks it so the collector and teardown can
still find it. Each string records its own slot index, so removal is an O(1) swap
with the last element.

That difference shapes how each is swept. An interned string can be freed when
only the table still holds it, but a refcount of 1 is not enough on its own,
because property tables and IC entries hold keys without taking a reference:
reachability decides. The registry holds no reference at all, so for large
strings reachability is the whole test, which makes that pass a backstop for a
refcount that was never decremented.

Both sweeps run only when `string_sweep_safe` is set, since a GC can trigger from
any allocation, including one made while an opcode holds a freshly interned
string that nothing roots yet.

Two caches sit alongside: pre-interned built-in strings, and `HString*` for the
integer keys 0 to 255. Both are *pinned*, so refcounting and sweep never free
them and incref and decref against them do nothing.

### Shapes and inline caches

Objects that gain properties in the same order share a hidden class, or *shape*.
A transition table maps `(parent_shape_id, key, flags)` to a child shape id, so
two objects taking the same path converge on one shape. The flags are part of the
key: every instance of a class installing the same private field can share a
shape, while the same key installed with different attributes needs its own.

Above that sits a megamorphic property cache mapping `(shape_id, key)` to a
resolved `(proto, prop_idx, value)`, shared across all call sites to skip
repeated prototype-chain walks. It is a lossy single-slot table, so a collision
simply evicts. It is allocated apart from the `Heap` struct to keep that struct
small.

One consequence worth knowing: `Heap.reset()` must clear this cache. Pool
allocators restart at the same addresses, so a stale entry can be hit by a new
object at a recycled address and return the wrong value.

### Generators and async state

A suspended generator's execution context lives in a `GeneratorState`: saved
registers, program counter, environments, catcher chain, and the resume protocol
values. It is not an `HObject`, so its lifetime is managed by a small refcount
maintained by `gs_acquire()` and `gs_release()`.

That count is the *only* ownership signal, and the reason is worth stating.
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
`microtask_count` has to keep counting the whole queue while this happens:
resetting it early would let new jobs overwrite the in-flight batch from slot 0
and hide queued entries from the collector.

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
and the environment freelist, whose nodes hold bindings pointing into the heap
that was just released.

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

Reactions become microtasks in the heap's queue, drained after each top-level
script and after `vm_call_fn_impl` returns. The drain walks forward with a cursor
so jobs enqueued by a running handler execute in the same drain, which is the
ordering the spec requires.

Async functions attach to this machinery directly. `AWAIT` suspends the
generator-style frame and schedules its resumption as a promise reaction, so the
microtask queue drives every async function's continuation.

### Iterators

The iterator protocol appears in three layers. Ordinary iterators are objects
with `next`; `%IteratorHelperPrototype%` backs the lazy `map`, `filter`, `take`,
`drop`, and `flatMap` results; and `%AsyncFromSyncIteratorPrototype%` adapts a
sync iterator for `for await`.

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

