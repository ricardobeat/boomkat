# 101: Flat AST

The compiler parses and emits in one pass, which is why it needs the token pre-scans plan 100
describes. This plan replaces the fused pass with a flat, Zig-style AST: parse into the tree,
resolve scopes over it, then generate code from it. It is developed on the `flat-ast` branch.

An Opus review of the first draft shaped the staging below. Its main points: port code generation
leaf-first through `compile_inner_function` instead of falling back per unit, gate the resolve pass
against the existing scans in a compare mode, and settle lexer and memory prerequisites before
writing the parser.

## Constraints from the current front end

- About 36k lines in `src/compiler/`; roughly 24k of them (`expressions`, `statements`, `functions`,
  `class`, `destructuring`) parse and emit together. The back half (`emit`, `regalloc`, `scope`,
  `constants`, `cells`, `patches`, `fusion`, `moveelim`, about 3.6k lines) is reusable as is.
- Test262 knowledge lives in emission order: the check-then-instantiate double pass in
  `compile()` (`entry.c3`), `hoist_pc` patches, `eval_var_coll`, and about 170 references to
  emit-time peephole state in `expressions.c3` (`last_was_getvar`, `call_prop_obj_reg`,
  `member_key_const` reading the previous instruction).
- The parser drives the lexer: regex versus division, templates, `await`/`yield` as operators and
  strictness all change how the next token lexes. `peek()` lexes the lookahead at once under the
  flags set at that moment, and `set_strict` does not invalidate a cached lookahead.
  `CompilerContext` keeps a second, multi-token `pushback_stack` on top of the lexer's.
- `Token` carries line and column but no byte offset. `Lexer.token_start` is updated by some paths
  and not by pushback.
- `emit()` takes each instruction's line from `self.lexer.current.line`.
- `Function.prototype.toString` needs function source spans, with special start rules
  (`pending_async_fn_kw_pos`).
- `Lexer` copies a 512-byte `err_msg` on every snapshot.
- TS type stripping (`ts_skip.c3`) is written against the `CompilerContext` token API.
- `MAX_PRESCAN_NAMES = 64` silently truncates a block's lexical declarations: the 65th name gets no
  TDZ initialisation. The tree has no such limit.

## Layout

Parallel columns indexed by a `u32` node id, 0 meaning null:

| column | type | meaning |
|--------|------|---------|
| `tag` | `enum NodeTag : char` | node kind |
| `flags` | `char` | parenthesised, and other per-node bits |
| `main_tok` | `u32` | source byte offset of the node's main token |
| `lhs`, `rhs` | `u32` each | child ids, an index into `extra`, or an inline payload |

That is 14 bytes per node plus the `extra` array for variable-arity lists and function and class
spans (explicit start and end offsets for `toString`). Identifier nodes carry an atom id, numbers the
`f64` bits, string literals an atom id for the decoded value. Line and column come from a line-start
table; `emit()` takes an explicit `cur_line` set from `main_tok` through a forward cursor.

Children are appended before their parent. That gives:

- A linear resolve sweep with no recursion.
- Backtracking by truncation, for the one case that needs speculation (TS generic arrows).
  Everything else in JS mode (arrow parameters, destructuring assignment) is a retag in place and
  never re-lexes.
- A contiguous subtree per function, which can be collapsed to a stub once its code is generated
  (see Memory).

## Memory

A node is about one token, so the TypeScript bundle is likely nearer 2M nodes than 1M: 30 to 50 MB
of tree, estimated and not measured. On MCU targets a whole-unit tree is a regression against
today's per-function compiler. Two measures:

- Collapse a function's subtree after its code is generated, keeping the stub's free-name set.
  Class bodies are the exception: `#x` can be declared after its use, so generation waits until the
  outermost class closes.
- Lazy compilation (parse once, compile a function body on first call) bounds the live tree, and
  needs the resolve pass.

The columns start as plain growable arrays behind accessors, and move to chunked arrays when a
measurement asks for it.

## Prerequisites in the lexer (before the parser)

- `Token.pos`: the byte offset of the token's first byte. The AST needs it everywhere.
- An explicit goal per token (division, regex, template tail) chosen by the parser, replacing the
  `force_*` flags as the parser's interface; a debug assertion that a consumed lookahead was lexed
  under the same mode it is consumed in.
- Strictness decides which words are keywords (`lookup_keyword(name, reserved_words_strict)`). A
  function name, its parameters and the prologue strings lex before `"use strict"` is seen, so the
  AST parser lexes them as identifiers with a flag and the resolve pass checks them.
- `err_msg` out of the `Lexer` struct, so a snapshot is cheap.
- `ts_skip.c3` onto a token-cursor interface shared by both parsers.

## Stages

Stages 0 to 5 are additive and gated by a build flag; the engine behaves as before until stage 6.

- [x] **0. Per-scan breakdown.** `RELEX_STATS` counts lexed bytes at the one scanning site and
  attributes them to the named scan (table in plan 100). Babel 17.1x, typescript 22.8x. The hoists
  (`hoist_decls`, `hoist_fn_decls`) are 6.5x of that, so stage 5 cannot leave them alone.
