// Regression: Symbol descriptions had a fixed 256-byte stack buffer that
// truncated longer descriptions byte-wise (possibly mid-UTF-8).
// ES2019 §19.4.3.5 imposes no length bound on a description.

function check(name, cond) {
    print(name + ": " + (cond ? "PASS" : "FAIL"));
}

// Long BMP description round-trips in full.
var d = "z".repeat(300);
var sd = Symbol(d).description;
check("long description length", sd.length === 300);
check("long description round-trip", sd === d);

// Long astral description round-trips without cutting a surrogate pair.
var e = "\u{1F600}".repeat(100);
var se = Symbol(e).description;
check("astral description length", se.length === 200);
check("astral description round-trip", se === e);
check("astral description well-formed", se.slice(-2) === "\u{1F600}");

// Long descriptions still produce distinct symbols usable as property keys.
var a = Symbol(d + "a");
var b = Symbol(d + "b");
var o = {};
o[a] = 1;
o[b] = 2;
check("long-described symbols stay distinct", a !== b && o[a] === 1 && o[b] === 2);

// The undefined-vs-empty distinction (twelve test262 tests depend on it).
check("Symbol() description undefined", Symbol().description === undefined);
check("Symbol('') description empty", Symbol("").description === "");

// A >256-byte private name drives create_hidden_symbol down its heap path.
// Hidden-symbol identity is pointer equality, so storing and reading the
// field is the observable check.
class C {
    #yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy = 42;
    get() { return this.#yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy; }
}
check("long private name hidden symbol", new C().get() === 42);
