# 100: Scope index

The compiler learns each block's lexical names, each function's `var` names and each function's
captured locals by re-tokenising source ahead of the parser (`pre_scan_lexical_decls`,
`pre_scan_switch_lexical_decls`, `pre_scan_var_decls`, `hoist_decls`, `pre_scan_captures`). Every
nesting level repeats the scan over everything inside it. This plan replaces those scans with one
scan per compilation unit that builds a scope index the compiler queries.

Plan 101 sketches the larger alternative (a flat AST). Everything here carries over to it: the atom
table and the scope index are the resolve pass's output.

## Measurements

Bytes the lexer is rewound over, summed over every `restore_lhs_snapshot` (a pre-scan always ends
with one), from `just relex-stats <file>` (the `RELEX_STATS` build, `src/relexstats.c3`). The
bundles are wrapped as `var __f = function(){ ... };` and the nested case is
`var __f = function(){` + 200 `{` + 20000 `var x=0;` + `};` (unterminated on purpose, so it stops at
a SyntaxError after the scans ran):

| input | source | re-lexed | ratio |
|-------|-------:|---------:|------:|
| `test/libcorpus/babel.js` | 2.9 MB | 43 MB | 15x |
| `test/libcorpus/typescript.js` | 9.1 MB | 194 MB | 21x |
| 200 nested blocks around a 20k-statement body | 0.16 MB | 34 MB | 211x |

Compile time and peak RSS, parse only (the file wrapped in `var __f = function(){ ... }`):

| input | time | peak RSS |
|-------|-----:|---------:|
| babel | 0.9 to 1.3 s | 44 MB |
| typescript | 1.7 s | 126 MB |

The lexer is about half of all samples when compiling the TypeScript bundle, nearly all of it
re-lexing. The pre-scan cost is the nesting depth times the size of the scanned span, so source with
deep nesting costs the most:

| 100k-token body, unterminated | time |
|-------------------------------|-----:|
| 50 nested blocks | 0.3 s |
| 200 nested blocks | 1.1 s |
| 800 nested blocks | 4.3 s |

Captures are kept as heap-copied names in a `List{char[]}` searched with `str_eq`
(`add_captured_name`), which also shows up in the profile.

## Design

One forward scan per unit (script, module, eval body, `Function` body) walks the tokens with a stack
of open scopes and records, in flat arrays:

- **Scopes.** `{open_pos, close_pos, parent, kind, decl_start, decl_count}`. Kinds are block,
  function, arrow, class, switch, catch and for-head. Scopes are numbered in source order, so a scope
  and its descendants are a contiguous id range. `open_pos` finds a scope by source offset through an
  open-addressing `u32 -> u32` table.
- **Declarations.** `{atom, kind, pos}`, grouped by scope.
- **Free and captured sets.** Computed bottom-up as each scope closes:
  `free(F) = (refs(F) | free(children)) - decls(F)` and
  `captured(F) = decls(F) & free(children)`. A function whose names number at most 256 uses a stack
  `BitSet{256}` over a numbering local to the function; larger functions use sorted `u32` slices
  merged in linear time. A bitset over every name in the program would be several KB per function.
- **Atoms.** A compile-lifetime open-addressing table maps identifier text (including decoded
  escapes) to a `u32` id. It is separate from the runtime heap's string interning: a local that lives
  in a register never needs a runtime string.

The compiler then asks the index instead of scanning:

- `block()` reads its declarations by `open_pos`.
- `hoist_decls` reads the function scope's `var` and function declarations.
- `declare_var` asks `is_captured(atom)`.

All storage is arena-backed and freed when the unit finishes compiling. The `std::collections`
containers fit only in part: `List{T}` is the growable array, `GrowableBitSet` and `BitSet{N}` cover
the sets, and `HashMap` chains an allocation per entry, so the atom and offset tables are small
purpose-built open-addressing tables. A `PagedVec{T}` (4096-element chunks indexed by shifts) avoids
the outgrown-buffer cost of a `List` growing inside an arena, and needs no virtual-memory reserve, so
it works on the MCU targets.

