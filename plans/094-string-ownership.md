# Explicit string ownership

## Requirement

Persistent string references own a counted reference. Temporary views borrow
from a known owner or the active native scope. GC must not free a string held
by an owner, and dead temporary references must not leak strings indefinitely.
The implementation uses C3 distinct types and explicit lifetime operations.

This work is in progress. String reclamation uses reference counts; major
collections still scan the intern table and non-interned registry.
The generational collector's 4 ms pause requirement remains unmet.

## Ownership boundaries

- `hstring::StringRef` is a distinct pointer type. `borrow` exposes a view,
  `set` acquires before releasing the prior owner, and `release` empties the
  owner. `string_ref` constructs an owner for newly initialized storage.
- Shape segments own their keys, including copies made for private shapes.
  Shape cleanup always releases its own segment. Hash indexes borrow from
  the owning shape.
- Property, variable and megamorphic caches own their keys. Shape transition
  entries own their keys. Rehashing transfers entries into the replacement
  table.
- Enumeration snapshots and their de-duplication arrays own keys. Callback,
  deletion and generator suspension cannot invalidate a snapshot's strings.
- String and regexp iterators own their input strings. Primitive wrappers and
  regexp instances release their string payloads on destruction.
- Temporal zone and calendar identifiers use a `StringRef` union member
  selected by the object class. Calendar objects use the pointer member.
- JSON parse records own their values and keys. The input string is retained
  across reviver callbacks. String methods retain converted receivers across
  argument coercion callbacks with a scoped owner and `defer`.
- Global checkpoints acquire both their keys and values. The snapshot stores
  them in one allocation, and traces saved object values.
- Native add-on handles own strings for one call. Payload slots own references
  independently: initialize, store/replace, clear. Add-on ABI version 2 adds
  `value_init` and `value_clear`; the bundled deflate add-on follows this
  contract. Objects in payloads still require `gc_mark`.
- `TVal.set_string_borrowed` builds an argument view. Property stores and C
  API value registries acquire their own references; constructing a temporary
  argument must not create an extra reference that no owner releases.

## Result and register boundaries

`BuiltinResultSlot` describes one owned destination. Handlers use context
copy/transfer methods; raw result assignment is a type error. Native getters
keep borrowed receiver slots separate from owned result storage. Callback
results borrow from `vm.return_val`, for both native and bytecode callbacks.
A caller retaining a result across another callback must acquire a reference.

VM primitive stores release the overwritten register's string. Threaded
handlers check release eligibility before mutation and fall back when release
requires freeing a string. Slot transfer clears its source in the transfer
operation. Raw writes at transfer sites require a matching source clear;
borrowed local values use `set_string_borrowed`.

A 10,000-iteration native callback/string-length churn check has a 34,238-byte
peak string allocation, versus 20,880,068 bytes before correcting register
reuse. The direct C3 test asserts at most two 2-KiB strings remain after 1,000
iterations, including JSON parsing, and a quiescent collection. That test
passes with ASAN/GC_VERIFY.
These are targeted lifetime measurements, not a collector pause bound.

## Remaining work

1. Complete the temporary-value audit, especially native builtin results,
   returned TVals, conversion helpers and saved VM state. Some APIs mix
   borrowed copies with references acquired by setters; replace that ambiguity
   with explicit copy/transfer contracts.
2. Audit all persistent string roots, including native registration names,
   compiled constants, module caches and exception state.
3. Validate count-based string reclamation against the full ownership audit.
   GC_VERIFY checks quiescent live string values for a counted owner.
4. Replace full string-table sweeps with a queue of candidates whose counted
   ownership reaches zero. Newly created unowned strings need a defined
   temporary lifetime until the next quiescent boundary. Pending entries
   must remain valid if a native callback acquires or releases references.
5. Validate the removal of string marking and minor string-mark clearing.
   Major scans reclaim strings with no owner beyond the intern table or
   temporary native scope.
6. Run ASAN, GC stress/verifier, NONANBOX, embedding, add-on and conformance
   checks; verify bounded memory under string churn and reprofile scene/VDOM.

## Checks so far

The direct GC test includes private-shape copy/release balance and same-string
replacement when a slot holds the sole reference. The add-on stress test
includes a large string retained solely by a payload. Both pass with ASAN;
the local suite passes 468 scripts and 20 module entries. Rosetta passes
42 tests; golden bytecode passes 28. Targeted String, JSON and Iterator
test262 runs pass 2,030 tests with no failures. GC stress with ASAN and
GC_VERIFY passes 12 lifetime tests. Temporal identifier ownership passes
80 checks under the same instrumentation. These checks cover the exercised
ownership boundaries; distinct types do not enforce linear ownership in C3.
