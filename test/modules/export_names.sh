#!/bin/bash
# Module export-name early errors (ES2024 §16.2.3.1, §16.2.1.1).
#
# Two distinct rules, both previously unenforced:
#
#   EN1  §16.2.3.1  The ExportedNames of a ModuleItemList must contain no
#        duplicates. This covers every spelling that can collide: `export {x}`
#        twice, two `as` aliases onto one name, `export default` paired with
#        `{y as default}`, two same-named `export function` declarations, and
#        `export * as z` against a local `{x as z}`.
#
#   EN2  §16.2.1.1  A module body's LexicallyDeclaredNames must contain no
#        duplicates. Unlike a Script's, a module's top-level FunctionDeclarations
#        are LEXICAL, so `class F {} function F(){}` is a SyntaxError here while
#        the same pair is legal at Script top level (there the function is
#        var-scoped and simply wins). `export default function F(){}` binds `F`
#        in module scope too, so it is subject to the same rule.
#
# `export * from` is deliberately exempt from EN1: it contributes no
# ExportedName of its own, so two star exports of the same module, or a star
# export alongside any named export, are all legal.
#
# Each case is written to a temporary .mjs and compiled (never run). Reject
# cases must exit non-zero with a syntax error; accept cases must exit zero.
#
# The same fixtures are checked against node when it is available, so the
# expectations are V8-verified rather than assumed.
#
# Usage: bash test/modules/export_names.sh [engine_binary]

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

  # Cross-check the expectation against node when it is available. These are
  # early errors, so `node --check` in module mode settles them without running
  # the module (which would need the imports to resolve).
  if command -v node >/dev/null 2>&1; then
    local noderc nodegot
    node --check "$f" >/dev/null 2>&1; noderc=$?
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

# ---------------------------------------------------------------------------
# EN1: duplicate ExportedNames
# ---------------------------------------------------------------------------

check REJECT "same name exported twice"        'var x; export { x }; export { x };'
check REJECT "two aliases onto one name"       'var x, y; export { x as z }; export { y as z };'
check REJECT "default twice (expr + alias)"    'var x, y; export default x; export { y as default };'
check REJECT "two same-named export functions" 'export function f() {} export function *f() {}'
check REJECT "export function vs export class" 'export function f() {} export class f {}'
check REJECT "export let vs export function"   'export function f() {} export let f = 1;'
check REJECT "export var twice"                'export var v = 1; export var v = 2;'
check REJECT "alias collides with declaration" 'export function f() {} var x; export { x as f };'

# ---------------------------------------------------------------------------
# EN2: duplicate LexicallyDeclaredNames in module code
# ---------------------------------------------------------------------------

check REJECT "class vs function"               'class F {} function F() {}'
check REJECT "function vs class"               'function F() {} class F {}'
check REJECT "let vs class"                    'let x; class x {}'
check REJECT "const vs function"               'const c = 1; function c() {}'
check REJECT "class vs default function"       'class F {} export default function F() {}'
check REJECT "class vs default generator"      'class G {} export default function * G() {}'
check REJECT "class vs default async function" 'class A {} export default async function A() {}'

# ---------------------------------------------------------------------------
# Accepts: distinct names, and the forms that legitimately repeat
# ---------------------------------------------------------------------------

check ACCEPT "single named export"             'var x; export { x };'
check ACCEPT "distinct aliases"                'var x, y; export { x as a }; export { y as b };'
check ACCEPT "one local under two names"       'var x; export { x }; export { x as y };'
check ACCEPT "distinct export functions"       'export function f() {} export function g() {}'
check ACCEPT "default expression alone"        'var x; export default x;'
check ACCEPT "anonymous default function"      'export default function () {}'
check ACCEPT "local aliased to default"        'var x; export { x as default };'
check ACCEPT "export let and const"            'export let a = 1; export const b = 2;'
check ACCEPT "export var with two declarators" 'export var c = 1, d = 2;'
check ACCEPT "export class"                    'export class K {}'
check ACCEPT "named default, no collision"     'class F {} export default function G() {}'
check ACCEPT "anonymous default, no binding"   'class F {} export default function () {}'
check ACCEPT "default function name alone"     'export default function F() {}'
check ACCEPT "anonymous default class"         'class F {} export default class {}'

# A `var` is NOT a LexicallyDeclaredName, so it does not collide with a
# module-level function or class declaration the way a `let`/`const` does.
check ACCEPT "var vs default function"         'var F; export default function G() {}'
check ACCEPT "var alongside function"          'var g; function h() {}'

