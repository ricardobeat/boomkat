// A string returned by a getter, a Proxy trap or a toString belongs to the
// pending return value until the next call replaces it. RegExp builtins that
// keep such a string across further user calls must hold their own reference.
var n = 0;
function churn() { n++; return String(n) + "x".repeat(3); }
function fresh(tag) { return { toString() { churn(); return ("ab" + tag).repeat(2) + "-" + tag; } }; }
function getterObj(src, flags) {
  var o = {};
  o[Symbol.match] = true;
  Object.defineProperty(o, "source", { get() { return (src + churn()).slice(0, src.length); } });
  Object.defineProperty(o, "flags", { get() { churn(); return (flags + "").slice(0); } });
  return o;
}
for (var i = 0; i < 100; i++) {
  var r1 = new RegExp(getterObj("a+b" + i, "gi"));
  if (r1.source !== "a+b" + i || r1.flags !== "gi") throw new Error("ctor " + r1.source + r1.flags);
  var r2 = RegExp(getterObj("c" + i, "g"), undefined);
  var r3 = new RegExp(fresh("p" + i), fresh("g").toString().slice(0, 0));
  var r4 = /x/; r4.compile(fresh("k" + i), "g");
  if (!r4.global) throw new Error("compile");
  var ts = RegExp.prototype.toString.call(getterObj("zz" + i, "m"));
  if (ts !== "/zz" + i + "/m") throw new Error("toString " + ts);
  var p = new Proxy(/q/g, { get(t, k) { churn(); var v = t[k]; churn(); return v; } });
  var rr = new RegExp(p);
  if (rr.source !== "q" || rr.flags !== "g") throw new Error("proxy");
  var re = /b/g;
  re.exec = function (s) { churn(); churn(); return RegExp.prototype.exec.call(this, s); };
  var res = re[Symbol.replace](fresh("r" + i), function (m, off, whole) { churn(); return "[" + whole.length + "]"; });
  var res2 = re[Symbol.replace](fresh("r" + i), fresh("rep" + i));
  var m = re[Symbol.match](fresh("m" + i));
  re.lastIndex = 0;
  var sp = re[Symbol.split](fresh("s" + i));
  re.lastIndex = 0;
  var all = [...re[Symbol.matchAll](fresh("a" + i))];
  var se = re[Symbol.search](fresh("e" + i));
  var t = re.test(fresh("t" + i));
}
