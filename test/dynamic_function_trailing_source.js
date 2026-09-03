// CreateDynamicFunction assembles `(params\n){\nbody\n}` and parses it as ONE
// FunctionExpression (ES2024 20.2.1.1.1 step 21). A body that closes the
// function early therefore leaves source behind, and that is a SyntaxError --
// the parser stopped at the matching `}` and silently dropped the rest, so
// `Function("}")` built a working empty function instead of throwing.
var out = [];
function t(name, got, want) {
    out.push((got === want ? "ok  " : "FAIL") + " " + name + " => " + String(got));
}
function throwsSyntax(src) {
    try { Function(src); } catch (e) { return e instanceof SyntaxError; }
    return false;
}

t("bare close brace", throwsSyntax("}"), true);
t("statement then brace", throwsSyntax("1+1}"), true);
t("shorthand object then brace", throwsSyntax("b = {a}}"), true);
t("closes then declares", throwsSyntax("}; var leaked = 1"), true);
t("unbalanced open still throws", throwsSyntax("{"), true);
t("stray close paren still throws", throwsSyntax(")"), true);

// Bodies that legitimately contain braces must still compile.
t("block body", Function("{ return 1; }")(), 1);
t("object literal", Function("return {x:2}")().x, 2);
t("nested function", Function("return function(){ return 3; }")()(), 3);
t("brace in string", Function("return '}'")(), "}");
t("brace in comment", Function("// }\nreturn 4")(), 4);
t("empty body", Function("")(), undefined);

// The same rule applies to the other dynamic-function constructors.
var GF = Object.getPrototypeOf(function* () {}).constructor;
var AF = Object.getPrototypeOf(async function () {}).constructor;
function throwsSyntaxCtor(C, src) {
    try { C(src); } catch (e) { return e instanceof SyntaxError; }
    return false;
}
t("generator trailing brace", throwsSyntaxCtor(GF, "}"), true);
t("async trailing brace", throwsSyntaxCtor(AF, "}"), true);
t("generator still works", [].concat.apply([], [Array.from(GF("yield 1; yield 2")())]).join(","), "1,2");

print(out.join("\n"));
if (out.some(function (l) { return l.indexOf("FAIL") === 0; })) {
    throw new Error("dynamic function trailing source test failed");
}