## What this does not change

The scan remains a second, approximate grammar: regex versus division, the `let`-before-newline
rule, class declaration versus expression, arrow detection and TS type skipping are decided by the
scan and again by the parser. The scan runs once instead of once per nesting level.

## Risk: the scans do not know regex literals

`Lexer.next_token` always returns `SLASH` for `/`: only the parser knows a regex literal starts
there and calls `scan_regexp`. The existing scans therefore tokenise `/[{]/` or `/'/` as ordinary
tokens, and `pre_scan_lexical_decls` has no template handling either (`pre_scan_captures` and
`hoist_decls` use `TemplateScan`). Today that is contained: a regex that derails a scan costs the
names of the one enclosing block, and every nested block rescans from its own start, in sync again.

A unit-wide scan makes a derailment global: a phantom `{` from a regex would swallow every later
declaration of the unit into a phantom scope. Mitigations, to be tried in this order:

1. A regex-versus-division rule in the scan from the previous token. It is exact after operators,
   `(`, `,`, `=`, `:`, `[`, `!`, `&`, `|`, `?`, `{`, `}`, `;` and keywords, and after identifiers,
   literals and `]`. It is ambiguous only after `)` (`if (x) /re/.test(y)`) and `}` (block versus
   object literal).
2. Check each recorded `close_pos` against the parser when the block ends, and fall back to the
   legacy scan for the rest of the unit on a mismatch. It detects a derailment only after that
   block's names were used, so it backs up mitigation 1 and does not replace it.
3. Fall back to the legacy scan for a unit where the ambiguous cases appear before the index is
   built: the index is an optimisation, and a unit that cannot use it compiles as it does today.

Stage 2 starts with an experiment before any consumer is switched: build the index with the
existing state machines run as a stack (no behaviour change) and count, under `SCAN_VERIFY`, how
many blocks disagree with the legacy scan across test262, `test/libcorpus` and the local suite.
That count decides how much of the list above is needed.

## Staging

Each stage keeps the old scan next to the new one behind `@feat(SCAN_VERIFY)`, which asserts that
both agree, and runs the local suite, `test/libcorpus`, `just rosetta` and a narrow test262 pass
before the old scan is deleted.

- [x] **0. Measure.** A `RELEX_STATS` counter in `restore_lhs_snapshot`, printed at exit, so every
  stage reports the table above for the same inputs (`just relex-stats`).
- [ ] **1. Atoms and storage.** Atom table, `PagedVec{T}`, the scope and declaration arrays and the
  offset lookup, with unit tests in C3.
- [ ] **2. Lexical declarations.** The disagreement-count experiment first (see the risk above), then
  `pre_scan_lexical_decls` and `pre_scan_switch_lexical_decls`
  read the index. Delete both scans.
- [ ] **3. `var` and function declarations.** `pre_scan_var_decls` and `hoist_decls`.
- [ ] **4. Captures.** `pre_scan_captures`, `captured_names` and `add_captured_name` replaced by
  atom ids and the set algebra above. This stage has the shadowing heuristics and the most risk.
- [ ] **5. Move the deep-nesting cases back.** If the pathological inputs now run in milliseconds,
  move the eight cases in `test/robustness/run.sh` back into `test/compiler_capacity.js`.

## Acceptance

- `RELEX_STATS` re-lexed bytes fall from 15x and 21x to about 2x on babel and typescript.
- `SCAN_VERIFY` disagrees on nothing across the local suite, `test/libcorpus` and test262.
- Bytecode in `test/golden_bytecode` is unchanged.
- `just perf-diff` shows no regression on the benchmark set; compile time of the two bundles falls.
- Peak RSS of the two bundles does not rise by more than the index itself.
