// A loop-local value is written before its first read and observed only after
// the loop. Its physical VM register is above the loop tier's 64-slot window.
function exitOnlyAlias(n) {
  var z0=0, z1=1, z2=2, z3=3, z4=4, z5=5, z6=6, z7=7, z8=8, z9=9, z10=10, z11=11, z12=12, z13=13, z14=14, z15=15, z16=16, z17=17, z18=18, z19=19, z20=20, z21=21, z22=22, z23=23, z24=24, z25=25, z26=26, z27=27, z28=28, z29=29, z30=30, z31=31, z32=32, z33=33, z34=34, z35=35, z36=36, z37=37, z38=38, z39=39, z40=40, z41=41, z42=42, z43=43, z44=44, z45=45, z46=46, z47=47, z48=48, z49=49, z50=50, z51=51, z52=52, z53=53, z54=54, z55=55, z56=56, z57=57, z58=58, z59=59, z60=60, z61=61, z62=62, z63=63, z64=64, z65=65, z66=66, z67=67, z68=68, z69=69;
  var i=0, result=0;
  for (i=0; i<n; i++) result=(i ^ (i >>> 2)) + (i & 31);
  return result + z0+z1+z2+z3+z4+z5+z6+z7+z8+z9+z10+z11+z12+z13+z14+z15+z16+z17+z18+z19+z20+z21+z22+z23+z24+z25+z26+z27+z28+z29+z30+z31+z32+z33+z34+z35+z36+z37+z38+z39+z40+z41+z42+z43+z44+z45+z46+z47+z48+z49+z50+z51+z52+z53+z54+z55+z56+z57+z58+z59+z60+z61+z62+z63+z64+z65+z66+z67+z68+z69;
}
for (var j=0; j<300; j++) {
  var n=3+(j % 71), k=n-1;
  var expected=(k ^ (k >>> 2))+(k & 31)+2415;
  if (exitOnlyAlias(n)!==expected) throw new Error('exit-only aliased register '+n);
}
print('exit-only high register: PASS');

// The immediate in the post-loop load is not a use of the matching register.
// Keep this separate from exitOnlyAlias: its loop temporary is dead on exit.
function phiProbe(n) {
  var i=0, t=0;
  for (i=0; i<n; i++) t=(i*3)|0;
  return 4;
}
for (var j=0; j<400; j++) if (phiProbe(30)!==4) throw new Error('dead loop temporary');
print('dead exit temporary: PASS');

// The inner loop's continuation branches back to the outer loop. Values from
// the inner loop and values used by a call must survive the compiled exit.
function nestedRecovery(n, consume) {
  var sum=0, i=0, j=0, last=0;
  for (i=0; i<n; i++) {
    for (j=0; j<8; j++) last=(i*3+j)|0;
    if ((i&1)===0) sum+=consume(last); else sum-=consume(last);
  }
  return sum;
}
var observed=0;
function observe(x) { observed++; return x+1; }
for (var round=0; round<200; round++) {
  var n=1+(round%19), expected=0;
  for (var q=0; q<n; q++) expected+=(q&1) ? -(q*3+8) : q*3+8;
  var before=observed;
  if (nestedRecovery(n, observe)!==expected || observed-before!==n)
    throw new Error('nested recovery');
}
print('nested continuation: PASS');

// A coercion failure after a loop write transfers to a handler that reads it.
function handlerRecovery(values) {
  var last=-1, total=0;
  try {
    for (var i=0; i<8; i++) { last=i; total+=values[i]+i; }
  } catch (e) { return last; }
  return total;
}
var inputs=[0,1,2,3,4,5,6,7];
for (var warm=0; warm<200; warm++) if (handlerRecovery(inputs)!==56) throw Error('handler warmup');
var coercions=0;
inputs[4]={valueOf:function(){coercions++; throw Error('coercion');}};
if (handlerRecovery(inputs)!==4 || coercions!==1) throw Error('handler recovery');
print('exception continuation: PASS');
