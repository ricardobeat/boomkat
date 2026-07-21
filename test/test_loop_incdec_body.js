// Regression: for-loops with pre/post inc/dec and a `localVar = loopVar` body
// must not drop the body assignment. An unsound LDREG-before-INC/DEC peephole
// (removed) NOP'd the body's LDREG, making these return 0/wrong values.
function post_inc(){ var s=0; for (var i=0;i<10;i++){ s=i; } return s; }
function pre_inc(){ var s=0; for (var i=0;i<10;++i){ s=i; } return s; }
function post_dec(){ var s=0; for (var i=10;i>0;i--){ s=i; } return s; }
function pre_dec(){ var s=0; for (var i=10;i>0;--i){ s=i; } return s; }
if (post_inc() !== 9) throw "post_inc: " + post_inc();
if (pre_inc()  !== 9) throw "pre_inc: "  + pre_inc();
if (post_dec() !== 1) throw "post_dec: " + post_dec();
if (pre_dec()  !== 1) throw "pre_dec: "  + pre_dec();
// postfix result still correct when consumed
var x=5, y=x++;  if (x!==6 || y!==5) throw "consumed postfix";
print("PASS: loop inc/dec body preserved");
