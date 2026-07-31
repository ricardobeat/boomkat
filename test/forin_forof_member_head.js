// A for-in/for-of head whose LHS is a member expression is parsed twice and
// then discarded (the real store is re-parsed per iteration from a lexer
// snapshot). Those discarded parses used to leave three pieces of compiler
// state behind:
//
//   * call_prop_obj_reg -- the method-call receiver. Left set, the NEXT call
//     in the same function took the method-call path, so the callee's
//     speculatively stripped GETVAR/GETGLOBAL was never restored and the call
//     dispatched on a register nothing ever wrote ("string is not a function").
//   * the emitted GETPROP/LDCONST themselves, which ran once before the loop
//     and clobbered whichever live local owned the scratch register.
//   * last_was_getvar/last_was_getglobal, the CALL_VAR fusion anchor.
//
// The blast radius was the whole enclosing function, not the loop, and the
// register clobber corrupted unrelated locals silently.
//
// Runs unmodified under node ('use strict' matters: sloppy node would create
// implicit globals for some shapes and diverge).
'use strict';
if (typeof print === 'undefined') { var print = function (s) { console.log(s); }; }
var pass=0, fail=0;
function eq(a,b,m){ if(a===b){pass++;} else {fail++; print('FAIL '+m+': got '+String(a)+' want '+String(b));} }
function kind(fn){ try{ fn(); }catch(e){ return e.constructor.name; } return 'NOTHROW'; }

function eq(a,b,m){ if(a===b){pass++;} else {fail++; print('FAIL '+m+': got '+JSON.stringify(a)+' want '+JSON.stringify(b));} }

// ---- {for-in, for-of} x {o.p, a[i], o.a.b} x {preceding loop kind} x {scope} ----
// Each case ASSIGNS and we check the assigned value, then call a global fn
// (print via a wrapper) to exercise the post-loop call path.
function nop(){ return 1; }

// --- preceded by NOTHING ---
(function(){ var o={}; for(o.p in {a:1}){} eq(o.p,'a','in/o.p/none/fn'); nop(); })();
(function(){ var o={}; for(o.p of [4]){} eq(o.p,4,'of/o.p/none/fn'); nop(); })();
(function(){ var a=[]; for(a[0] in {q:1}){} eq(a[0],'q','in/a[i]/none/fn'); nop(); })();
(function(){ var a=[],i=1; for(a[i] of [5]){} eq(a[1],5,'of/a[i]/none/fn'); nop(); })();
(function(){ var o={a:{}}; for(o.a.b in {z:1}){} eq(o.a.b,'z','in/o.a.b/none/fn'); nop(); })();
(function(){ var o={a:{}}; for(o.a.b of [6]){} eq(o.a.b,6,'of/o.a.b/none/fn'); nop(); })();

// --- preceded by a BARE-IDENTIFIER loop ---
(function(){ var o={},k; for(k in {z:1}){} for(o.p in {a:1}){} eq(o.p,'a','in/o.p/bareid'); eq(k,'z','bareid retained'); nop(); })();
(function(){ var o={},k; for(k of [9]){} for(o.p of [4]){} eq(o.p,4,'of/o.p/bareid'); eq(k,9,'bareid of retained'); nop(); })();

// --- preceded by a DECLARING loop (var/let/const) ---
// NOTE: `for (var v in o)` at FUNCTION scope loses v (engine yields undefined,
// node yields 'z'). That is a pre-existing bug unrelated to member-target
// heads -- it reproduces with the member loop removed and on the d6b92443
// baseline -- so this case only asserts the member target, not v.
(function(){ var o={}; for(var v in {z:1}){} for(o.p in {a:1}){} eq(o.p,'a','in/o.p/var'); nop(); })();
(function(){ var o={}; for(let l of [7]){} for(o.p in {a:1}){} eq(o.p,'a','in/o.p/let'); nop(); })();
(function(){ var o={}; for(const c of [7]){} for(o.p of [4]){} eq(o.p,4,'of/o.p/const'); nop(); })();

// --- preceded by ANOTHER MEMBER-TARGET loop (the original repro) ---
(function(){ var mt={}; for(mt.p in {a:1}){} for(mt.q in {b:1}){} eq(mt.p,'a','in/first'); eq(mt.q,'b','in/second'); nop(); })();
(function(){ var mt={}; for(mt.p of [1]){} for(mt.q of [2]){} eq(mt.p,1,'of/first'); eq(mt.q,2,'of/second'); nop(); })();
(function(){ var mt={}; for(mt.p in {a:1}){} for(mt.q of [2]){} eq(mt.p,'a','mix in-then-of 1'); eq(mt.q,2,'mix in-then-of 2'); nop(); })();

