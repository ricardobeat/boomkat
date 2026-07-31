// Early (parse-time) SyntaxErrors in and around class bodies.
//
// Each case is compiled in isolation via eval() because these are *early*
// errors: they must be raised while parsing, before any of it runs. A direct
// source-level copy of these shapes would fail to parse this whole file rather
// than exercise one rule at a time.
//
// The engine used to ACCEPT every rejects() case below, silently compiling
// something else:
//
//   CE1  `super.#x` fell through to the shared IdentifierName reader, which
//        hands back a private name with the `#` stripped, so it compiled as
//        `super.x`. ES2022 §13.3.7 SuperProperty is `super.IdentifierName` or
//        `super[Expression]`; a PrivateName is neither.
//   CE2  A lexer failure while looking past `static` was treated as "`static`
//        is the member name". The failed lookahead had already stepped over
//        the offending character, so `static # x;` resumed mid-token and
//        defined a static field named `x`.
//   CE3  A class field initializer may not mention `arguments` (ES2022
//        §15.7.1). The check lived in the identifier path, which the two
//        bare-identifier fast paths under `typeof` return before reaching.
//   CE4  ClassHeritage is `extends LeftHandSideExpression`, but the clause was
//        parsed as an AssignmentExpression, so an arrow function was accepted
//        and only failed later at runtime.
//   CE5  A private getter and setter sharing a name were merged without
//        comparing static-ness, so `get #f(){}` + `static set #f(v){}` passed.
//   CE6  A ScriptBody's LexicallyDeclaredNames must not repeat (ES2024
//        §16.1.1), but two top-level `class` bindings never met the
//        declaration-site scope walk that catches duplicate `let`/`const`.
//
// The complementary accepts() cases matter more than the rejects(): each rule
// above sits next to a legal form that differs by one token (`this.#x` vs
// `super.#x`, an arrow nested in the heritage vs one heading it), and
// over-rejecting those would break working code.
//
// This file is written to run UNMODIFIED under node (with a `print` shim), so
// the expectations are V8-verified rather than self-asserted.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Assert that `src` is an early SyntaxError.
function rejects(src) {
  var threw = null;
  try {
    eval('"use strict";\n' + src);
  } catch (e) {
    threw = e;
  }
  assert(threw !== null && threw instanceof SyntaxError,
         'expected SyntaxError for: ' + src +
         (threw === null ? ' (accepted)' : ' (got ' + threw.name + ')'));
}

// Assert that `src` parses AND runs cleanly. Over-rejection is the more
// damaging failure mode, so the valid shapes are asserted just as hard as the
// invalid ones.
function accepts(src) {
  var threw = null;
  try {
    eval('"use strict";\n' + src);
  } catch (e) {
    threw = e;
  }
  assert(threw === null,
         'expected clean parse+run for: ' + src +
         (threw === null ? '' : ' (got ' + threw.name + ': ' + threw.message + ')'));
}

// ---------------------------------------------------------------------------
// CE1: a private name is not a SuperProperty IdentifierName
// ---------------------------------------------------------------------------

rejects('class C { #x = 1; m() { return super.#x; } }');
rejects('class C { #m() {} m() { return super.#m(); } }');
rejects('class C extends Object { #x = 1; m() { return super.#x; } }');
rejects('class C { #x = 1; m() { delete super.#x; } }');
rejects('class C { #x = 1; Child = class extends C { access() { return super.#x; } }; }');

// The same private name reached through `this` (or any ordinary base) is the
// whole point of private fields and must keep working, including inside a
// subclass method that also uses `super` for something else.
accepts('class C { #x = 5; m() { return this.#x; } }\n' +
        'if (new C().m() !== 5) throw new Error("x");');
accepts('class C { #m() { return 6; } m() { return this.#m(); } }\n' +
        'if (new C().m() !== 6) throw new Error("x");');
accepts('class B { get v() { return 7; } }\n' +
        'class C extends B { #x = 1; m() { return super.v + this.#x; } }\n' +
        'if (new C().m() !== 8) throw new Error("x");');
// `super.x` with an ordinary IdentifierName, and the computed form, are
// untouched by the private-name rejection.
accepts('class B { m() { return 9; } }\n' +
        'class C extends B { m() { return super.m(); } }\n' +
        'if (new C().m() !== 9) throw new Error("x");');
