# 101: Flat AST

A proposal, not scheduled. The compiler parses and emits in one pass, which is why it needs the
token pre-scans plan 100 replaces. This plan describes the alternative that removes the pre-scans
and the duplicated grammar together: parse into a flat, Zig-style AST, resolve scopes over it, then
generate code from the tree. Do plan 100 first. Its atom table and scope index are what this
design's resolve pass produces, so none of that work is lost.

## Constraints from the current front end

- About 36k lines in `src/compiler/`; roughly 24k of them (`expressions`, `statements`, `functions`,
  `class`, `destructuring`) parse and emit together.
- The parser drives the lexer. Regex versus division is decided at parse time (`scan_regexp`), so
  the source cannot be tokenised up front the way Zig's can.
- Backtracking is built in: 29 `save_lhs_snapshot` sites and about 245 pushback references.
- `Function.prototype.toString` needs each function's source span.
- TS type stripping (`ts_skip.c3`) skips type syntax at token level.

## Layout

Parallel columns (`PagedVec{T}`, plan 100), indexed by a `u32` node id with 0 meaning null:

| column | type | meaning |
|--------|------|---------|
| `tag` | `enum NodeTag : char` | node kind |
| `main_tok` | `u32` | source byte offset of the node's main token |
| `lhs`, `rhs` | `u32` each | child ids, an index into `extra`, or an inline payload |

That is 13 bytes per node, plus an `extra` array for variable-arity lists (call arguments, block
statements, parameter lists) and function spans for `toString`. Identifier nodes carry an atom id,
numbers carry the `f64` bits in `lhs`/`rhs`, string literals carry an atom id for the decoded value.
There is no token array: the parser streams tokens, and only the tree is kept.

Children are appended before their parent, so a parent's id is larger than every descendant's. That
gives three properties:

- The resolve pass is one linear sweep over the columns with no recursion. It computes free and
  captured sets bottom-up with the set algebra in plan 100.
- Backtracking is truncation. The columns are append-only, so a speculative parse (arrow versus
  parenthesised expression, destructuring cover grammar) rolls back by resetting the column lengths
  to a saved mark. That replaces the lexer snapshots and most pushback.
- A cover grammar reinterpretation (`({a, b} = x)`, `(a, b) => ...`) is a retag in place plus the
  early-error checks.

## Phases

1. **Parse.** Recursive descent, bounded by `check_stack`, producing the tree and the early errors
   that need no scope information.
2. **Resolve.** Linear sweep: scope tree, declarations, free and captured sets, TDZ and redeclaration
   errors, strictness retroactively applied after a `"use strict"` prologue.
3. **Generate.** A recursive walk with real knowledge of each whole subtree, so destination
   registers and operand order are decided with the tree in hand.

The AST of a top-level unit lives in an arena that is freed after code generation.

## Memory

The estimate is on the order of a million nodes for the 9 MB TypeScript bundle, about 15 to 25 MB of
AST against 126 MB peak RSS today. It is an estimate: nothing here has counted nodes. A bundle
wrapped in one function is a single unit, so its whole tree is live at once. Lazy compilation of
inner functions would bound this and needs the scope index first.

## Risk and cost

This is a rewrite of the parse-and-emit half of the compiler, weeks of work, and the old and new
paths cannot both be kept for long.

The de-risking tool is `test/golden_bytecode`. Stage 1 is the new path emitting bytecode identical
to the old one across the local suite, `test/libcorpus` and test262, before any optimisation uses the
tree. The peephole passes (`fusion.c3`, `moveelim.c3`) work on bytecode and are unaffected.

## Todos

- [ ] Plan 100 stages 0 to 4 (prerequisite).
- [ ] `NodeTag` enum, the columns and `extra`, with `mark`/`truncate`.
- [ ] Expression and statement parser producing the tree, behind a build flag.
- [ ] Resolve pass reusing plan 100's index builder.
- [ ] Code generation from the tree, bytecode-identical to the old path.
- [ ] Delete the old fused parse-and-emit path.
