# 092: Compiler fixed limits and VM soundness

Open bugs found while auditing the compiler's fixed-size tables. They are listed in fix order:
memory safety first, then silent wrong behaviour, then spurious errors. Each fix gets its own commit
and a check in `test/compiler_capacity.js`.

Already fixed: destructuring patterns past 64 bindings (f284b541), parameter defaults past 32
(d021f058), buffers leaked on a compile error (14a85256), class methods past 32 (6a2f4f36).

## Data structures

- `List{T}` for every table used as a stack or append log: loop, label, `try`/`finally`,
  private-name scopes, loop-head names, switch and jump-patch tables, `prologue_octal` (cleared when
  the prologue ends). Allocated in `init()`, freed in `cleanup()`, which runs through `defer`.
- `HashSet{uint}` keyed by the name's constant-pool index for duplicate detection (`SeenParams`, the
  lexical-declaration pre-scan). Fall back to a `List{uint}` with a linear scan if the set's setup
  shows up when compiling ordinary code.
- `DString` for names built by concatenation (`inferred_name_buf`, the `bind()` name).
- Not used: `FixedList` and `RingBuffer` keep a fixed capacity; the temp allocator leaves each
  outgrown buffer behind until the pool ends.

## Compiler

1. [x] **Per-iteration environments in `let`/`const` loop heads.** A for-in pattern with 9 or more
   captured names overflows an 8-entry stack array, which is memory-unsafe. Only the first 8 names
   get a fresh binding on each iteration.
2. [x] **Nested control flow.**
   - A `break` inside the 9th nested `try` skips its `finally`.
   - With 17 or more nested loops, `continue outer` breaks; 200 nested loops crash.
   - More than 16 nested labels gives a SyntaxError with no message.
   - The switch and jump-patch tables are fixed-size too.
3. [x] **Deep nesting crashes the compiler.** Guarded by `check_stack()` against the thread's real
   stack bounds (`src/native_stack.c`); deep nesting is now a SyntaxError. Follow-up: one nested
   function level costs about 50 KB of parser frames, partly from whole-`Lexer` copies (4.9 KB) used
   for lookahead, so functions and classes stop at 100-150 levels on an 8 MB stack.
4. [ ] **Strict duplicate parameters.** Duplicates past the 32nd parameter are accepted, and names of 64
   or more characters escape the check (`SeenParams`).
5. [ ] **Nested classes.** 17 or more give a spurious "private name is not declared" error.
6. [ ] **Octal escapes before `"use strict"`.** One that sits more than 16 directives earlier is not
   rejected (the `prologue_octal` ring).
7. [ ] **Long names are cut.** A function assigned to a name over 128 characters gets an empty `.name`
   (`inferred_name_buf`). `bind()` cuts the bound name at 126 bytes and can split a UTF-8 character.
8. [ ] **Remaining fixed-size tables.** Audit the rest; the lexical-declaration pre-scan stops at 64
   names.
9. [ ] **Compiled functions live until heap teardown.** Every successful `eval` run in a loop keeps
   about 10 KB. Freeing them needs function templates to be owned and released, which is an
   architectural change.

## VM

10. [ ] **Reference counts never reach zero for new objects.** An object starts at refcount 1 and gains
    another reference when stored, so reference counting never frees it and only the cycle
    collector does.
11. [ ] **Script mode shares global slots across scripts incorrectly.** A later script can resolve a
    name to a slot another script assigned.
