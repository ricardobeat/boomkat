#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void check(bk_ctx ctx, const char *source) {
    bk_value value = bk_eval_ex(ctx, source, strlen(source), "jit.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(value)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(value) && bk_to_bool(ctx, value));
    bk_free_value(ctx, value);
}

/* Past the tiers' entry threshold (src/jit/opt.c3 OPT_ENTRY_THRESHOLD), so the
 * baseline tier compiles the function and the optimizing tier takes it from
 * there; every repeat must produce the same value. */
static const char *HOT_LOOP =
    "function grain(x){return (x*7+3)^(x>>>3);}"
    "function sum(n){var s=0;for(var i=0;i<n;i++)s+=grain(i);return s|0;}"
    "var expect=-1;for(var k=0;k<4000;k++){var v=sum(600);if(expect<0)expect=v;else if(v!==expect)throw 'sum changed';}"
    "true";

static const char *INLINE_CALLEE =
    "function addg(a,b){return a+b;}"
    "function fan(n){var s=0;for(var i=0;i<n;i++){s=addg(s,addg(i,1)&3);}return s;}"
    "var want=-1;for(var k=0;k<4000;k++){var v=fan(120);if(want<0)want=v;else if(v!==want)throw 'fan changed';}"
    "true";

static const char *INLINED_APPLY =
    "function mix(a,b){return a*3+b;}"
    "function drive(n){var s=0;for(var i=0;i<n;i++)s=mix(s,i)+mix(i,s)|0;return s;}"
    "var want=-1;"
    "for(var k=0;k<4000;k++){var v=drive(90);if(want<0)want=v;else if(v!==want)throw 'mix changed';}"
    "true";

/* Twelve receiver shapes on one load site: the optimized code compares the
 * shapes its cache recorded and exits on the rest, and the tier leaves the site
 * to the baseline cache once the exits repeat, so the reads must stay right. */
static const char *DEOPT_SHAPES =
    "function getx(o){return o.x;}"
    "var objs=[];"
    "for(var i=0;i<12;i++){var o={};o['p'+i]=i;o.x=i*3;objs.push(o);}"
    "var n=0;"
    "for(var k=0;k<4000;k++){var o=objs[k%objs.length];if(getx(o)!==o.x)throw 'shape read';n++;}"
    "n===4000";

/* Calls the optimized body keeps as call nodes: the callee varies with the
 * receiver's shape and Function.prototype.apply forwards the argument list. */
static const char *CALL_NODES =
    "function plus(a,b){return a+b;}"
    "function minus(a,b){return a-b;}"
    "function pick(n){return (n&1)===0?plus:minus;}"
    "function run(n){var s=0;for(var i=0;i<n;i++){s+=pick(i)(s,1);}return s;}"
    "function fwd(f,args){return f.apply(null,args);}"
    "var want=-1;"
    "for(var k=0;k<4000;k++){var v=run(80)+fwd(plus,[1,2]);if(want<0)want=v;else if(v!==want)throw 'call changed';}"
    "fwd(plus,[2,3])===5";

/* Functions the host calls (Array.prototype.map and friends), whose frames
 * are the outermost of a run: compiled, they return to the host from their
 * own code (vm::jit_ret_outermost) a number, a counted string, an object while
 * the garbage keeps the collector marking, or undefined, or decline to the
 * interpreter's return from a try/finally or with mapped arguments, or throw. */
static const char *CALLBACK_RETURNS =
    "function num(x){return x+1;}"
    "function str(x,i){return 's'+i+'-'+x+'-'.repeat(40);}"
    "function obj(x,i){return {i:i,big:new Array(8).fill(i)};}"
    "function none(x){}"
    "function fin(x){try{return x*2;}finally{x=0;}}"
    "function mapped(x){arguments[0]=5;return x;}"
    "function thrower(x){if(x===7)throw new RangeError('seven');return x;}"
    "function desc(x,y){return y-x;}"
    "function add(acc,x){return acc+x;}"
    "var a=[];for(var i=0;i<64;i++)a.push(i);"
    "var ok=true;"
    "for(var k=0;k<300;k++){"
    "var m=a.map(num);if(m[63]!==64)ok=false;"
    "var s=a.map(str);if(s[10]!=='s10-10'+'-'.repeat(40)||s.length!==64)ok=false;"
    "var o=a.map(obj);if(o[5].big[7]!==5||o[63].i!==63)ok=false;"
    "var u=a.map(none);if(u[3]!==undefined)ok=false;"
    "var f=a.map(fin);if(f[9]!==18)ok=false;"
    "var p=a.map(mapped);if(p[9]!==5)ok=false;"
    "try{a.forEach(thrower);ok=false;}catch(e){if(!(e instanceof RangeError)||e.message!=='seven')ok=false;}"
    "if(a.slice().sort(desc)[0]!==63)ok=false;"
    "if(a.reduce(add,0)!==2016)ok=false;"
    "}"
    "ok";