# `export * from` contributes no ExportedName, so it never collides. These
# resolve for real (unlike the rest, which are compile-only), so the sibling
# modules have to exist: a missing specifier is a link error, not a syntax
# error, and would make the case pass for the wrong reason.
printf 'export var m = 1;\n' > "$TMP/m.mjs"
printf 'export var a = 1;\n' > "$TMP/a.mjs"
printf 'export var b = 1;\n' > "$TMP/b.mjs"
check ACCEPT "star export plus named"          'var x; export { x }; export * from "./m.mjs";'
check ACCEPT "two star exports"                'export * from "./a.mjs"; export * from "./b.mjs";'

# ---------------------------------------------------------------------------
# EN3  §16.2.3.1  A ModuleExportName spelled as a StringLiteral must be
#      well-formed Unicode: a lone surrogate names an export no importer could
#      ever spell.
#
# EN4  §16.2.3.1  `export NamedExports ;` with no `from` clause: it is a Syntax
#      Error if ReferencedBindings contains a ModuleExportName. Without a
#      `from`, a specifier's LOCAL half names a binding in this module, and a
#      string is not an identifier — so `export { "foo" as "bar" }` is rejected
#      even when a matching `function foo(){}` exists. With a `from`, that half
#      is a name in the OTHER module and a string is fine.
# ---------------------------------------------------------------------------
printf 'export var a = 1;\nvar t = 2;\nexport { t as "\xe2\x98\xbf" };\n' > "$TMP/names.mjs"

check REJECT "lone surrogate as export alias"  'export { Foo as "\uD83D" }
function Foo() {}'
check REJECT "lone surrogate in a re-export"   'export { "a" as "\uD83D" } from "./names.mjs";'
check REJECT "lone surrogate in a star alias"  'export * as "\uD83D" from "./names.mjs";'
check REJECT "lone surrogate as import alias"  'import { "\uD83D" as bad } from "./names.mjs";'
check REJECT "string local, no from clause"    'export { "foo" as "bar" }
function foo() {}'
check REJECT "string local, bare specifier"    'var foo; export { "foo" };'

check ACCEPT "string local with a from clause" 'export { "☿" as ok } from "./names.mjs";'
check ACCEPT "string alias with a from clause" 'export { a as "b" } from "./names.mjs";'
check ACCEPT "string alias on a local binding" 'var q = 1; export { q as "nice name" };'
check ACCEPT "string import name"              'import { "☿" as m } from "./names.mjs"; export { m };'
check ACCEPT "string star alias"               'export * as "ns" from "./names.mjs";'
check ACCEPT "paired surrogates in a name"     'var r = 1; export { r as "😀" };'

# ---------------------------------------------------------------------------
# EN5  §16.2.1.1  Every element of ExportedBindings must also occur in the
#      VarDeclaredNames or LexicallyDeclaredNames of the ModuleItemList. Only
#      a LOCAL export has an ExportedBinding — `export {x} from` names `x` in
#      the OTHER module, and a star export names nothing here. The rule is
#      about the item LIST, so the declaration need not precede the export.
# ---------------------------------------------------------------------------
check REJECT "export of an undeclared name"    'export { unresolvable };'
check REJECT "export of a global"              'export { Number };'
check REJECT "export of an undeclared alias"   'export { missing as alias };'
check REJECT "export of a block-scoped name"   'export { blk }; { let blk = 1; }'
check REJECT "export of a name from a function" 'export { deep }; function h() { var deep = 1; }'

check ACCEPT "export declared later"           'export { later }; var later = 1;'
check ACCEPT "export of a hoisted function"    'export { fn }; function fn() {}'
check ACCEPT "export of a class"               'export { C }; class C {}'
check ACCEPT "export of a let"                 'let L = 1; export { L };'
check ACCEPT "export of a var in a block"      'if (1) { var inner = 1; } export { inner };'
check ACCEPT "export of a later declarator"    'var c1 = 1, d1 = 2; export { d1 };'
check ACCEPT "export of an imported binding"   'import { a } from "./names.mjs"; export { a };'
check ACCEPT "export of a namespace binding"   'import * as ns from "./names.mjs"; export { ns };'
# A re-export has no ExportedBinding of its own, so EN5 does not apply to it.
# The name must still RESOLVE in the other module, which is a link-time error
# rather than a syntax one, so the fixture exports it for real.
check ACCEPT "re-export needs no local"        'export { a } from "./names.mjs";'

# An `export`-PREFIXED declaration binds its own name in the same statement,
# so it satisfies the rule by construction — including the destructuring forms,
# whose leaf names no declaration pre-scan reconstructs.
check ACCEPT "export var with a pattern"       'export var { p1 = 1 } = {};'
check ACCEPT "export var with an array pattern" 'export var [p2, p3] = [1, 2];'
check ACCEPT "export let with a pattern"       'export let { p4 } = { p4: 1 };'
check ACCEPT "export var with top-level await" "$(printf 'var w = 1;\nexport var w1 = await w;\nexport var { w2 = await w } = {};')"

echo ""
echo "modules/export_names: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