accepts('class B { m() { return 10; } }\n' +
        'class C extends B { m() { return super["m"](); } }\n' +
        'if (new C().m() !== 10) throw new Error("x");');

// ---------------------------------------------------------------------------
// CE2: no whitespace between `#` and the private name
// ---------------------------------------------------------------------------

rejects('class C { static # x; }');
rejects('class C { static # x = 1; }');
rejects('class C { static # m() {} }');
rejects('class C { # x; }');
rejects('class C { static get # g() {} }');

// `static` in each of its three roles (modifier, static block prefix, and an
// ordinary member name) still parses, as does a correctly spelled private
// static member.
accepts('class C { static #x = 11; static read() { return C.#x; } }\n' +
        'if (C.read() !== 11) throw new Error("x");');
accepts('class C { static #m() { return 12; } static read() { return C.#m(); } }\n' +
        'if (C.read() !== 12) throw new Error("x");');
accepts('class C { static { C.built = 13; } }\n' +
        'if (C.built !== 13) throw new Error("x");');
accepts('class C { static static = 14; }\n' +
        'if (C.static !== 14) throw new Error("x");');
accepts('class C { static get p() { return 15; } }\n' +
        'if (C.p !== 15) throw new Error("x");');
accepts('class C { get static() { return 16; } }\n' +
        'if (new C().static !== 16) throw new Error("x");');

// ---------------------------------------------------------------------------
// CE3: `arguments` anywhere in a class field initializer
// ---------------------------------------------------------------------------

rejects('class C { x = arguments; }');
rejects('class C { x = typeof arguments; }');
rejects('class C { x = typeof (arguments); }');
rejects('class C { #x = typeof arguments; }');
rejects('class C { x = () => typeof arguments; }');
rejects('class C { #x = () => typeof arguments; }');
rejects('class C { static x = typeof arguments; }');

// `arguments` is only restricted inside the initializer. A method body owns a
// real arguments object, and `typeof` on any other name (declared or not) must
// keep its ES5 §11.4.3 unresolvable-reference behaviour.
accepts('class C { m() { return arguments.length; } }\n' +
        'if (new C().m(1, 2) !== 2) throw new Error("x");');
accepts('class C { m() { return typeof arguments; } }\n' +
        'if (typeof new C().m() !== "string") throw new Error("x");');
accepts('class C { x = typeof someNameThatIsNotDeclared; }\n' +
        'if (new C().x !== "undefined") throw new Error("x");');
accepts('class C { x = typeof (alsoNotDeclared); }\n' +
        'if (new C().x !== "undefined") throw new Error("x");');
accepts('var argumentsLike = 17;\n' +
        'class C { x = argumentsLike; }\n' +
        'if (new C().x !== 17) throw new Error("x");');

// ---------------------------------------------------------------------------
// CE4: ClassHeritage is a LeftHandSideExpression
// ---------------------------------------------------------------------------

rejects('class C extends () => {} {}');
rejects('class C extends async () => {} {}');
rejects('class C extends x => x {}');
rejects('class C extends (a, b) => {} {}');

// Everything the LeftHandSideExpression grammar does admit as a heritage: a
// plain reference, a call, a member access, parentheses, a class expression,
// `null`, and a comma expression in parens. Crucially, an arrow NESTED inside
// the heritage is legal -- only the head position is restricted.
accepts('class B {}\nclass C extends B {}\n' +
        'if (!(new C() instanceof B)) throw new Error("x");');
accepts('class B {}\nfunction f() { return B; }\nclass C extends f() {}\n' +
        'if (!(new C() instanceof B)) throw new Error("x");');
accepts('class B {}\nvar o = { k: B };\nclass C extends o.k {}\n' +
        'if (!(new C() instanceof B)) throw new Error("x");');
accepts('class B {}\nvar o = { k: B };\nclass C extends o["k"] {}\n' +
        'if (!(new C() instanceof B)) throw new Error("x");');
accepts('class B {}\nclass C extends (B) {}\n' +
        'if (!(new C() instanceof B)) throw new Error("x");');
accepts('class C extends null {}');
accepts('class C extends class { m() { return 18; } } {}\n' +
        'if (new C().m() !== 18) throw new Error("x");');
