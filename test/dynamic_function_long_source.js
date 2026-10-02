// Function, GeneratorFunction and AsyncFunction accept parameter lists and
// bodies of any length, and report the spec's source text.
var pass = 0, fail = 0;
function t(name, got, want) {
  if (got === want) { pass++; } else { fail++; print("FAIL: " + name + ": got " + got + ", want " + want); }
}

var L = 40000;
t("long body", new Function("return '" + "x".repeat(L) + "'")().length, L);
t("long body statements", new Function("var s = 0;" + "s += 1;".repeat(L / 7) + "return s")(), Math.floor(L / 7));

var names = [], args = [];
for (var i = 0; i < 400; i++) { names.push("param" + i); args.push(i); }
var many = new Function(names.join(","), "return param0 + param399");
t("many params", many.apply(null, args), 399);
t("many params length", many.length, 400);
t("last param", new Function(names.join(","), "return param399").apply(null, args), 399);

t("toString", String(new Function("a", "b", "return a + b")),
  "function anonymous(a,b\n) {\nreturn a + b\n}");
t("toString no args", String(new Function()), "function anonymous(\n) {\n\n}");
t("toString long", String(new Function("return '" + "y".repeat(L) + "'")).length, L + 35);

t("comment in params", new Function("a, b //", "return a + b")(1, 2), 3);
var threw = false;
try { new Function("*/) {", "}") ; } catch (e) { threw = e instanceof SyntaxError; }
t("param text must parse on its own", threw, true);

var Gen = Object.getPrototypeOf(function* () {}).constructor;
var g = new Gen("a", "yield a; yield '" + "z".repeat(L) + "'")(5);
t("generator long body", g.next().value, 5);
t("generator long body 2", g.next().value.length, L);
t("generator toString", String(new Gen("a", "yield a")), "function* anonymous(a\n) {\nyield a\n}");

var Async = Object.getPrototypeOf(async function () {}).constructor;
t("async toString", String(new Async("a", "await a")), "async function anonymous(a\n) {\nawait a\n}");
t("async instance", Object.getPrototypeOf(new Async("return 1")) === Async.prototype, true);

var AsyncGen = Object.getPrototypeOf(async function* () {}).constructor;
t("async generator toString", String(new AsyncGen("yield 1")), "async function* anonymous(\n) {\nyield 1\n}");

t("non-string args", new Function(1 === 1 ? { toString: function () { return "a"; } } : "", { toString: function () { return "return a * 2"; } })(21), 42);
var order = [];
try {
  new Function({ toString: function () { order.push("p"); return "a"; } },
               { toString: function () { order.push("b"); return "return 1"; } });
} catch (e) {}
t("coercion order", order.join(), "p,b");
var symThrew = false;
try { new Function(Symbol(), "return 1"); } catch (e) { symThrew = e instanceof TypeError; }
t("symbol param throws", symThrew, true);

print(pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("dynamic_function_long_source failed");
