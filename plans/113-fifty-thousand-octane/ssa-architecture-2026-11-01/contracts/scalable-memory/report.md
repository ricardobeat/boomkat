# Scalable SSA memory and recovery contracts

The full decoded tier now lowers dense numeric elements, eight typed-array classes,
and ordinary numeric own fields through explicit SSA receiver/address/load/store
nodes. It does not use the old eight-entry prepared memory table. Each access
checks live storage; fields check the live shape generation. Uncommon objects,
slots, coercions and descriptors recover before the unperformed opcode.

The embedding harness proves WIDE accesses through the actual function gateway:
304 registers, two native access sites, zero legacy memory descriptors and zero
property helpers, for dense arrays and all eight typed-array classes. The field
consumer has 156 words, three native accesses and no helpers. Accessors and
read-only fields verify fallback semantics. The callback consumer has four native
accesses plus a real generic callback; ASan records 594 helper calls and 589
native continuations including deliberate throwing/hole cases.

## Bytecode and native code

`callback-bytecode.txt` contains a 162-word function. PC 3 loads the element,
PC 7 calls the callback, PC 8 reloads the element, and PC 14 stores the update.
The callback adds a named property, moving inline array storage, and mutates the
current element. Separate cases throw or delete the element.

`callback-native.asm` is the actual 6,620-byte SSA body. The callback helper is
called at offset 0x1044. Offset 0x1048 branches on its outcome; completed calls
restore typed homes and continue. At 0x1100 the actual receiver is reloaded;
0x1138/0x1144 read live bounds, and 0x1150 reloads property storage. The inline
versus external storage branch then derives the new element address and loads it
at 0x1184. Thus the path demonstrably does not use the pointer from before the
callback. The common deopt call at 0x19c0 publishes frozen sparse locations.

## Validation

- 53 fixtures match interpreter, JIT and stress modes (see differential.json).
- Full ARM64 embedding passes under ASan, including the callback consumer.
- Full x64 embedding passes, including WIDE dense/typed/field paths.
- Shared deopt reduces the same 714-word/310-register body from 1,304,028 to
  42,936 native bytes. Both preserve 153 edge copies and 160 native entries.
- A 605-word acyclic WIDE-call body completes 128 native helper continuations.

Source/configuration boundaries are recorded in metadata.json. This is mechanism
and correctness evidence, not a throughput claim or completion of plan 113.
Effectful inlining, actual LICM and range/bounds proof consumers remain underway.