accepts('class B {}\nclass C extends (0, B) {}\n' +
        'if (!(new C() instanceof B)) throw new Error("x");');
// Arrows nested inside the heritage expression.
accepts('class B {}\nfunction mk(f) { return f(); }\nclass C extends mk(() => B) {}\n' +
        'if (!(new C() instanceof B)) throw new Error("x");');
accepts('class B {}\nclass C extends (() => B)() {}\n' +
        'if (!(new C() instanceof B)) throw new Error("x");');
// Arrows elsewhere are of course unaffected.
accepts('var f = () => 19;\nif (f() !== 19) throw new Error("x");');
accepts('var f = async () => 20;\nif (typeof f().then !== "function") throw new Error("x");');
accepts('var f = x => x + 1;\nif (f(20) !== 21) throw new Error("x");');
accepts('var f = (a, b) => a + b;\nif (f(1, 2) !== 3) throw new Error("x");');

// ---------------------------------------------------------------------------
// CE5: a private accessor pair must agree on static-ness
// ---------------------------------------------------------------------------

rejects('class C { get #f() {} static set #f(v) {} }');
rejects('class C { set #f(v) {} static get #f() {} }');
rejects('class C { static get #f() {} set #f(v) {} }');
rejects('class C { static set #f(v) {} get #f() {} }');

// A pair that DOES agree, in either order and at either home, must work --
// including the round trip through the setter.
accepts('class C { #v = 0; get #f() { return this.#v; } set #f(x) { this.#v = x; }\n' +
        '  run() { this.#f = 22; return this.#f; } }\n' +
        'if (new C().run() !== 22) throw new Error("x");');
accepts('class C { #v = 0; set #f(x) { this.#v = x; } get #f() { return this.#v; }\n' +
        '  run() { this.#f = 23; return this.#f; } }\n' +
        'if (new C().run() !== 23) throw new Error("x");');
accepts('class C { static #v = 0; static get #f() { return C.#v; }\n' +
        '  static set #f(x) { C.#v = x; }\n' +
        '  static run() { C.#f = 24; return C.#f; } }\n' +
        'if (C.run() !== 24) throw new Error("x");');
// A getter-only and a setter-only private accessor are each fine alone, and a
// public accessor pair may still straddle static-ness (the rule is specific to
// private names, which have a single home per class).
accepts('class C { #v = 25; get #f() { return this.#v; } run() { return this.#f; } }\n' +
        'if (new C().run() !== 25) throw new Error("x");');
accepts('class C { get f() { return 26; } static set f(v) {} }\n' +
        'if (new C().f !== 26) throw new Error("x");');

// ---------------------------------------------------------------------------
// CE6: duplicate ScriptBody lexically declared names
// ---------------------------------------------------------------------------

rejects('class A {} class A {}');
rejects('class A {} let A = 1;');
rejects('let A = 1; class A {}');
rejects('class A {} const A = 1;');

// Distinct names, nested-block redeclarations (each block is its own scope),
// and a class EXPRESSION whose name binds only inside its own body are all
// legal. The last shape is the one a naive duplicate check gets wrong.
accepts('class A {} class B {}\n' +
        'if (typeof A !== "function" || typeof B !== "function") throw new Error("x");');
accepts('{ class A {} }\n{ class A {} }');
accepts('function f() { class A {} return typeof A; }\n' +
        'if (f() !== "function") throw new Error("x");');
accepts('let A = class A {};\nif (typeof A !== "function") throw new Error("x");');
accepts('var A = class A {};\nif (typeof A !== "function") throw new Error("x");');
accepts('let A = class A { m() { return A; } };\n' +
        'if (new A().m() !== A) throw new Error("x");');
accepts('let A = 1, B = class A {};\nif (A !== 1) throw new Error("x");');
accepts('let A = class A {}, B = class B {};\n' +
        'if (typeof A !== "function" || typeof B !== "function") throw new Error("x");');
// A `var` may still share a name with a top-level function declaration. Only
// the parse is asserted here: re-declaring the name with `var` currently loses
// the hoisted function binding inside eval, which is a separate pre-existing
// bug in EvalDeclarationInstantiation and not what this file covers.
accepts('function A() { return 27; } var A;');

print('class_early_errors: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
