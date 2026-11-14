var x = "global";
function direct() { var x = "local"; return eval("x"); }
function paren() { var x = "local"; return (eval)("x"); }
function paren2() { var x = "local"; return ((eval))("x"); }
function indirect() { var x = "local"; return (0, eval)("x"); }
function alias() { var x = "local"; var e = eval; return e("x"); }
function opt() { var x = "local"; return eval?.("x"); }
function tagged() { var x = "local"; try { return eval`x`; } catch (e) { return "throws"; } }
function viaDeferred() { function inner() { var x = "inner"; return (eval)("x"); } return inner(); }
var got = [direct(), paren(), paren2(), indirect(), alias(), opt(), tagged(), viaDeferred()].join();
var want = "local,local,local,global,global,global,x,inner";
console.log(got === want ? "eval reference forms: ok" : "FAIL eval reference forms: " + got);
