#!/bin/bash
# Compile-error messages must never be empty.
#
# Several parse paths returned COMPILE_ERROR without recording a message,
# so the CLI printed "SyntaxError:  (line 0, col 0)" for common typos like
# `var ] x` or `class {`. Each case below must fail AND name what went
# wrong. The first line of the engine's stderr is `SyntaxError: <msg>
# (line L, col C)`; the empty-message form is `(line 0, col 0)`.

ENGINE="${1:-./out/boomkat}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# check <description> <source>
check() {
  local desc="$1" src="$2"
  local f rc out
  f="$TMP/case.js"
  printf '%s\n' "$src" > "$f"
  out=$(timeout 5 "$ENGINE" "$f" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc -- compiled cleanly (expected a SyntaxError)"
    return
  fi
  if [ "$rc" -eq 124 ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc -- engine HUNG (timeout)"
    return
  fi
  first=$(printf '%s\n' "$out" | head -1)
  case "$first" in
    "SyntaxError:  (line 0, col 0)")
      FAIL=$((FAIL + 1))
      echo "FAIL: $desc -- empty error message"
      ;;
    SyntaxError:*)
      PASS=$((PASS + 1))
      ;;
    *)
      FAIL=$((FAIL + 1))
      echo "FAIL: $desc -- no SyntaxError reported: $first"
      ;;
  esac
}

# Binding declarations
check "var with a stray ]"            'var ] x'
check "var with a paren"              'var ( x'
check "const with a tilde"            'const ~'
check "dangling declarator comma"     'var x = 1,'
check "let with an object pattern"    'let {'
check "let with an array pattern"     'let ['
check "destructuring, bad property"   'var { a: '

# Statements
check "return at top level"           'return }'
check "class without a name"          'class {'
check "generator method, no name"     'class C { *'

# Expressions
check "unclosed object literal"       'var x = {'
check "lone paren object literal"     '({'
check "member access, nothing after"  'x.'
check "optional member, nothing after" 'x?.'
check "new then dot"                  'new .'
check "new member, nothing after"     'new C.'
check "undeclared private name"       'x.#x'
check "super with no follower"        'var x = super'
check "super outside a class"         'super.#x'

# A YieldExpression operand inherits the enclosing [In] parameter, so an `in`
# is no more available inside it than outside it in a `[~In]` for head
# (`yield [no LineTerminator here] AssignmentExpression[?In, +Yield]`). These
# parsed before, because binary_expr consumes forbid_in on the way down and the
# yield operand is parsed below that point. test262:
# language/expressions/yield/{in,star-in}-iteration-stmt.js.
check "yield operand with in, for-init"   'function* g(){ for (yield "" in {}; ; ) ; }'
check "yield* operand with in, for-init"  'function* g(){ for (yield * "" in {}; ; ) ; }'

# An ArrowFunction is AssignmentExpression-level and may not appear directly
# as a binary operand (ES §13.16, §13.15). These must stay rejected: the
# complement of test/test_arrow_call_arg_binary_operand.js, which fixed an
# over-rejection of an arrow passed as a CALL ARGUMENT in the same position.
# node rejects all of these too.
check "bare arrow after +"            '1 + () => 2'
check "bare arrow after &&"           'true && x => 1'
check "bare arrow after ??"           'null ?? () => 1'
check "bare arrow in an initializer"  'var x = 1 + (y) => 2'

# Control: a path that always had a message still reports it.
check "expression with a bad token"   'x ='

echo ""
echo "compile_error_messages: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
