// RegExp.prototype.source and toString escape `/` and line terminators for a
// pattern of any length, and Error.prototype.toString keeps long messages.
var pass = 0, fail = 0;
function t(name, got, want) {
  if (got === want) { pass++; } else { fail++; print("FAIL: " + name + ": got " + got + ", want " + want); }
}

t("empty", new RegExp("").source, "(?:)");
t("slash", new RegExp("a/b").source, "a\\/b");
t("slash in class", new RegExp("[/]").source, "[/]");
t("escaped slash", new RegExp("a\\/b").source, "a\\/b");
t("escaped bracket", new RegExp("\\[/]").source, "\\[\\/]");
t("LF", new RegExp("a\nb").source, "a\\nb");
t("CR", new RegExp("a\rb").source, "a\\rb");
t("LS", new RegExp("a\u2028b").source, "a\\u2028b");
t("PS", new RegExp("a\u2029b").source, "a\\u2029b");
t("backslash LF", new RegExp("a\\\nb").source, "a\\nb");
t("toString", String(new RegExp("a/b", "gi")), "/a\\/b/gi");
t("toString empty", String(new RegExp("")), "/(?:)/");

var L = 20000;
t("long source", new RegExp("a".repeat(L)).source.length, L);
t("long source slashes", new RegExp("/".repeat(L)).source.length, 2 * L);
t("long toString", String(new RegExp("a".repeat(L), "g")).length, L + 3);
t("long toString slashes", String(new RegExp("/".repeat(L))).length, 2 * L + 2);

var m = "m".repeat(L);
t("Error toString", String(new Error(m)).length, L + 7);
t("Error toString name", Error.prototype.toString.call({ name: "N".repeat(L), message: m }).length, 2 * L + 2);
t("Error toString NUL", Error.prototype.toString.call({ name: "N", message: "a\0b" }), "N: a\0b");

print(pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("regexp_source_escape failed");
