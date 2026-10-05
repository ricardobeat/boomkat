# 101: Flat AST

The compiler parses JavaScript and TypeScript into a flat AST, resolves bindings
and captures, checks early errors, then generates register bytecode. Work is on
`flat-ast`. Source compilation has one path; the fused token parser is removed.

## Representation

Node 0 is null. Parallel columns hold a byte tag, byte flags, source offsets
`main_tok` and `end_tok`, and two `uint` payloads, `lhs` and `rhs`. The columns use
18 bytes per node; `extra` holds lists and records. Identifier and decoded-string
payloads index an atom table. Function and class records retain source spans for
`Function.prototype.toString`. A line-start table maps byte offsets to positions
by binary search. Generation sets the emitter's source line explicitly.

Children precede parents. JavaScript cover grammar retags expressions into
parameters and patterns. TypeScript generic arguments and arrow return types use
cursor snapshots. `mark`/`truncate` rolls back speculative tree additions.
Resolution walks scopes in source order; long left binary spines are iterative.
Early errors and generation also walk those spines without native-stack recursion.
Other grammar nesting uses the native-stack guard.

The AST uses small growable arrays and an open-addressed atom table. Compiler
lowering uses C3 `List` and the engine's existing allocators, register machinery,
iterator helpers, class installation and bytecode passes. It avoids a second
implementation of those semantics.

## Lexer and diagnostics

`Token` carries byte positions, end positions and line-break information.
`Lexer.ast_mode` scans `/` and `}` as punctuators; the parser requests regexp and
template continuation rescans at grammar boundaries. It discards speculative
lookahead before a rescan. Strict-only lexical forms retain enough information
for the early-error pass to check a later `"use strict"` directive.

The lexer's diagnostic storage is a heap-backed slice, so token snapshots do
not copy a fixed diagnostic array. AST parser errors have their own buffer and
copy their message and source position into the owning lexer on failure.
Parse or early-error rejection stops compilation before generation.

Direct eval supplies inherited strictness, private names, super permissions,
new.target permission and class-initializer restrictions. Scripts and ordinary
dynamic function bodies default to sloppy; modules and class code are strict.

## Memory decision

The parser builds a whole-unit tree. Collapsing a subtree after generation cannot
reduce that parse peak, and truncating an interior range of contiguous columns
cannot release its allocation while preserving node ids. Lazy generation also
keeps the parsed tree live; it requires a separate ownership design to save memory.
The draft's claims that these measures already bound the live tree are withdrawn.

The implementation frees parser scratch, reference records and atom hash slots
before generation, then frees the remaining tree and scopes before the root's
final bytecode passes. This reduces overlap with bytecode copies and optimizer
scratch without adding segmented storage or allocation per node. The columns
remain contiguous. Large-unit peak memory remains a measured limitation, not
an unimplemented stage hidden behind a completed checkbox.

Compile-only measurements on Apple Silicon, using optimized inspection builds
and a saved compiler with both AST generation and the AST index disabled:

| Source | Fused time | AST time | Fused peak RSS | AST peak RSS |
|--------|-----------:|---------:|---------------:|-------------:|
| Babel bundle | 0.810 s | 0.255 s | 40.11 MB | 50.61 MB |
| TypeScript bundle | 1.834 s | 0.605 s | 72.35 MB | 96.76 MB |

`--check` neither disassembles nor executes. Timings are medians of three runs;
RSS is the largest `wait4` child peak in those runs, in decimal MB. Bundle
compilation is 3.0–3.2× faster, with 26–34% higher peak RSS. The small operator
fixture peaks at 4.47 MB against 4.62 MB for fused compilation; its startup-scale
timing varies too much to support a speed claim. Disabling only AST generation
still builds the tree and is not a valid memory baseline.

## Completed stages

- [x] **0. Re-lex statistics.** Per-scan accounting identified hoisting and
  capture scans as the main repeated token work. The Babel and TypeScript
  baselines and scan breakdown are in plan 100.
- [x] **1. Lexer prerequisites.** Source offsets, parser-directed regexp/template
  goals, strict lexical metadata and cheap snapshots. Type stripping uses the
  AST parser's cursor rather than a second compiler token API.
- [x] **2. Container.** Flat columns, variable records, atoms, source positions
  and speculative rollback. Subtree compaction is replaced by the measured
  lifetime policy above.
