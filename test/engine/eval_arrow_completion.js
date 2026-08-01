// Arrow bodies compiled inside eval source must not accumulate a completion value.
//
// eval's top-level context allocates eval_acc_reg and has every expression
// statement store its value there, so eval can return the last statement's
// value. An arrow body nested in that source is a SEPARATE frame: it returns
// via `return`, and the eval accumulator register number means nothing in it.
// When the "inside eval code" flag (needed so new.target keeps its eval rules
// inside an arrow) was conflated with "accumulate a completion value", arrow
// bodies inherited the accumulator with register 0 — the arrow's first
// parameter — so every expression statement silently overwrote it.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// --- The core defect: a discarded expression statement must not touch params.

assert(eval("((x)=>{Math.max(1,2); return x+100})(7)") === 107,
       "discarded call does not clobber the single parameter");
assert(eval("((x,y)=>{Math.max(1,2); return x+y})(3,4)") === 7,
       "discarded call does not clobber either of two parameters");

// A bare literal is enough — the trigger is any expression statement, not a call.
assert(eval("((x)=>{ 42; return x+100})(7)") === 107,
       "discarded literal does not clobber the parameter");
assert(eval("((x)=>{ 1; 2; return x+100})(7)") === 107,
       "several discarded literals do not clobber the parameter");
assert(eval("((x)=>{Math.max(1,2); Math.min(3,4); String(5); return x})(7)") === 7,
       "several discarded calls do not clobber the parameter");

// The clobber stored the statement's exact value, so vary the value to pin it.
assert(eval("((x)=>{ 999; return x })(7)") === 7, "literal 999 does not land in param 0");
assert(eval("((x)=>{ 'AAA'; return x })(7)") === 7, "a string does not land in param 0");
assert(eval("((x,y)=>{ 555; return y })(1,2)") === 2, "param 1 stays intact");

// --- Parameter shapes: defaults, rest, none at all.

assert(eval("((x, y=5)=>{42; return x+y})(7)") === 12,
       "default parameter survives a discarded statement");
assert(eval("((...r)=>{42; return r[0]})(9)") === 9,
       "rest parameter survives a discarded statement");
// With no parameters, register 0 is the first body local instead.
assert(eval("(()=>{ var v=3; 42; return v})()") === 3,
       "a zero-parameter arrow's first local survives");

// --- Nesting: arrow in arrow, and arrow inside a function inside eval.

assert(eval("((x)=>(y)=>{ 42; return x+y})(10)(5)") === 15,
       "nested arrow does not clobber the outer arrow's captured parameter");
assert(eval("(function(a){ return ((x)=>{42; return x+a})(7) })(100)") === 107,
       "arrow inside a function inside eval keeps its parameter");
assert(eval("(function(){ return ((x)=>{42; return x+1})(7) })()") === 8,
       "arrow inside a function inside eval returns the right value");

// --- A discarded call as the LAST statement of the body.

assert(eval("((x)=>{ Math.max(1,2); })(7)") === undefined,
       "arrow whose last statement is a discarded call returns undefined");
assert(eval("var z; ((x)=>{ z=x; Math.max(8,9); })(7); z") === 7,
       "a trailing discarded call does not corrupt an earlier read of the param");

// --- eval's own completion value must still work (the half of the flag we kept).

assert(eval("1+1") === 2, "eval returns the last expression statement's value");
assert(eval("var a=1; a+5") === 6, "eval completion value after a declaration");
assert(eval("if(true){42}") === 42, "eval completion value from an if body");
assert(eval("for(var i=0;i<3;i++){i*2}") === 4, "eval completion value from a for body");
assert(eval("try{5}finally{9}") === 5, "eval completion value from try/finally");
assert(eval("switch(1){case 1: 77;}") === 77, "eval completion value from a switch case");
assert(eval("var n=0; while(n<2){n++; n*10}") === 20, "eval completion value from a while body");
// An arrow's inner statements must not leak into the eval completion value.
assert(eval("var f=(x)=>{ 99; return x}; 7") === 7,
       "an arrow body does not leak into eval's completion value");
assert(eval("((x)=>{1;2;3})(0); 'tail'") === "tail",
       "a called arrow does not leak into eval's completion value");

// --- new.target rules still apply inside an arrow in eval code.
// This is why the lexical flag must keep propagating into arrow bodies.

var threw = false;
try { (0, eval)("(()=>new.target)()"); } catch (e) { threw = (e instanceof SyntaxError); }
assert(threw, "new.target in an arrow in indirect eval is a SyntaxError");

threw = false;
try { (0, eval)("new.target"); } catch (e) { threw = (e instanceof SyntaxError); }
assert(threw, "new.target at indirect eval top level is a SyntaxError");

assert((function () { return String(eval("new.target")); })() === "undefined",
       "new.target in direct eval inside a function is allowed");
assert((function () { return String(eval("(()=>new.target)()")); })() === "undefined",
       "new.target in an arrow in direct eval inside a function is allowed");

// --- Non-eval path must be unaffected (it always was, but pin it).

assert(((x) => { Math.max(1, 2); return x + 100; })(7) === 107,
       "non-eval arrow keeps its parameter");
assert(((x) => { 999; return x; })(7) === 7,
       "non-eval arrow ignores a discarded literal");

print("engine/eval_arrow_completion: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
