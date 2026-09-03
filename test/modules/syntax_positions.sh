#!/bin/bash
# Module declaration-position early errors (ES2024 §16.2.1).
#
# An ImportDeclaration / ExportDeclaration is a ModuleItem: it may appear ONLY
# in a Module's top-level StatementList, never inside a block, a loop or switch
# body, a labelled statement, a try/catch/finally, or a function body. The
# non-declaration export forms additionally end with `;` in the grammar, so a
# missing semicolon is a SyntaxError unless ASI supplies one.
#
# Each case is written to a temporary .mjs and passed to the engine. Reject
# cases must exit non-zero with a syntax error; accept cases must exit zero.
#
# The release CLI has no parse-only mode, so an accepted case is also RUN. That
# is invisible for all but one case here — see the module-resolution note in
# check() — because every other fixture is a bare declaration with no runtime
# behaviour to fail at.
#
# The same fixtures are checked against `node --check` when node is available,
# so the expectations are V8-verified rather than assumed.
#
# Usage: bash test/modules/syntax_positions.sh [engine_binary]

ENGINE="${1:-./out/boomkat}"
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
  if [ "$rc" -eq 0 ]; then
    got=ACCEPT
  else
    got=REJECT
    # What is under test is whether the source PARSES, and the release CLI has
    # no parse-only mode: it runs what it accepts. A case whose source parses
    # but then fails at RUNTIME must not be scored as a syntax rejection.
    #
    # `{ import("./x.js"); }` is the one case where the two differ. A dynamic
    # import is an ordinary call expression, legal in a block, so it parses —
    # and then rejects because ./x.js does not exist. Scoring that as REJECT
    # blamed the parser for the module loader's (correct) resolution failure.
    #
    # Only a module-resolution failure is forgiven, and only for ACCEPT cases;
    # anything else, and every REJECT case, is scored strictly. Note the engine
    # reports this through an unhandled rejection, since `import()` returns a
    # promise, so the exit status alone cannot distinguish the two.
    case "$out" in
      *"cannot resolve module"*) [ "$expect" = ACCEPT ] && got=ACCEPT ;;
    esac
  fi

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

# ---------------------------------------------------------------------------
# ImportedBinding is a BindingIdentifier (§13.1.1, §16.2.2)
# ---------------------------------------------------------------------------
#
# The LOCAL name an import introduces is a binding, so the restricted names
# (`eval`, `arguments`, `let`, `yield`, ...) are illegal there -- even though
# the same word is a perfectly good EXPORT name on the other side of `as`.
# self.mjs (created above) exports `a`, so these are syntax decisions and not
# unresolvable-binding link errors.

check REJECT "eval as namespace binding"         'import * as eval from "./self.mjs";'
check REJECT "arguments as namespace binding"    'import * as arguments from "./self.mjs";'
check REJECT "eval as import alias"              'import {a as eval} from "./self.mjs";'
check REJECT "arguments as import alias"         'import {a as arguments} from "./self.mjs";'
check REJECT "let as import alias"               'import {a as let} from "./self.mjs";'
check REJECT "yield as import alias"             'import {a as yield} from "./self.mjs";'
check REJECT "eval as default binding"           'import eval from "./self.mjs";'

# The bare form binds the export name itself, so it is restricted too.
printf 'var x;%sexport {x as eval};%s' "$(printf '\n')" "$(printf '\n')" > "$TMP/haseval.mjs"
check REJECT "bare eval import specifier"        'import {eval} from "./haseval.mjs";'

# An export NAME may be anything; only the local binding is restricted.
check ACCEPT "eval as export name, aliased"      'import {a as evaluate} from "./self.mjs";'
check ACCEPT "plain namespace binding"           'import * as ns from "./self.mjs";'
check ACCEPT "plain import alias"                'import {a as b} from "./self.mjs";'
check ACCEPT "bare import specifier"             'import {a} from "./self.mjs";'
check ACCEPT "string export name aliased"        'import {"a" as c} from "./self.mjs";'

# ---------------------------------------------------------------------------
# HTML-like comments (ES2024 §12.5) are reachable from Script only. In a
# Module `<!--` and `-->` stay real tokens, so each of these is a SyntaxError.
# ---------------------------------------------------------------------------
check REJECT "SingleLineHTMLOpenComment"         '<!--'
check REJECT "SingleLineHTMLCloseComment"        '-->'
check REJECT "MultiLineHTMLCloseComment"         "$(printf '/*\n*/-->')"
check REJECT "HTML open after a statement"       'var x = 1; <!-- still a comment in a script'
check REJECT "HTML close after a blank line"     "$(printf 'var x = 1;\n--> trailing')"

# The same character sequences as ordinary operators/strings must still parse:
# `-->` is `-- >` and `<!--` is `< ! --`, and neither is special inside a
# string literal.
check ACCEPT "--> as decrement then compare"     "$(printf 'var a = 1, b = 2;\nvar c = a-->b;\nexport {c};')"
check ACCEPT "<!-- as compare then not-decrement" "$(printf 'var a = 1, b = 2;\nvar c = a < !--b;\nexport {c};')"
check ACCEPT "--> inside a string literal"       'var s = "a-->b"; export {s};'

# ---------------------------------------------------------------------------
# `await` is reserved throughout module code (ES2024 §13.1.1): the [Await]
# grammar parameter is set for the whole Module goal symbol, not just the
# module body. So it stays reserved inside a nested plain (non-async)
# function, a class field initializer, and a computed key -- all places where
# the enclosing function context is no longer the module body itself.
# ---------------------------------------------------------------------------
check REJECT "await expr in nested function"     "$(printf 'function f() {\n    await;\n}')"
check REJECT "await binding in nested function"  'function f(){ var await = 1; }'
check REJECT "await param in nested function"    'function f(await){}'
check REJECT "await as function name"            'function await(){}'
check REJECT "await in class field initializer"  'async () => class { x = await };'
check REJECT "await in nested fn in class field" 'class C { x = function(){ return await; } }'
check REJECT "await binding at module top level" 'var await = 1;'
check REJECT "await as catch param"              'try { } catch (await) { }'
check REJECT "await in destructuring pattern"    'var { await } = {};'

# A real AwaitExpression (top-level await) is still valid module syntax, and
# `await` remains an ordinary identifier in Script code -- neither regresses.
check ACCEPT "top-level await expression"        'var v = await Promise.resolve(1); export {v};'
check ACCEPT "await as a property name"          'var o = { await: 1 }; var n = o.await; export {n};'
check ACCEPT "await as a method name"            'var o = { await(){ return 1; } }; export {o};'

echo ""
echo "modules/syntax_positions: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