- [x] **3. Parser.** Script and Module grammar, cover grammar, ASI and lexical
  goals. `--dump-ast` and `--parse-only` expose it. The source-printer round-trip
  gate is replaced by full function-dump comparisons and runtime regressions;
  `print.c3` is a diagnostic tree dump, not a JavaScript source printer.
- [x] **4. Resolution.** Scope tree, binding/declaration sites, references,
  captures, module exports and Annex B publication. The migration's 51,010-file
  scan comparison had no unexplained disagreements. Its token compare machinery
  is removed with the fused parser.
- [x] **5. Replace scans.** Hoisting, lexical TDZ, captures, module register
  residency and block functions use resolved records. There are no compiler
  token pre-scans or lexer seeks for declarations.
- [x] **6. Early errors.** Streaming checks, contextual tree checks and resolved
  redeclarations cover supported grammar. Eval uses inherited context. Regexp
  validation runs at compilation; runtime regexp objects use the existing
  literal cache. Census differences from the saved compiler have exact named
  explanations; proposal-scope exclusions remain visible.
- [x] **7. Generation.** Every accepted source body uses the AST. Shared lowering
  handles parameters/defaults/rest, patterns, member and super references,
  optional chains, logical assignment, calls/new/spreads, classes/private names,
  loops/iterators, exceptions, coroutines, templates, modules, eval, dynamic
  scopes and Annex B. No construct whitelist or fallback remains.
- [x] **8. Remove fused code and port TS.** JavaScript and TypeScript use the
  parser, resolver, early checks and generator. Compiler token APIs, scan
  fallbacks, construct whitelist and legacy selection flags are removed.
  The TS port precedes deletion so the language retains a working compiler.
  The new generation files replace the fused parser and its scan helpers.

## Lowering invariants

A local's home register stays live until scope exit. `Val` distinguishes it from
an expression temporary. Bounded node scans preserve operands across writes;
a scan that reaches its budget takes a conservative copy. `MemberTarget` retains
a member's base and key until its store. Plain stores remove the unused read and
its `WIDE` prefix; wide constants and registers use the same emitter helpers.

A dynamic binding Reference is captured before evaluating its RHS. With updates
retain their owner even when a getter deletes the property; with calls retain
the receiver. Getter and proxy writes share the VM's with-binding store helper.
Annex B publication uses the resolver's accepted outer binding.

Pattern keys and targets execute at their pattern step, after the iterator opens.
Pattern defaults execute inline, including yield and await. Parameter defaults
use the shared lexical-bridge thunks; parameter TDZ initialization publishes names
left to right. Class keys execute in the enclosing activation. Class helpers
install prototypes, brands, field initializers, static blocks and constructors.

Direct eval records actual call sites. Capture candidates link compiled children
by name after compilation. Hidden class binding names, private-name snapshots,
`eval_var_idxs`, capture publication and `FuncFlags` retain their runtime contracts.

TypeScript erases annotations, aliases/interfaces, generics, assertions,
non-null markers, overload signatures, type-only imports/exports and ambient
statements. Runtime namespaces, enums, parameter properties and prefix angle
assertions are rejected under the erasable-only policy. Decorators, auto-accessors
and using declarations remain documented non-goals.

## Validation

`boomkat_debug --dump-code` includes all functions, flags, registers, instructions,
source lines, constants and captures. `--trace-ast-gen` reports generation.
`scripts/ast_gen_diff.py` compares this with `AST_LEGACY_BIN`; `AST_LEGACY_MODE`
selects `--no-ast-gen` for the saved fused compiler or `--trace-ast-gen` to audit
removal against the saved AST compiler. Large dumps are saved intact rather than
fed to quadratic diff alignment. The tool exits nonzero for any difference.

`scripts/ast_census.py` compares parser/early-error acceptance with an optional
saved compiler, honors inline and block-list test262 flags, and reports exact
`AST-KNOWN` explanations. A difference in an unsupported proposal remains visible
in the metadata tally; it does not justify changing the test262 skip list.
`scripts/ast_compare.py` can audit a saved migration compiler with `--compare-ast`.
The current compiler has no legacy flags.

