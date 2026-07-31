#!/bin/bash
# Early errors that are specific to TOP-LEVEL code.
#
# This is its own surface because these rules cannot be expressed with eval().
# `new.target` is the motivating case: §16.1.1 forbids it in a StatementList
# "unless the source code containing NewTarget is eval code that is being
# processed by a direct eval that is contained in function code that is not the
# function code of an ArrowFunction", so wrapping a case in eval() from a test
# harness makes it LEGAL and tests the opposite of what is intended. Each case
# therefore has to be a whole file compiled on its own.
#
# For the same reason this is not a node differential: `node file.js` accepts a
# bare top-level `new.target` because it evaluates a script as though wrapped in
# a function. The expectations here follow the spec text and test262
# (language/global-code/new.target.js, language/module-code/early-new-target.js),
# which state the rule directly. The eval-reachable half of the rule, where node
# does agree, is covered in test/new_target_early_errors.js.
#
# Usage: bash test/toplevel_syntax/run.sh [engine_binary]

ENGINE="${1:-./out/duktape_c3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# check <expect: REJECT|ACCEPT> <mode: script|module> <description> <source>
check() {
  local expect="$1" mode="$2" desc="$3" src="$4"
  local f rc got out
  if [ "$mode" = "module" ]; then
    f="$TMP/case.mjs"
    printf '%s\n' "$src" > "$f"
    out=$(timeout 5 "$ENGINE" --module "$f" 2>&1); rc=$?
  else
    f="$TMP/case.js"
    printf '"use strict";\n%s\n' "$src" > "$f"
    out=$(timeout 5 "$ENGINE" "$f" 2>&1); rc=$?
  fi
  if [ "$rc" -eq 124 ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc -- engine HUNG (timeout)"
    return
  fi
  if [ "$rc" -eq 0 ]; then got=ACCEPT; else got=REJECT; fi
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc -- expected $expect got $got"
    echo "$out" | head -2 | sed 's/^/      | /'
  fi
}

# ---------------------------------------------------------------------------
# new.target is a SyntaxError in top-level script code...
# ---------------------------------------------------------------------------

check REJECT script "bare new.target"            'new.target;'
check REJECT script "new.target in a block"      '{ new.target; }'
check REJECT script "new.target in an if body"   'if (true) { new.target; }'
check REJECT script "new.target in a loop"       'for (var i = 0; i < 1; i++) { new.target; }'
check REJECT script "new.target in a try"        'try { new.target; } catch (e) {}'
check REJECT script "new.target assigned"        'var x = new.target;'

# ...and in an arrow written directly there, which has no [[NewTarget]] of its
# own and inherits from an enclosing function that does not exist.
check REJECT script "arrow block body"           '() => { new.target; };'
check REJECT script "arrow expression body"      'var f = () => new.target;'
check REJECT script "nested arrows"              'var f = () => () => new.target;'
check REJECT script "async arrow"                'var f = async () => new.target;'

# ---------------------------------------------------------------------------
# ...and identically in module code (§16.2.1.1).
# ---------------------------------------------------------------------------

check REJECT module "bare new.target"            'new.target;'
check REJECT module "arrow at module top level"  'var f = () => new.target;'

# ---------------------------------------------------------------------------
# Accepts: function code has a [[NewTarget]], so every nesting of it is fine
# ---------------------------------------------------------------------------

check ACCEPT script "inside a function"          'function f() { return new.target; } f();'
check ACCEPT script "inside a constructor"       'class C { constructor() { this.t = new.target; } } new C();'
check ACCEPT script "inside a method"            'var o = { m() { return new.target; } }; o.m();'
check ACCEPT script "arrow inside a function"    'function f() { var g = () => new.target; return g(); } f();'
check ACCEPT script "arrow inside a ctor"        'class C { constructor() { var g = () => new.target; g(); } } new C();'
check ACCEPT script "inside a generator"         'function* g() { yield new.target; } g().next();'
check ACCEPT script "inside an async function"   'async function a() { return new.target; } a();'
check ACCEPT module "inside a function"          'function f() { return new.target; } f();'
check ACCEPT module "arrow inside a function"    'function f() { var g = () => new.target; return g(); } f();'

# `target` is an ordinary identifier and `new` an ordinary operator elsewhere.
check ACCEPT script "identifier named target"    'var target = 1; if (target !== 1) throw new Error("x");'
check ACCEPT script "property named target"      'var o = { target: 2 }; if (o.target !== 2) throw new Error("x");'
check ACCEPT script "ordinary new expression"    'function F() {} var x = new F();'

echo ""
echo "toplevel_syntax: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
