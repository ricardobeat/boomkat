// The optimizing tier through the embedding API, under AddressSanitizer: the
// same workloads as test/capi/jit.c, so both tiers' compilers, the inline
// sites, the call nodes and the exits that run baseline code are exercised
// while the sanitizer watches the C side of them.
module jit_tiers;

import boomkat;
import std::io;

fn void check(JsContext* context, String source) {
    JsValue value = context.eval(source)!!;
    defer context.release(value);
    assert(context.as_bool(value)!!);
}

const String HOT_LOOP =
    "function grain(x){return (x*7+3)^(x>>>3);}"
    "function sum(n){var s=0;for(var i=0;i<n;i++)s+=grain(i);return s|0;}"
    "var expect=-1;for(var k=0;k<3000;k++){var v=sum(600);if(expect<0)expect=v;else if(v!==expect)throw 'sum changed';}"
    "true";

const String INLINE_CALLEE =
    "function addg(a,b){return a+b;}"
    "function fan(n){var s=0;for(var i=0;i<n;i++){s=addg(s,addg(i,1)&3);}return s;}"
    "var want=-1;for(var k=0;k<3000;k++){var v=fan(120);if(want<0)want=v;else if(v!==want)throw 'fan changed';}"
    "true";

const String DEOPT_SHAPES =
    "function getx(o){return o.x;}"
    "var objs=[];"
    "for(var i=0;i<12;i++){var o={};o['p'+i]=i;o.x=i*3;objs.push(o);}"
    "var n=0;"
    "for(var k=0;k<3000;k++){var o=objs[k%objs.length];if(getx(o)!==o.x)throw 'shape read';n++;}"
    "n===3000";

const String CALL_NODES =
    "function plus(a,b){return a+b;}"
    "function minus(a,b){return a-b;}"
    "function pick(n){return (n&1)===0?plus:minus;}"
    "function run(n){var s=0;for(var i=0;i<n;i++){s+=pick(i)(s,1);}return s;}"
    "function fwd(f,args){return f.apply(null,args);}"
    "var want=-1;"
    "for(var k=0;k<3000;k++){var v=run(80)+fwd(plus,[1,2]);if(want<0)want=v;else if(v!==want)throw 'call changed';}"
    "fwd(plus,[2,3])===5";

fn int main() {
    JsContext context;
    context.create()!!;
    defer context.destroy();
    JsRuntime* runtime = context.get_runtime();
    // The optimizing tier compiles on top of the baseline and leaves for its
    // code, so it needs the JIT on.
    assert(!runtime.set_jit_opt(true));
    assert(runtime.set_jit(true));
    check(&context, HOT_LOOP);
    check(&context, "function sum(a){var x=0;for(var i=0;i<a.length;i++)x+=a[i];return x;}"
                    "var bytes=new Uint8Array(4096);bytes.fill(3);sum(bytes)===12288");
    assert(runtime.set_jit_opt(true));
    check(&context, HOT_LOOP);
    check(&context, INLINE_CALLEE);
    check(&context, DEOPT_SHAPES);
    check(&context, CALL_NODES);
    assert(runtime.set_jit_stress(true));
    check(&context, HOT_LOOP);
    check(&context, INLINE_CALLEE);
    check(&context, CALL_NODES);
    assert(runtime.set_jit_stress(false));
    assert(runtime.set_jit_opt(false));
    check(&context, HOT_LOOP);
    io::printn("JIT tiers (ASan): PASS");
    return 0;
}
