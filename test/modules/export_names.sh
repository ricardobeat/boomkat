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

echo ""
echo "modules/export_names: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
