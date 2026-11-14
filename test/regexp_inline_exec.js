// exec and test of plain RegExps from optimized loops, through the in-line body call and every case that leaves it.
var out = [];
function run(n, o, re, s) { var r, x = 0; for (var i = 0; i < n; i++) { r = re.exec(s); x += o.a + o.b; } return r; }
function runt(n, o, re, s) { var r, x = 0; for (var i = 0; i < n; i++) { r = re.test(s); x += o.a + o.b; } return r; }
var o = {a:1,b:2};
var cases = [[/b(c)?/, "abc"], [/b(c)?/, "xyz"], [/āx/, "aāx"], [/(?<n>q)/, "aq"], [/x/d, "zx"], [/\ud83d/u, "😀"], [/\ud83d/, "😀"], [/a/i, "A"], [/./s, "\n"]];
for (var k = 0; k < cases.length; k++) {
  var m = run(3000, o, cases[k][0], cases[k][1]);
  out.push(JSON.stringify(m), m && m.index, m && JSON.stringify(m.groups), m && m.indices && JSON.stringify(m.indices), runt(3000, o, cases[k][0], cases[k][1]));
}
out.push(JSON.stringify(run(3000, o, /a/, 12)), JSON.stringify(run(3000, o, /1/, 12)));
var g = /a/g; out.push(run(3, o, g, "aaa") && g.lastIndex);
class R extends RegExp { exec(s) { return null; } }
out.push(runt(3000, o, new R("a"), "a"));
var p = /a/; p.exec = function() { return {}; }; out.push(runt(3000, o, p, "zz"));
try { run(3000, o, /a/, Symbol()); } catch (e) { out.push(e.constructor.name); }
var q = /b/; Object.defineProperty(q, "lastIndex", {writable:false}); out.push(JSON.stringify(run(3000, o, q, "abc")));
RegExp.prototype.exec = function() { return null; }; out.push(runt(3000, o, /a/, "a"));
console.log(out.join("|"));
