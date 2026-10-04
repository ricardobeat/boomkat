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

Stages 0 to 6 leave the compiler's output and its error reporting as they were: the tree answers
scans and rejects programs only by sending them back to the legacy path. Code generation from the
tree starts at stage 7.

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
  the parser does not yet (the ratchet: this count fell through stage 6). The printer round-trip
  is dropped: stage 7's per-function bytecode diff catches the same precedence and cover-grammar
  mistakes against the legacy compiler directly.
- [x] **4. Resolve, in compare mode.** Scope tree, declarations, sites, references and captured
  bindings (`src/ast/resolve.c3`), with a debug-build check at every pure-query scan call site
  (`src/ast/compare.c3`, `boomkat_debug --compare-ast`; `scripts/ast_compare.py` sweeps a corpus).
  Names compare in source order; a name only one side has needs a recorded reason, printed as
  `AST-KNOWN <why>`. Rule for captures: AST-captured is a subset of legacy-captured, or legacy
  captured everything. A sweep of 51,010 files (test262 `language`, `built-ins`, `annexB`,
  `staging`, the lib corpus, the local tests) has 0 unexplained disagreements. The explained
  classes, all legacy gaps the index closes in stage 5 or deliberate scope differences:
  a name after `let x = 1, y` or `var x = 1, y` (late-declarator), contextual keywords as binding
  names, `export class`, a class after an ASI-terminated `)` or declaration, the legacy var scan
  overrunning or truncating at a function end, `let` as an identifier, a direct `eval` in a
  parameter list (the legacy scan reads the body only), and names behind a `with` (resolved
  dynamically). Top-level script and module bindings, `arguments`, class inner names and function
  expression names are outside the capture set by design.
  The compare found a real legacy miscompile, fixed in `captures.c3`: a call's argument list before
  a callable argument (`f(k, function () { return k; })`) was adopted as that callable's parameter
  shadow set, and the parameter defaults of an expression-bodied arrow or a destructuring
  parameter (`(x = v) => x`, `({ a = v }) => a`) were not captured, so the closure read a stale
  register. Regression test: `test/capture_call_arg_not_shadow.js`.