// --- preceded by a DESTRUCTURING loop ---
(function(){ var o={},dp,dq; for([dp,dq] of [[1,2]]){} for(o.p in {a:1}){} eq(o.p,'a','in/o.p/destr'); eq(dp,1,'destr dp'); nop(); })();
(function(){ var o={},dm; for({m:dm} of [{m:9}]){} for(o.p of [4]){} eq(o.p,4,'of/o.p/destr'); eq(dm,9,'destr dm'); nop(); })();

// --- GLOBAL scope ---
var go={}; for(go.p in {a:1}){} eq(go.p,'a','in/o.p/global'); nop();
var go2={}; for(go2.p in {a:1}){} for(go2.q in {b:1}){} eq(go2.q,'b','in/global/2loops'); nop();
var ga=[]; for(ga[0] of [5]){} eq(ga[0],5,'of/a[i]/global'); nop();

// --- NESTED function ---
(function(){ return (function(){ var o={}; for(o.p in {a:1}){} for(o.q in {b:1}){} eq(o.q,'b','in/nested fn'); nop(); })(); })();

// --- METHOD body ---
var obj={ m:function(){ var o={}; for(o.p in {a:1}){} for(o.q in {b:1}){} eq(o.q,'b','in/method'); nop(); return o.p; } };
eq(obj.m(),'a','method returns');

// --- loop BODY runs and target is live inside it ---
(function(){ var o={},seen=''; for(o.p in {a:1,b:2,c:3}){ seen+=o.p; } eq(seen,'abc','body sees target'); eq(o.p,'c','last key'); nop(); })();
(function(){ var o={},sum=0; for(o.v of [1,2,3]){ sum+=o.v; } eq(sum,6,'of body sees target'); eq(o.v,3,'last value'); nop(); })();

// --- member target re-evaluated each iteration (spec: fresh reference) ---
(function(){ var arr=[{},{}], i=0, log=[];
  for(arr[i++].k in {x:1,y:1}){ log.push(i); }
  eq(log.length,2,'reeval count'); eq(arr[0].k,'x','reeval slot0'); eq(arr[1].k,'y','reeval slot1'); nop(); })();

// --- call immediately after loop with NO other statement (the crash shape) ---
(function(){ var o={}; for(o.p in {a:1}){} nop(); eq(o.p,'a','call-right-after'); })();


// ---- rejection / error-path shapes ----


// A member head whose OBJECT is undefined/null must throw TypeError when the
// store executes (i.e. only if the iterable is non-empty).
eq(kind(function(){ var u; for(u.p in {a:1}){} }),'TypeError','undef obj, nonempty in');
eq(kind(function(){ var u; for(u.p of [1]){} }),'TypeError','undef obj, nonempty of');
eq(kind(function(){ var u; for(u.p in {}){} }),'NOTHROW','undef obj, EMPTY in -> no store');
eq(kind(function(){ var u; for(u.p of []){} }),'NOTHROW','undef obj, EMPTY of -> no store');
eq(kind(function(){ var n=null; for(n.p in {a:1}){} }),'TypeError','null obj in');

// The object expression is re-evaluated per iteration, so a getter that starts
// returning undefined mid-loop throws.
eq(kind(function(){ var i=0, host={ get o(){ return i++ ? undefined : {}; } };
  for(host.o.p in {a:1,b:2}){} }),'TypeError','obj getter turns undefined');

// for-of over a non-iterable throws regardless of the member head.
eq(kind(function(){ var o={}; for(o.p of 5){} }),'TypeError','for-of non-iterable');
eq(kind(function(){ var o={}; for(o.p of {}){} }),'TypeError','for-of plain object');

// for-in over null/undefined is a NO-OP (not a throw) per spec.
eq(kind(function(){ var o={}; for(o.p in null){} }),'NOTHROW','for-in null is noop');
eq(kind(function(){ var o={}; for(o.p in undefined){} }),'NOTHROW','for-in undefined is noop');

// Assigning to a member of a frozen object is a strict-mode TypeError.
eq(kind(function(){ var f=Object.freeze({p:0}); for(f.p in {a:1}){} }),'TypeError','frozen target in');
eq(kind(function(){ var f=Object.freeze({p:0}); for(f.p of [1]){} }),'TypeError','frozen target of');

// A setter on the target that throws propagates.
eq(kind(function(){ var o={ set p(v){ throw new RangeError('x'); } }; for(o.p in {a:1}){} }),'RangeError','throwing setter in');

// A computed key expression that throws propagates, and is evaluated per iter.
eq(kind(function(){ var a=[], i=0; for(a[(function(){ if(i++) throw new URIError('k'); return 0; })()] in {x:1,y:1}){} }),'URIError','throwing key expr');

// All of the above must not have prevented a later call from compiling right.
(function(){ var o={}; for(o.p in {a:1}){} eq(o.p,'a','post-reject sanity'); })();


print('forin_forof_member_head: '+pass+' passed, '+fail+' failed');
if(fail>0){ print('SOME TESTS FAILED'); throw new Error('FAIL'); }
