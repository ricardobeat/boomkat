#!/bin/bash
# Module declaration-position early errors (ES2024 §16.2.1).
#
# An ImportDeclaration / ExportDeclaration is a ModuleItem: it may appear ONLY
# in a Module's top-level StatementList, never inside a block, a loop or switch
# body, a labelled statement, a try/catch/finally, or a function body. The
# non-declaration export forms additionally end with `;` in the grammar, so a
# missing semicolon is a SyntaxError unless ASI supplies one.
#
# Each case is written to a temporary .mjs and compiled (never run). Reject
# cases must exit non-zero with a syntax error; accept cases must exit zero.
#
# The same fixtures are checked against `node --check` when node is available,
# so the expectations are V8-verified rather than assumed.
#
# Usage: bash test/modules/syntax_positions.sh [engine_binary]

ENGINE="${1:-./out/duktape_c3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# check <expect: REJECT|ACCEPT> <description> <source>
check() {
  local expect="$1" desc="$2" src="$3"
  local f="$TMP/case.mjs"
  printf '%s\n' "$src" > "$f"

  local out rc got
  out=$(timeout 5 "$ENGINE" --module "$f" 2>&1)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc -- engine HUNG (timeout)"
    return
  fi
  if [ "$rc" -eq 0 ]; then got=ACCEPT; else got=REJECT; fi

  # Cross-check the expectation against node when it is available.
  if command -v node >/dev/null 2>&1; then
    local nodeout noderc nodegot
    nodeout=$(node --check "$f" 2>&1); noderc=$?
    if [ "$noderc" -eq 0 ]; then nodegot=ACCEPT; else nodegot=REJECT; fi
    if [ "$nodegot" != "$expect" ]; then
      FAIL=$((FAIL + 1))
      echo "FAIL: $desc -- expectation disagrees with node (node=$nodegot expected=$expect)"
      return
    fi
  fi

  if [ "$got" = "$expect" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc -- expected $expect got $got"
    echo "$out" | head -2 | sed 's/^/      | /'
  fi
}

# --- an ExportDeclaration is only a ModuleItem ---
check REJECT "export in a block"                 '{ export default null; }'
check REJECT "export in a block statement list"  '{ ; export default null; }'
check REJECT "export in a switch case"           'switch(0) { case 1: export default null; }'
check REJECT "export in a switch default"        'switch(0) { default: export default null; }'
check REJECT "export in an if body"              'if (0) export default null;'
check REJECT "export in an else body"            'if (0) ; else export default null;'
check REJECT "export in a while body"            'while (0) export default null;'
check REJECT "export in a do-while body"         'do export default null; while (0);'
check REJECT "export in a for body"              'for (;;) export default null;'
check REJECT "export as a for var init"          'for (export var a;;) ;'
check REJECT "export as a for let init"          'for (export let a;;) ;'
check REJECT "export as a for const init"        'for (export const a = null;;) ;'
check REJECT "export in a for-in head (var)"     'for (export var a in {}) ;'
check REJECT "export in a for-in head (let)"     'for (export let a in {}) ;'
check REJECT "export in a for-of head (var)"     'for (export var a of []) ;'
check REJECT "export in a for-of head (let)"     'for (export let a of []) ;'
check REJECT "export in a labelled statement"    'l: export default null;'
check REJECT "export in a try block"             'try { export default null; } catch (e) {}'
check REJECT "export in a catch block"           'try {} catch (e) { export default null; }'
check REJECT "export in a finally block"         'try {} finally { export default null; }'
check REJECT "export in a function body"         'function f() { export default null; }'

# --- likewise an ImportDeclaration ---
check REJECT "import in a block"                 '{ import v from "./x.js"; }'
check REJECT "import in a function body"         'function f() { import v from "./x.js"; }'
check REJECT "import in an if body"              'if (0) import v from "./x.js";'
check REJECT "import in a try block"             'try { import v from "./x.js"; } catch (e) {}'
check REJECT "import in a switch case"           'switch(0) { case 1: import v from "./x.js"; }'
check REJECT "import in a while body"            'while (0) import v from "./x.js";'
check REJECT "import in a labelled statement"    'l: import v from "./x.js";'

# --- the non-declaration export forms require their trailing semicolon ---
check REJECT "export default expr, no semicolon" 'export default 0 null;'
check REJECT "named export, no semicolon"        'export {} null;'
check REJECT "export star, no semicolon"         'export * from "./x.js" null;'
check REJECT "ns export, no semicolon"           'export * as ns from "./x.js" null;'
# ...but ASI supplies it at a line break.
check ACCEPT "export default expr, ASI"          'export default 0
null;'
check ACCEPT "named export, ASI"                 'export {}
null;'
# ...and the declaration forms never needed one.
check ACCEPT "export default function, no semi"  'export default function f() {} null;'
check ACCEPT "export default class, no semi"     'export default class C {} null;'
check ACCEPT "export function, no semi"          'export function f() {} null;'
check ACCEPT "export class, no semi"             'export class C {} null;'

# --- ACCEPT side: everything legal must keep compiling ---
check ACCEPT "top-level export default"          'export default null;'
check ACCEPT "top-level export var"              'export var a = 1;'
check ACCEPT "top-level export let"              'export let b = 1;'
check ACCEPT "top-level export const"            'export const c = 1;'
check ACCEPT "top-level export function"         'export function f() {}'
check ACCEPT "top-level export class"            'export class C {}'
check ACCEPT "top-level named export"            'var d = 1; export { d };'
check ACCEPT "top-level aliased export"          'var e = 1; export { e as ee };'
check ACCEPT "empty named export"                'export {};'
check ACCEPT "export default anonymous function" 'export default function () {}'
check ACCEPT "export default anonymous class"    'export default class {}'
check ACCEPT "export default expression"         'export default 1 + 1;'
check ACCEPT "plain block"                       '{ var a = 1; }'
check ACCEPT "plain switch case"                 'switch(0) { case 1: var a = 1; }'
check ACCEPT "plain if body"                     'if (0) var a = 1;'
check ACCEPT "plain function body"               'function f() { var a = 1; }'
check ACCEPT "plain labelled statement"          'l: var a = 1;'
check ACCEPT "plain try block"                   'try { var a = 1; } catch (e) {}'
check ACCEPT "plain for loop"                    'for (var i = 0;;) break;'
check ACCEPT "plain for-in"                      'for (var k in {}) ;'
check ACCEPT "plain for-of"                      'for (var v of []) ;'
# Dynamic import is a CallExpression, NOT a ModuleItem: legal anywhere.
check ACCEPT "dynamic import in a block"         '{ import("./x.js"); }'
check ACCEPT "dynamic import in a function"      'function f() { return import("./x.js"); }'
check ACCEPT "dynamic import in an if body"      'if (0) import("./x.js");'
# import.meta is a meta-property, likewise legal anywhere in module code.
check ACCEPT "import.meta at top level"          'import.meta;'
check ACCEPT "import.meta in a function"         'function f() { return import.meta; }'
# `export` / `import` as ordinary property names are unaffected.
check ACCEPT "property named export"             'var o = { export: 1 }; o.export;'
check ACCEPT "property named import"             'var o = { import: 1 }; o.import;'

# ---------------------------------------------------------------------------
# Escaped contextual keywords (ES2024 §12.6.1)
# ---------------------------------------------------------------------------
#
# `as` and `from` are matched on their text rather than being reserved words,
# and a spelling containing a UnicodeEscapeSequence is never the keyword. Each
# escaped form below is therefore a plain identifier in a position where the
# grammar demands the keyword, i.e. a SyntaxError.
#
# The specifiers point at ./self.mjs, which exists (created below), so a
# REJECT here is the escape rule and not an unresolvable-module link error.

printf 'export var a = 0;%s' "$(printf '\n')" > "$TMP/self.mjs"

check REJECT "escaped as in export specifier"    'export var a = 0;
export {a \u0061s b} from "./self.mjs";'
check REJECT "escaped from in export"            'export {} \u0066rom "./self.mjs";'
check REJECT "escaped from in import"            'import {} \u0066rom "./self.mjs";'
check REJECT "escaped as in namespace import"    'import* \u0061s ns from "./self.mjs";'
check REJECT "escaped as in import specifier"    'import {a \u0061s b} from "./self.mjs";'
check REJECT "escaped as in export * as"         'export * \u0061s ns from "./self.mjs";'

# The unescaped spellings must all keep working.
check ACCEPT "plain as in export specifier"      'export var a = 0;
export {a as b} from "./self.mjs";'
check ACCEPT "plain from in export"              'export {} from "./self.mjs";'
check ACCEPT "plain from in import"              'import {} from "./self.mjs";'
check ACCEPT "plain as in namespace import"      'import* as ns from "./self.mjs";'
check ACCEPT "plain as in import specifier"      'import {a as b} from "./self.mjs";'
check ACCEPT "plain as in export * as"           'export * as ns from "./self.mjs";'

# `as` and `from` are not reserved, so they remain ordinary identifiers.
check ACCEPT "as and from as variable names"     'var as = 1, from = 2; as + from;'
check ACCEPT "as and from as property names"     'var o = { as: 1, from: 2 }; o.as + o.from;'

echo ""
echo "modules/syntax_positions: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
