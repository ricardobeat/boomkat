// The literal checks compiled into a pattern body: a prefix, a required
// substring and a whole-literal pattern at every offset around the search
// block edges, in narrow and wide subjects, against hashes taken from node.
var cases = [];
var pats = ["foo", "x=", "=", "NQ_VQ", "^ab", "ab(c)", "q\\d+z", "(\\w)NQ_VQ"];
var flags = ["", "g", "y", "u"];
for (var len of [0, 1, 5, 15, 16, 17, 31, 32, 33, 47, 63, 64, 65, 100, 713]) {
  for (var at of [0, 1, 14, 15, 16, 17, 30, 31, 32, 33, len - 6, len - 5, len - 1]) {
    for (var pi = 0; pi < pats.length; pi++) {
      for (var wide of [false, true]) {
        var lit = pats[pi].replace(/\^|\(|\)|\\d\+|\\w/g, function (m) { return m == "\\d+" ? "12" : m == "\\w" ? "k" : ""; });
        var base = "";
        while (base.length < len) base += wide ? "ab中cdefNQ_V=fo x" : "abcdefNQ_V=fo xq1";
        base = base.slice(0, len);
        if (at < 0 || at > len) continue;
        cases.push([pats[pi], flags[(len + at + pi) % 4], base.slice(0, at) + lit + base.slice(at + lit.length), (at * 7) % 5]);
      }
    }
  }
}
function run(c) {
  var re = new RegExp(c[0], c[1]);
  re.lastIndex = c[3];
  var m = re.exec(c[2]);
  var r = m ? m.index + ":" + m.join("|") : "null";
  re.lastIndex = c[3];
  r += ";" + re.test(c[2]) + ":" + re.lastIndex;
  r += ";" + c[2].replace(re, "-").length + ";" + c[2].split(re).length;
  return r;
}
for (var rep = 0; rep < 3; rep++) {
  var h = 0;
  for (var c of cases) {
    var s = run(c);
    for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  }
  if (cases.length !== 2336 || h !== -1740926017) print("FAIL literal scan " + cases.length + " " + h);
}
print("regexp literal scan ok");
