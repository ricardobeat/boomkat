// A function can exceed the 64-register loop window while its hot loop uses
// only low registers. A second form puts the loop counter and inputs in high
// registers, forcing the loop tier to alias them to free low slots and publish
// the exact values back to the interpreter.
function ref(n) {
  var i = 0, s = 0;
  for (i = 0; i < n; i++) {
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
  }
  return s;
}

function hot(n) {
  var i = 0, s = 0;
  for (i = 0; i < n; i++) {
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
    s = (s + i) | 0;
  }
  var a0=0,a1=1,a2=2,a3=3,a4=4,a5=5,a6=6,a7=7,a8=8,a9=9;
  var b0=0,b1=1,b2=2,b3=3,b4=4,b5=5,b6=6,b7=7,b8=8,b9=9;
  var c0=0,c1=1,c2=2,c3=3,c4=4,c5=5,c6=6,c7=7,c8=8,c9=9;
  var d0=0,d1=1,d2=2,d3=3,d4=4,d5=5,d6=6,d7=7,d8=8,d9=9;
  var e0=0,e1=1,e2=2,e3=3,e4=4,e5=5,e6=6,e7=7,e8=8,e9=9;
  var f0=0,f1=1,f2=2,f3=3,f4=4,f5=5,f6=6,f7=7,f8=8,f9=9;
  return s + a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + b0 + b1 + b2 + b3 + b4 + b5 + b6 + b7 + b8 + b9 + c0 + c1 + c2 + c3 + c4 + c5 + c6 + c7 + c8 + c9 + d0 + d1 + d2 + d3 + d4 + d5 + d6 + d7 + d8 + d9 + e0 + e1 + e2 + e3 + e4 + e5 + e6 + e7 + e8 + e9 + f0 + f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 + f9;
}

function refAlias(n) {
  var z0 = 0, z69 = 69;
  var i = 0, s = 0;
  for (i = 0; i < n; i++) {
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
  }
  return s;
}

function hotAlias(n) {
  var z0=0, z1=1, z2=2, z3=3, z4=4, z5=5, z6=6, z7=7, z8=8, z9=9, z10=10, z11=11, z12=12, z13=13, z14=14, z15=15, z16=16, z17=17, z18=18, z19=19, z20=20, z21=21, z22=22, z23=23, z24=24, z25=25, z26=26, z27=27, z28=28, z29=29, z30=30, z31=31, z32=32, z33=33, z34=34, z35=35, z36=36, z37=37, z38=38, z39=39, z40=40, z41=41, z42=42, z43=43, z44=44, z45=45, z46=46, z47=47, z48=48, z49=49, z50=50, z51=51, z52=52, z53=53, z54=54, z55=55, z56=56, z57=57, z58=58, z59=59, z60=60, z61=61, z62=62, z63=63, z64=64, z65=65, z66=66, z67=67, z68=68, z69=69;
  var i = 0, s = 0;
  for (i = 0; i < n; i++) {
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
    s = (s + i + z0 + z69) | 0;
  }
  return s + z1 + z2 + z3 + z4 + z5 + z6 + z7 + z8 + z9;
}

var expected = 0, aliasExpected = 0;
for (var k = 0; k < 200; k++) {
  expected += ref(1000) + 270;
  aliasExpected += refAlias(1000) + 45;
}
var total = 0, aliasTotal = 0;
for (var k = 0; k < 200; k++) {
  total += hot(1000);
  aliasTotal += hotAlias(1000);
}
// Wide counts overflow the integer accumulator, so the aliased loop leaves its
// integer speculation, rebuilds itself wider and finally falls back to the
// straight-line tier. Each rebuild must remap the bytecode it reads again.
var wideExpected = 0, wideTotal = 0;
for (var k = 0; k < 40; k++) {
  wideExpected += refAlias(20000) + 45;
  wideTotal += hotAlias(20000);
}
if (total !== expected) {
  print("FAIL: high-register loop total=" + total + " expected=" + expected);
} else if (aliasTotal !== aliasExpected) {
  print("FAIL: aliased loop total=" + aliasTotal + " expected=" + aliasExpected);
} else if (wideTotal !== wideExpected) {
  print("FAIL: widening aliased loop total=" + wideTotal + " expected=" + wideExpected);
} else {
  print("PASS");
}