- [x] **1. Lexer prerequisites** (list above), except moving `err_msg` out of the `Lexer` and the
  `ts_skip.c3` cursor interface, which wait for the TS port in stage 7. `Token` carries `pos`, `end`
  and `nl_before`; `Lexer.ast_mode` lexes `/` and `}` as punctuators and decodes octal escapes
  leniently; `rescan_regexp` and `rescan_template_part` re-lex a token where the parser says so.
- [x] **2. AST container** (`src/ast/{vec,atoms,ast}.c3`). Columns, `extra`, atom table (open addressing, compile lifetime), line
  table, `mark`/`truncate`, subtree collapse. C3 unit tests where cheap.
- [~] **3. Parser** (`src/ast/parse_*.c3`; gates below met except the round-trip, see the note). Full ES2024 Script and Module grammar, syntax only, streaming tokens from the
  existing lexer. Gates, none of which needs code generation:
  - `--dump-ast` in `cli/boomkat_debug.c3`.
  - Acceptance census: the AST parser accepts every file the legacy compiler accepts (test262
    positive tests, `test/libcorpus`, `test/*.js`), plus a ratchet on how many negative tests it
    accepts, falling as early errors move over.
  - Printer round-trip: print fully parenthesised source, check that print then parse is a fixed
    point, and run the printed positives through the legacy compiler expecting the same results.
    This catches precedence, ASI, regex versus division and cover grammar mistakes without codegen.
  - A lexer ratio of 1.0x under `RELEX_STATS` in JS mode. Met: 0.99x on babel (17.05x legacy).

  Status: `just ast-census` over `test/*.js` and `test/libcorpus` agrees with the legacy compiler on
  all 615 files. Over the 50,109 test262 `language`, `built-ins`, `annexB` and `staging` files the AST
  parser rejects nothing the legacy compiler accepts except out-of-scope proposals (decorators,
  `using`, `accessor`); 1,827 files differ only because the legacy compiler enforces early errors
  the parser does not yet (the ratchet: this count falls through stage 7). The printer round-trip
  is dropped: stage 6's per-function bytecode diff catches the same precedence and cover-grammar
  mistakes against the legacy compiler directly.
- [ ] **4. Resolve, in compare mode.** Scope tree, declarations, free and captured sets (bitsets for
  small functions, sorted `u32` slices for large). In a debug build every pure-query scan call site
  (18 of them) is checked against the AST index. Rule: AST-captured is a subset of legacy-captured
  (the legacy scan over-approximates by name), and every other disagreement gets an explanation.
  This is the gate for the stage.
- [ ] **5. Replace the pure-query scans.** `pre_scan_lexical_decls`, `pre_scan_switch_lexical_decls`,
  `pre_scan_var_decls` and `pre_scan_captures` read the index. `hoist_decls` and
  `hoist_global_fn_decls` emit while scanning, and hoisting compiles functions by seeking the lexer;
  they are 6.5x of the measured cost, so a second step moves their name collection onto the index
  and leaves only the emission in place. Compile time and the regex-after-`)` rejection are fixed
  from here on.
- [ ] **6. Code generation, leaf first.** Hook `compile_inner_function`: snapshot the lexer,
  AST-parse the parameters and body from the current position, check that every tag is supported,
  then generate or restore the snapshot. Inherited state (strictness, super and home-object names,
  private-name snapshot, `outer_with`, `is_constructable`) is read from `self`. Inner code reads
  outer names by name and `resolve_capture_candidates` links them after compilation, so a legacy
  parent with an AST child works; the reverse does not (legacy inner code needs a legacy parent
  context). The fallback decision is made before any side effect: parse, check, then generate. The
  harness functions in test262 reach the new path first. Grow upward: statements, classes,
  destructuring, then the top-level entry points last.
- [ ] **7. Early errors** into parser and resolve, then delete the legacy fused path, then TS mode.

## Contracts both paths must share

- Hidden binding names (`__super__N` from a per-context `super_class_counter`, `__home_object__N`).
- The private-name snapshot layout and the `capture_names` publication format.
- `eval_var_idxs` and `FuncFlags`: direct eval compiled by one path reads bindings the other made.
- A fallback must clear `err_msg` (first writer wins, and `finish()` treats it as the error check),
  defer `module_def` writes, and discard partial `CompiledFunction`s.

## Validation tooling

`scripts/bytecode_diff.py` compares only opcode counts per file, and `test/golden_bytecode` has 28
pairs. Stage 6 needs a per-function disassembly diff from one binary with an `--ast` switch. The
hard bar is identical behaviour; identical bytecode is the goal where it is cheap.

## Branch policy

Work is on `flat-ast`. Stages 0 to 5 change no behaviour behind the flag and are mergeable to `main`
as they land, which keeps the branch from drifting while legacy bugs keep getting fixed there.
Stage 6 is the long one.
