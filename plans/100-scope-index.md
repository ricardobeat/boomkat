# 100: Scope index

The compiler learns each block's lexical names, each function's `var` names and each function's
captured locals by re-tokenising source ahead of the parser (`pre_scan_lexical_decls`,
`pre_scan_switch_lexical_decls`, `pre_scan_var_decls`, `hoist_decls`, `pre_scan_captures`). Every
nesting level repeats the scan over everything inside it. This plan replaces those scans with one
scan per compilation unit that builds a scope index the compiler queries.

Plan 101 sketches the larger alternative (a flat AST). Everything here carries over to it: the atom
table and the scope index are the resolve pass's output.

## Measurements

Bytes the lexer scans, divided by source size, from `just relex-stats <file>` (the `RELEX_STATS`
build, `src/relexstats.c3`). It counts at the one place that scans, so every rewind mechanism is
included, and 1.0x is the floor. The bundles are wrapped as `var __f = function(){ ... };` and the
nested case is `var __f = function(){` + 200 `{` + 20000 `var x=0;` + `};` (unterminated on purpose,
so it stops at a SyntaxError after the scans ran):

| input | source | lexed | ratio |
|-------|-------:|------:|------:|
| `test/libcorpus/babel.js` | 2.9 MB | 49 MB | 17.1x |
| `test/libcorpus/typescript.js` | 9.1 MB | 209 MB | 22.8x |
| 200 nested blocks around a 20k-statement body | 0.16 MB | 34 MB | 212x |

Where it goes, as multiples of the source size (`parse` is everything outside a named scan, so its
excess over 1.0 is the parser's own speculation and loop re-parsing):

| activity | babel | typescript | nested |
|----------|------:|-----------:|-------:|
| `parse` | 2.5 | 2.9 | 1.0 |
| `lex_decls` (`pre_scan_lexical_decls`) | 6.0 | 4.9 | 4.0 |
| `block_decls` (`pre_scan_switch_lexical_decls`, also run for every plain block) | 0.2 | 2.7 | 200 |
| `var_decls` | 0 | 4.1 | 0 |
| `hoist_decls` | 4.6 | 4.5 | 3.0 |
| `hoist_fn_decls` | 2.0 | 2.0 | 2.0 |
| `captures` | 1.7 | 1.7 | 2.0 |

The pathological nesting cost is entirely `block_decls`: every plain block runs the scan that also
collects function and class declarations. The hoists are 6.5x on the bundles, more than a third of
the total, so replacing only the lexical, `var` and capture scans leaves most of the cost; they
have to move too.

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

## The scans disagree with the parser about `/` after `)` and `}`

`Lexer.next_token` decides regex versus division from the previous token (`prev_was_operand`), which
treats `)` and `}` as ending an operand, so `/` after them is division. The parser corrects this
where the grammar says otherwise (`force_regex_after_brace`, `force_division_next`). The pre-scans
have no such corrections, so they mis-lex a regex literal that follows the `)` of an
`if`/`while`/`for`/`with` head or a statement-level block's `}`:

    function g() { if (1) /}/.test("}"); return 1; }
    // SyntaxError: unexpected character ';' (not supported)

The same function compiles at the top level of a script. This is a bug in today's compiler, not only
a hazard for the index. Rare in practice, but the failure is a rejected valid program.

A unit-wide scan makes the mismatch worse: today a derailed scan costs one block's names and the
next scan resynchronises, while a unit-wide scan would carry the error to every later scope. The fix
is the same for both, so it comes first:

1. One shared tracker for the scans (`ScanLexState`): a paren stack recording whether each `(`
   followed `if`/`while`/`for`/`with`, and a brace stack recording whether each `{` opened a statement
   block, a function body, or an expression. After the matching `)` or `}` it sets the lexer's
   existing `force_regex_after_brace` for the next token when a statement starts there. The scans
   already track the first half (`head_pending`, `head_active`, `at_clause` in
   `pre_scan_lexical_decls`).
2. Run it in every scan, with a regression test for the repro above.
3. In the index, check each recorded `close_pos` against the parser when the block ends, and fall
   back to the legacy scan for the rest of the unit on a mismatch.

The census at the start of stage 2 (the existing state machines run as a stack, counting blocks that
disagree with the legacy scan under `SCAN_VERIFY`, across test262, `test/libcorpus` and the local
suite) measures how often the remaining cases occur.

## Staging

Each stage keeps the old scan next to the new one behind `@feat(SCAN_VERIFY)`, which asserts that
both agree, and runs the local suite, `test/libcorpus`, `just rosetta` and a narrow test262 pass
before the old scan is deleted.

- [x] **0. Measure.** A `RELEX_STATS` counter in `restore_lhs_snapshot`, printed at exit, so every
  stage reports the table above for the same inputs (`just relex-stats`).
- [ ] **1. Atoms and storage.** Atom table, `PagedVec{T}`, the scope and declaration arrays and the
  offset lookup, with unit tests in C3.
- [ ] **1b. Shared regex/brace tracker for the scans.** Fixes the rejected-valid-program bug above.
- [ ] **2. Lexical declarations.** The disagreement-count experiment first, then
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