The full pre-deletion comparison covered 51,068 files and 215,698 functions:
25,138 exact dumps, 542 line-only changes, 25,388 other differences, zero compiler
crashes. Four fallbacks were invalid module cases: HTML comments and duplicate
import bindings; authoritative AST errors reject them. A dump difference is not
proof of a runtime difference. Register choices, env-backed root bindings, TDZ,
inline pattern defaults, reference snapshots and corrected call/member behavior
explain the main groups; runtime gates cover those changes.

Runtime checks through generation include 4,291 destructuring, 8,392 class,
2,866 coroutine, 1,069 optional/tag/import and narrower module/eval/with/dynamic
function directories. These directories overlap and are not additive. Regressions
under `test/ast_*.js` cover evaluation order, local value preservation, private
brands, WIDE operands, TDZ, dynamic scopes and constructor/coroutine behavior.
Final checks:

- The post-deletion census covers 51,068 files: zero crashes, zero unexplained
  acceptance differences. All 18 differences have exact `AST-KNOWN` reasons.
  The 169 metadata mismatches are 145 explicit-resource-management and 24
  decorator files excluded by the canonical suite rules.
- Against the saved AST compiler, 51,029 dumps match exactly and 39 differ only
  for the logical-assignment Reference snapshot fix. Together they contain
  215,706 generated functions with no fallback. The TypeScript bundle timed
  out in the parallel sweep and matched exactly in its isolated retry.
- Local: 559 scripts, 20 ESM fixtures, module syntax/export gates and all reporting,
  robustness, diagnostic, private-field and TS handbook checks pass. Rosetta:
  42/42. TS core, expanded cases, modules and the tsc erasable-only oracle pass.
- Official TS conformance: 1,980 accepted files compile and 251 nonerasable files
  are rejected, with zero failures. Non-goals follow the existing runner policy.
- Fresh runtime test262 gates pass: module-code 569, with 181, assignment 485,
  logical-assignment 78, class expressions 4,039, Function 475 and eval 10.
  Skipped files retain the existing suite rules.
- The memberstrict target builds and passes member-target regressions, but its
  legacy recorded-member assertions are removed with the fused parser. NONANBOX builds
  and runs all ten new AST regression files successfully.
- A fresh ASan inspection build compiles 855 local, module, TS and library files
  without a sanitizer report or crash. All ten new AST regression files also run
  cleanly under ASan, including a 20,000-operand dynamic Function body.
- The existing `check_compile_asan.sh` executes scripts despite its name. Its
  seven findings also reproduce in an ASan build of the original branch. The
  octal EOF slice bound error is fixed and passes ASan. Six existing VM findings
  remain outside this frontend migration: `array_cyclic_join`,
  `class_constructor_host_call`, `destructuring_early_errors`,
  `generator_catcher_cleanup`, `generator_throw_via_call_bind`, and
  `native_frame_storage`. The runtime sanitizer sweep is not a clean gate.

The compiler-only sanitizer checks include rejected source and a 20,000-operand
unit, so they exercise cleanup and iterative walks independently of runtime
execution. No full runtime test262 sweep is required for this migration.

The inherited computed-property-key contract remains a separate spec-version
question: the current draft retains a raw key while ES2024 coerces at reference
creation. The AST generator follows the engine's opcode contract; this migration
does not claim to settle that version choice.

## Merge review

Logical-assignment results retain their local-register ownership so a later
operand cannot overwrite the value before it is consumed. The operator fixture
covers taken and short-circuited `&&=`, `||=` and `??=` followed by a write to
the same local.

Fresh review gates pass: 559 local scripts, 20 module fixtures and their syntax
and reporting checks, 42 Rosetta cases, the checked-in TypeScript suite, and
6,296 test262 cases across assignment, logical assignment, with, module-code,
class expressions, try, switch, arrows and generators. The official TypeScript
conformance rerun requires its missing downloaded corpus; the earlier results
above are retained as migration evidence.

Three additional correctness findings reproduce on freshly built `main`
(`651e61aa`) and remain follow-up work. Each example is inside an ordinary
function so the variable can reside in a register:

- `var a=1; return (0,a)+(a=4);` returns 8; the expected value is 5.
- `var a=1; switch(a) { case (a=2): return 'wrong'; case 1: return 'right'; }`
  returns `wrong`; the discriminant must retain 1 and select `right`.
- `var a=3; for (var a; a<4; a++) {} return a;` returns undefined; the
  declaration without an initializer must preserve 3 and the loop return 4.