int main(void) {
    bk_runtime runtime = bk_new_runtime(NULL);
    assert(runtime);
    assert(bk_set_jit(NULL, 1) == BK_ERR_INVALID);
    /* The optimizing tier compiles on top of the baseline and leaves for its
     * code, so it cannot be enabled without it. */
    assert(bk_set_jit_opt(runtime, 1) == BK_ERR_INVALID);
    assert(bk_set_jit(runtime, 1) == BK_OK);
    bk_ctx ctx = bk_new_context(runtime, NULL);
    assert(ctx);
    check(ctx, "function render(items){let out='';for(let i=0;i<items.length;i++){const item=items[i];out+=`<li>${item.id}:${item.name}</li>`;}return out;}"
               "var rows=[{id:1,name:'one'},{id:2,name:'two'}];"
               "for(var i=0;i<64;i++){if(render(rows)!=='<li>1:one</li><li>2:two</li>')throw 'bad render';}true");
    check(ctx, "function sum(a){var x=0;for(var i=0;i<a.length;i++)x+=a[i];return x;}"
               "var bytes=new Uint8Array(4096);bytes.fill(3);sum(bytes)===12288");
    assert(bk_set_jit(runtime, 0) == BK_OK);
    check(ctx, "rows[0].id=3;render(rows)==='<li>3:one</li><li>2:two</li>'");
    check(ctx, "bytes[5]=99;sum(bytes)===12384");
    assert(bk_set_jit(runtime, 1) == BK_OK);
    check(ctx, "sum(bytes)===12384");
    check(ctx, "render(rows)==='<li>3:one</li><li>2:two</li>'");

    /* The same workloads in the baseline tier alone, then with the optimizing
     * tier on top of it: field and element reads, inlined callees, an inlined
     * body that keeps a call, call nodes, a forwarding apply and the shape
     * exits that run baseline code again. */
    assert(bk_set_jit_opt(runtime, 0) == BK_OK);
    check(ctx, HOT_LOOP);
    check(ctx, INLINE_CALLEE);
    assert(bk_set_jit_opt(runtime, 1) == BK_OK);
    check(ctx, HOT_LOOP);
    check(ctx, INLINE_CALLEE);
    check(ctx, INLINED_APPLY);
    check(ctx, DEOPT_SHAPES);
    check(ctx, CALL_NODES);
    check(ctx, CALLBACK_RETURNS);
    assert(bk_set_jit_opt(runtime, 0) == BK_OK);
    check(ctx, CALLBACK_RETURNS);
    check(ctx, HOT_LOOP);
    check(ctx, DEOPT_SHAPES);

    /* Stress warms every function on its first entry, with the optimizing tier
     * still selecting bodies, which is the combination the differential suites
     * run under. */
    assert(bk_set_jit_opt(runtime, 1) == BK_OK);
    assert(bk_set_jit_stress(runtime, 1) == BK_OK);
    check(ctx, HOT_LOOP);
    check(ctx, INLINE_CALLEE);
    check(ctx, INLINED_APPLY);
    check(ctx, CALL_NODES);
    check(ctx, CALLBACK_RETURNS);
    assert(bk_set_jit_stress(runtime, 0) == BK_OK);

    /* Turning the runtime's JIT off releases the compiled bodies of both tiers
     * while values keep working. */
    assert(bk_set_jit_opt(runtime, 0) == BK_OK);
    assert(bk_set_jit(runtime, 0) == BK_OK);
    check(ctx, HOT_LOOP);
    bk_free_context(ctx);
    bk_free_runtime(runtime);
    puts("C API JIT: PASS");
}