- [x] **5. Replace the pure-query scans.** Every non-TS compile builds the AST and its scopes up
  front (`AstIndex`, `src/ast/index.c3`, a thread-local like the heap it sits beside). The
  declaration scans (`pre_scan_lexical_decls`, `pre_scan_var_decls`, `pre_scan_switch_lexical_decls`),
  `pre_scan_captures`, `hoist_decls` and `hoist_global_fn_decls` read it, and fall back to the token
  scans when it cannot answer: an AST parse failure (out-of-scope syntax, or source the legacy
  compiler reports differently), no scope at the scan position, or a function containing a `with`.
  `boomkat_debug --no-ast-index` runs the token scans for A/B runs; `--compare-ast` runs both and
  prints disagreements, including `AST-COMPARE PARSE-FAILED` when the index could not be built.
  Hoisted functions are compiled from the offsets the AST holds (`enter_hoisted_function` seeks the
  lexer to a declaration's source start). Measured on babel.js: lexed bytes 14.8x to 1.7x of the
  source (the remainder is the AST parse plus the compiler's own parse), compile time 1.20s to
  0.75s, peak RSS 40 to 51 MB. typescript.js: 2.28s to 1.35s, 71 to 95 MB. The tree is freed at the
  end of each compile, so the extra memory is a peak and not a resident cost; subtree collapse
  after code generation is what brings it down. test262 `language`, `built-ins`, `annexB` and `staging` pass
  48,809 of 48,809 with the index on.
  Left on the token path: `pre_scan_global_var_slots` (a module-only scan that needs the
  resolver to record export lists as references), and everything under TS mode.
  Bugs the switch exposed, all fixed: the for-await `break` unwind clobbered `r0` (it emitted
  `ITER_CLOSE_ASYNC` with operand C hardwired to 0, which the token scan hid by boxing every
  for-await function's locals); `ForLhsSnapshot` did not save `at_line_start`, so a restore left it
  to whatever the last scan did; the AST parser rejected block-level `let`.
- [~] **6. Early errors.** Code generated from the tree has no legacy parse to reject invalid
  programs, so the AST path must reject what the legacy compiler does before any function is
  generated from it. Three layers:
  - The parser rejects what it decides while streaming tokens: cover grammar, `await`/`yield`
    positions, escaped reserved words (`Parser.next` checks every consumed keyword token that is
    not read as an IdentifierName), a lexing error met while peeking, a trailing comma after a
    spread that a pattern would reinterpret as rest (`SPREAD_COMMA`).
  - `src/ast/early.c3` (`Early.run`) walks the finished tree top-down with the context the rules
    need, so a `"use strict"` directive that arrives after the function name or parameters
    re-validates them: strict reserved words, `eval`/`arguments`, legacy octals, `delete` of an
    identifier or private member, `with`, labels, `break`/`continue` targets, single-statement
    declaration positions, private names declared in an enclosing class, class constructor and
    `prototype` rules, getter and setter arity, `??` mixed with `&&`/`||`, `const` without an
    initialiser, regex literals (`regexp_literal_error`, which compiles each literal a second
    time), and `arguments` in field initialisers and static blocks.
  - `Early.conflicts` checks redeclarations over the resolver's sites (lexical duplicates, lexical
    against var, against parameters and catch parameters, the Annex B.3.3 and B.3.4 exemptions)
    and module exports (duplicates, undeclared locals, ill-formed string names).
  `index_begin` runs both after the resolver; a rejected program leaves the index unused so the
  legacy scans and error messages stand. `boomkat_debug --parse-only` reports the AST path's
  verdict. `scripts/ast_census.py` compares it with the legacy compiler and with test262's
  `negative:` metadata over the whole corpus.
  Status over 50,911 files: no file the AST path rejects that legacy accepts, and 174 negative
  files still accepted, all of them decorators, `using` and `accessor` (out of scope) or the census
  reading a module test as a script. The census still lists 11 files legacy rejects that the AST
  path accepts: hashbang comments (legacy lacks them), `accessor` and `using`. Not yet in the tree
  checks: direct eval needs its inherited context (strictness, field-initialiser, enclosing
  private names) passed into `Early`; a recursion guard covers nesting but binary chains are
  walked iteratively. Where the AST path is stricter than legacy and right (for example
  `for (eval of x)` in strict code, `for (null of x)`) the census would report a disagreement; those
  are spec-correct and need an `AST-KNOWN` reason in the census before the gate can read zero.
- [ ] **7. Code generation, leaf first.** Hook `compile_inner_function`: snapshot the lexer,
  AST-parse the parameters and body from the current position, check that every tag is supported,
  then generate or restore the snapshot. Inherited state (strictness, super and home-object names,
  private-name snapshot, `outer_with`, `is_constructable`) is read from `self`. Inner code reads
  outer names by name and `resolve_capture_candidates` links them after compilation, so a legacy
  parent with an AST child works; the reverse does not (legacy inner code needs a legacy parent
  context). The fallback decision is made before any side effect: parse, check, then generate. The
  harness functions in test262 reach the new path first. Grow upward: statements, classes,
  destructuring, then the top-level entry points last. `boomkat_debug --dump-code` prints a
  canonical dump of every function (flags, registers, code with lines, constants, captures) so the
  two paths can be diffed per function from one binary.
- [ ] **8. Delete the legacy fused path**, then port TS mode onto the tree.

## Contracts both paths must share

- Hidden binding names (`__super__N` from a per-context `super_class_counter`, `__home_object__N`).
- The private-name snapshot layout and the `capture_names` publication format.
- `eval_var_idxs` and `FuncFlags`: direct eval compiled by one path reads bindings the other made.
- A fallback must clear `err_msg` (first writer wins, and `finish()` treats it as the error check),
  defer `module_def` writes, and discard partial `CompiledFunction`s.

## Validation tooling

`scripts/bytecode_diff.py` compares only opcode counts per file, and `test/golden_bytecode` has 28
pairs. Stage 7 needs a per-function disassembly diff from one binary with an `--ast` switch. The
hard bar is identical behaviour; identical bytecode is the goal where it is cheap.

## Branch policy

Work is on `flat-ast`. Stages 0 to 6 change no observable behaviour and are mergeable to `main`
as they land, which keeps the branch from drifting while legacy bugs keep getting fixed there.
Stage 7 is the long one.
