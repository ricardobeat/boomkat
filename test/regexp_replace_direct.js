// String.prototype.replace and replaceAll with RegExps from compiled loops, through the
// frameless entry and every case that leaves it.
var out = [];
function run(n, o, re, s, r) { var x, y = 0; for (var i = 0; i < n; i++) { x = s.replace(re, r); y += o.a + o.b; } return x; }
function runa(n, o, re, s, r) { var x, y = 0; for (var i = 0; i < n; i++) { x = s.replaceAll(re, r); y += o.a + o.b; } return x; }
var o = {a:1,b:2};
var C = [[/=/g, "a=b=c", "-"], [/=/, "a=b=c", "--"], [/x*/g, "abc", "_"], [/(b)/g, "abcb", "[$1]"], [/b/g, "abāb", "B"], [/b/g, "abb", "ā"],
         [/=/g, "none", "-"], [/^/gm, "a\nb", ">"], [/a|/g, "baa", ""], [/b/y, "bb", "c"], [/b/gy, "bba", "c"], [/(?<n>b)/g, "ab", "x"], [/b/g, "", "x"], [/abc/g, "abcabc", ""]];
for (var k = 0; k < C.length; k++) {
  var re = C[k][0];
  out.push(run(3000, o, re, C[k][1], C[k][2]), re.lastIndex);
  if (re.global) out.push(runa(3000, o, re, C[k][1], C[k][2]));
}
try { runa(3000, o, /a/, "aa", "b"); } catch (e) { out.push(e.constructor.name); }
var q = /b/g; Object.defineProperty(q, "lastIndex", {writable:false}); try { out.push(run(3000, o, q, "abc", "x")); } catch (e) { out.push(e.constructor.name); }
out.push(run(3000, o, /b/g, "abc", function(m){ return m.toUpperCase(); }));
var p = /b/g; out.push(run(3000, o, p, "abcb", "Z"));
RegExp.prototype[Symbol.replace] = function() { return "hooked"; }; out.push(run(3000, o, /b/g, "abc", "x"));
var want = "[\"a-b-c\",0,\"a-b-c\",\"a--b=c\",0,\"_a_b_c_\",0,\"_a_b_c_\",\"a[b]c[b]\",0,\"a[b]c[b]\",\"aB\u0101B\",0,\"aB\u0101B\",\"a\u0101\u0101\",0,\"a\u0101\u0101\",\"none\",0,\"none\",\">a\\n>b\",0,\">a\\n>b\",\"b\",0,\"b\",\"bb\",0,\"cca\",0,\"cca\",\"ax\",0,\"ax\",\"\",0,\"\",\"\",0,\"\",\"TypeError\",\"TypeError\",\"aBc\",\"aZcZ\",\"hooked\"]";
if (JSON.stringify(out) !== want) console.log("FAIL regexp replace direct: " + JSON.stringify(out));
else console.log("regexp replace direct: ok");
