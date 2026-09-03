// A method's `name` is its property key, and for a NumericLiteral or
// BigIntLiteral key that key is ToString(NumericValue) -- not the literal's
// source text (ES2024 13.2.5.5, SetFunctionName via PropertyDefinitionEvaluation).
//
// Two separate gaps: object-literal methods with a numeric or BigInt key never
// seeded an inferred name at all, so they came out "". Class methods did seed
// one, but from the token's raw text, so `0x10(){}` was named "0x10" and a
// BigInt key kept its trailing `n`.
var out = [];
function t(name, got, want) {
    out.push((got === want ? "ok  " : "FAIL") + " " + name + " => " + JSON.stringify(got));
}

var o = {
    1() {},
    1.5() {},
    0x10() {},
    1e3() {},
    2n() {},
    get 5n() { return 1; },
    get 7() { return 1; },
};
t("obj decimal", o[1].name, "1");
t("obj fractional", o[1.5].name, "1.5");
t("obj hex canonicalizes", o[16].name, "16");
t("obj exponent canonicalizes", o[1000].name, "1000");
t("obj bigint drops n", o[2].name, "2");
t("obj bigint getter", Object.getOwnPropertyDescriptor(o, "5").get.name, "get 5");
t("obj numeric getter", Object.getOwnPropertyDescriptor(o, "7").get.name, "get 7");

class C {
    1() {}
    0x10() {}
    2n() {}
    get 0x20() { return 1; }
    static 3n() {}
}
var c = new C();
t("class decimal", c[1].name, "1");
t("class hex canonicalizes", c[16].name, "16");
t("class bigint drops n", c[2].name, "2");
t("class hex getter", Object.getOwnPropertyDescriptor(C.prototype, "32").get.name, "get 32");
t("class static bigint", C[3].name, "3");

// The name must be exactly the key: no NUL left over from the number formatter.
t("no trailing NUL", c[1].name.length, 1);
t("key matches name", Object.getOwnPropertyNames(o).indexOf("16") >= 0, true);

// An anonymous function *value* under a numeric key is still named by the key,
// while a named one keeps its own name -- same rule as a string key.
var named = function realName() {};
var v = { 1: named, 2: function () {}, 3: () => {} };
t("named value keeps name", v[1].name, "realName");
t("anon value takes key", v[2].name, "2");
t("arrow value takes key", v[3].name, "3");

print(out.join("\n"));
if (out.some(function (l) { return l.indexOf("FAIL") === 0; })) {
    throw new Error("numeric key function name test failed");
}
