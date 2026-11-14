// exec and test of a g or y RegExp in an optimized loop read lastIndex as the start and move it
// to the match's end, or reset it on a failure; a lastIndex that is not a small int is the slow
// path's.
function run(re, s, n, test) {
  var out = [];
  for (var i = 0; i < n; i++) {
    var r = test ? re.test(s) : re.exec(s);
    out.push(test ? r : (r ? r[0] + "@" + r.index : "null"), re.lastIndex);
  }
  return out.slice(-12).join(",");
}
function results() {
  var got = [];
  for (var k = 0; k < 2; k++) {
    got.push(run(/a/g, "aXaa", 3000, k));
    got.push(run(/a/y, "aaXa", 3001, k));
    got.push(run(/(?:)/g, "ab", 3000, k));
    got.push(run(/b*/gu, "\u{1F600}bb", 3000, k));
    var re = /a/g; re.lastIndex = -5; got.push(run(re, "xa", 3000, k));
    re = /a/g; re.lastIndex = 1.5; got.push(run(re, "aaa", 3000, k));
    re = /a/g; re.lastIndex = 99; got.push(run(re, "aaa", 1, k) + ";" + re.lastIndex);
    re = /a/g; Object.defineProperty(re, "lastIndex", { writable: false, value: 0 });
    try { got.push(run(re, "aaa", 3000, k)); } catch (e) { got.push(e.constructor.name + ";" + re.lastIndex); }
    re = /a/y; re.lastIndex = "1"; got.push(run(re, "aaa", 3000, k));
    got.push(run(/(a)|b/g, "ab", 3000, k));
  }
  return got;
}
var expected = ["a@3,4,null,0,a@0,1,a@2,3,a@3,4,null,0","a@1,2,null,0,a@0,1,a@1,2,null,0,a@0,1","@0,0,@0,0,@0,0,@0,0,@0,0,@0,0","@0,0,@0,0,@0,0,@0,0,@0,0,@0,0","a@1,2,null,0,a@1,2,null,0,a@1,2,null,0","null,0,a@0,1,a@1,2,a@2,3,null,0,a@0,1","null,0;0","TypeError;0","null,0,a@0,1,a@1,2,a@2,3,null,0,a@0,1","a@0,1,b@1,2,null,0,a@0,1,b@1,2,null,0","true,4,false,0,true,1,true,3,true,4,false,0","true,2,false,0,true,1,true,2,false,0,true,1","true,0,true,0,true,0,true,0,true,0,true,0","true,0,true,0,true,0,true,0,true,0,true,0","true,2,false,0,true,2,false,0,true,2,false,0","false,0,true,1,true,2,true,3,false,0,true,1","false,0;0","TypeError;0","false,0,true,1,true,2,true,3,false,0,true,1","true,1,true,2,false,0,true,1,true,2,false,0"];
var got = results();
for (var i = 0; i < expected.length; i++) {
  if (got[i] !== expected[i]) throw new Error("case " + i + ": " + got[i] + " !== " + expected[i]);
}
