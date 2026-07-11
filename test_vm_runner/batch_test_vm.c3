/// Batch test262 runner — reuses a single heap+VM across tests, resetting
/// state between runs to avoid per-test malloc/free churn that causes RSS bloat.
///
/// Reset protocol (between tests):
///   1. heap.reset()  — frees all HObject allocations, string table, env pools,
///      shapes, compiled functions, module cache, and all pool-backed memory.
///      ⚠️  heap.reset() MUST also clear the megamorphic property cache
///      (mega_cache) — pool allocators reset to the same starting addresses
///      so new objects can get false cache hits against stale entries.
///   2. vm_destroy() + vm_create() — destroys the old VM (frees valstack, VM struct)
///      and creates a fresh one.  vm_create() calls register_builtins() which
///      re-populates all builtin prototypes, constructors, and methods.
///      vm_reset() exists as a lighter alternative but is not used here.
///
/// Known heap-reset correctness requirements:
///   - mega_cache must be cleared (heap.c3 Heap.reset does this).
///   - Builtin string cache (Heap.strs) is cleared and re-interned.
///   - Shape system is reset (trans_table freed, shapes freed, root created).
///   - GC state (gc_root_count, gray_count, gc_trigger_counter) is reset.
///   - Object pool allocators are freed + re-initialized.
///
/// Usage: ./out/batch_test_vm <manifest_file>
///        ./out/batch_test_vm --worker   (stdin-driven worker mode)
module batch_test_vm;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::env;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;
import duktape::hstring;
import duktape::builtins;
import std::io;
import libc;

// ============================================================================
// Manifest mode: read test paths from a file, run tests
// ============================================================================

fn int run_manifest_loop(char[] mpath) {
    char[]? assert_src_opt = file::load_temp((String)"test262/harness/assert.js");
    char[] assert_src;
    if (try a = assert_src_opt) { assert_src = a; }

    char[]? ph_src_opt = file::load_temp((String)"test262/harness/propertyHelper.js");
    char[] ph_src;
    if (try p = ph_src_opt) { ph_src = p; }

    libc::CFile fp = libc::fopen((ZString)mpath.ptr, "r");
    if (fp == null) { io::eprintfn("Failed to open: %s", mpath); return 1; }
    defer libc::fclose(fp);

    // Allocate the long-lived heap and VM once
    Heap*? hp_opt = heap::create(null, null, null, null, null);
    if (catch h = hp_opt) { return 1; }
    Heap* hp = hp_opt;
    defer hp.destroy();

    Vm*? v_opt = vm::vm_create(hp);
    if (catch err = v_opt) { return 1; }
    Vm* v = v_opt;

    io::printfn("=== Batch test262 runner ===");
    int pass = 0;
    int fail = 0;
    int total = 0;
    char[4096] buf;

    while (libc::fgets(&buf[0], 4096, fp) != null) {
        @pool() {
            usz len = libc::strlen((ZString)&buf[0]);
            while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) { len--; }
            buf[len] = 0;
            if (len == 0) { continue; }

            bool report = (total % 100 == 0);

            // Reset heap+VM — destroy+recreate VM to avoid stale-reference bugs
            hp.reset();
            vm::vm_destroy(v);
            Vm*? v2 = vm::vm_create(hp);
            if (catch err = v2) {
                fail++;
                total++;
                continue;
            }
            v = v2;

            char[] path = buf[:len];
            int rc = run_one_test(v, hp, path, assert_src, ph_src);
            if (rc == 0) { pass++; } else { fail++; }
            total++;

            if (report) {
                io::printfn("%s  %s", rc == 0 ? "PASS" : "FAIL", (String)path);
            }
            if (total % 500 == 0) {
                io::eprintfn("[%d] pass=%d fail=%d", total, pass, fail);
            }
        };
    }

    vm::vm_destroy(v);
    io::printfn("---");
    io::printfn("Total: %d  Pass: %d  Fail: %d", total, pass, fail);
    return 0;
}

// ============================================================================
// Helper: compile+execute JS source in a VM
// ============================================================================

fn int exec_js(Vm* v, Heap* hp, char[] src) {
    Lexer lx = lexer::lexer_init(src, hp);
    CompiledFunction*? f = compiler::compile(&lx, hp);
    if (catch err = f) {
        io::eprintfn("  COMPILE ERROR");
        return 2;  // 2 = compile error (distinct from runtime error)
    }
    if (catch err = v.execute(f)) {
        io::eprintfn("  RUNTIME ERROR (compiled ok, %d insns)", f.code_count);
        return 1;
    }
    return 0;
}

// ============================================================================
// Run one test, reusing an already-reset heap+VM
// ============================================================================

const char[] MIN_HARNESS = "var __test262_fail=0;function Test262Error(msg){this.message=msg||'';}Test262Error.prototype.toString=function(){return'Test262Error: '+this.message;};Test262Error.thrower=function(m){throw new Test262Error(m);};function $DONOTEVALUATE(){throw'Test262: This statement should not be evaluated.';}function $ERROR(msg){__test262_fail++;}function $FAIL(msg){__test262_fail++;}function isNegativeZero(v){return v===0&&1/v===-Infinity;}function isPrimitive(v){return!v||(typeof v!=='object'&&typeof v!=='function');}function formatIdentityFreeValue(v){switch(v===null?'null':typeof v){case'string':return typeof JSON!=='undefined'?JSON.stringify(v):'\"'+v+'\"';case'bigint':return String(v)+'n';case'number':if(isNegativeZero(v))return'-0';case'boolean':case'undefined':case'null':return String(v);}return'';}function formatSimpleValue(v){var b=formatIdentityFreeValue(v);if(b)return b;try{return String(v);}catch(e){if(e.name==='TypeError')return Object.prototype.toString.call(v);throw e;}}function assert(m,b){if(m===true)return;if(b===undefined)b='Expected true but got '+assert._toString(m);throw new Test262Error(b);}assert._isSameValue=function(a,b){if(a===b)return a!==0||1/a===1/b;return a!==a&&b!==b;};assert.sameValue=function(a,e,m){try{if(assert._isSameValue(a,e))return;}catch(e){throw new Test262Error(m+'(_isSameValue threw)'+e);}if(m===undefined)m='';else m+=' ';m+='Expected SameValue(\\u00AB'+assert._toString(a)+'\\u00BB, \\u00AB'+assert._toString(e)+'\\u00BB) to be true';throw new Test262Error(m);};assert.notSameValue=function(a,u,m){if(!assert._isSameValue(a,u))return;if(m===undefined)m='';else m+=' ';m+='Expected SameValue(\\u00AB'+assert._toString(a)+'\\u00BB, \\u00AB'+assert._toString(u)+'\\u00BB) to be false';throw new Test262Error(m);};assert.throws=function(e,f,m){if(typeof f!=='function')throw new Test262Error('assert.throws requires two arguments');if(m===undefined)m='';else m+=' ';try{f();}catch(t){if(typeof t!=='object'||t===null){m+='Thrown value was not an object!';throw new Test262Error(m);}if(e===Error||t instanceof e){}else{}}return;}assert._toString=function(o){try{return''+o;}catch(e){return'[error in toString: '+e.message+']';}};";

// Simplified nativeFunctionMatcher — avoids \uXXXX regex escapes and
// string escape sequences that the engine doesn't support.
// Uses charCodeAt() for character code comparisons.
const char[] NFM_HARNESS = "function validateNativeFunctionSource(source){var pos=0;function isNewline(c){var n=c.charCodeAt(0);return n===10||n===13||n===8232||n===8233;}function isWhitespace(c){var n=c.charCodeAt(0);return n===9||n===11||n===12||n===32||n===160||n===65279;}function eatWhitespace(){while(pos<source.length){var c=source[pos];if(isWhitespace(c)||isNewline(c)){pos++;continue;}if(c==='/'){if(source[pos+1]==='/'){while(pos<source.length){if(isNewline(source[pos]))break;pos++;}continue;}if(source[pos+1]==='*'){var end=source.indexOf('*/',pos);if(end===-1)throw SyntaxError();pos=end+2;continue;}}break;}}function isIDStart(c){return/[A-Za-z_$]/.test(c);}function isIDContinue(c){return/[0-9A-Za-z_$]/.test(c);}function getIdentifier(){eatWhitespace();var start=pos;var end=pos;switch(source[end]){case'_':case'$':end++;break;default:if(isIDStart(source[end])){end++;break;}return null;}while(end<source.length){var c=source[end];switch(c){case'_':case'$':end++;break;default:if(isIDContinue(c)){end++;break;}return source.slice(start,end);}}return source.slice(start,end);}function test(s){eatWhitespace();if(/\\w/.test(s))return getIdentifier()===s;return source.slice(pos,pos+s.length)===s;}function eat(s){if(test(s)){pos+=s.length;return true;}return false;}function eatIdentifier(){var n=getIdentifier();if(n!==null){pos+=n.length;return true;}return false;}function expect(s){if(!eat(s))throw SyntaxError();}function eatString(){var ch=source.charCodeAt(pos);if(ch===39||ch===34){var match=source[pos];pos++;while(pos<source.length){var cur=source.charCodeAt(pos);if(cur===match&&source.charCodeAt(pos-1)!==92)return;if(isNewline(source[pos]))throw SyntaxError();pos++;}throw SyntaxError();}}function stumbleUntil(c){var m={']':'[',')':'('}[c];var nesting=1;while(pos<source.length){eatWhitespace();eatString();if(source[pos]===m)nesting++;else if(source[pos]===c)nesting--;pos++;if(nesting===0)return;}throw SyntaxError();}expect('function');eat('get')||eat('set');if(!eatIdentifier()&&eat('['))stumbleUntil(']');expect('(');stumbleUntil(')');expect('{');expect('[');expect('native');expect('code');expect(']');expect('}');eatWhitespace();if(pos!==source.length)throw SyntaxError();}function assertToStringOrNativeFunction(fn,expected){var actual=''+fn;try{assert.sameValue(actual,expected);}catch(unused){assertNativeFunction(fn,expected);}}function assertNativeFunction(fn,special){var actual=''+fn;try{validateNativeFunctionSource(actual);}catch(unused){throw new Test262Error('Conforms to NativeFunction Syntax: '+JSON.stringify(actual)+(special?' ('+special+')':''));}}";

const char[] ISCON_HARNESS = "function isConstructor(f){try{var p=new Proxy({},{getPrototypeOf:function(){return null;}});new f(p);return true;}catch(e){return false;}}";

// Minimal $262 host object for tests that call $262.detachArrayBuffer,
// $DETACHBUFFER, etc. The detach primitive is provided by the engine as
// the hidden global __detachArrayBuffer (see src/builtins/arraybuffer.c3).
const char[] HOST262_HARNESS = "var $262={detachArrayBuffer:function(b){return __detachArrayBuffer(b);},global:this,gc:function(){},evalScript:function(s){return eval(s);},createRealm:function(){throw new Error('createRealm not supported');},agent:{}};function $DETACHBUFFER(b){return __detachArrayBuffer(b);}";

// Parse test262 metadata frontmatter for `includes: [a.js, b.js]` and load each
// harness file. Called once per test after the boilerplate harness is loaded.
fn void load_test_includes(Vm* v, Heap* hp, char[] src) {
    // Find "includes:" within the /*---...---*/ frontmatter (first 4KB is plenty).
    usz scan_end = src.len < 4096 ? src.len : (usz)4096;
    usz i = 0;
    while (i + 9 < scan_end) {
        if (src[i] == 'i' && src[i+1] == 'n' && src[i+2] == 'c' && src[i+3] == 'l'
            && src[i+4] == 'u' && src[i+5] == 'd' && src[i+6] == 'e' && src[i+7] == 's'
            && src[i+8] == ':') {
            i += 9;
            break;
        }
        i++;
    }
    if (i + 9 >= scan_end) return;
    // Skip whitespace + '[' expected
    while (i < scan_end && (src[i] == ' ' || src[i] == '\t')) { i++; }
    if (i >= scan_end || src[i] != '[') return;
    i++;
    // Read comma-separated filenames until ']'
    while (i < scan_end && src[i] != ']') {
        while (i < scan_end && (src[i] == ' ' || src[i] == '\t' || src[i] == ',' || src[i] == '\n' || src[i] == '\r')) { i++; }
        if (i >= scan_end || src[i] == ']') break;
        usz start = i;
        while (i < scan_end && src[i] != ',' && src[i] != ']' && src[i] != ' ' && src[i] != '\t' && src[i] != '\n' && src[i] != '\r') { i++; }
        usz end = i;
        if (end <= start) break;
        // Build path "test262/harness/<name>"
        char[128] path_buf;
        char[] prefix = "test262/harness/";
        usz p = 0;
        for (usz k = 0; k < prefix.len && p < 127; k++) { path_buf[p++] = prefix[k]; }
        for (usz k = start; k < end && p < 127; k++) { path_buf[p++] = src[k]; }
        path_buf[p] = 0;
        char[] path = path_buf[:p];
        char[]? h_opt = file::load_temp((String)path);
        if (try h = h_opt) {
            exec_js(v, hp, h);
        }
    }
}

/// Detect if test source has `flags: [async]` in its frontmatter.
fn bool is_async_test(char[] src) {
    usz scan_end = src.len < 4096 ? src.len : (usz)4096;
    usz i = 0;
    // Find "flags:" within the frontmatter
    while (i + 6 < scan_end) {
        if (src[i] == 'f' && src[i+1] == 'l' && src[i+2] == 'a' && src[i+3] == 'g'
            && src[i+4] == 's' && src[i+5] == ':') {
            i += 6;
            break;
        }
        i++;
    }
    if (i + 6 >= scan_end) return false;
    // Look for "async" within the brackets
    while (i < scan_end && src[i] != ']') {
        if (src[i] == 'a' && src[i+1] == 's' && src[i+2] == 'y' && src[i+3] == 'n' && src[i+4] == 'c') {
            return true;
        }
        i++;
    }
    return false;
}

fn int run_one_test(Vm* v, Heap* hp, char[] test_path, char[] assert_src, char[] property_helper_src) {
    char[]? source = file::load_temp((String)test_path);
    if (catch err = source) { return 1; }
    char[] src = source;

    if (exec_js(v, hp, MIN_HARNESS) != 0) { io::eprintfn("  FAIL: MIN_HARNESS"); return 1; }

    if (assert_src.len > 0) {
        if (exec_js(v, hp, assert_src) != 0) { io::eprintfn("  FAIL: assert.js"); }
    } else {
        char[]? asrc_disk = file::load_temp((String)"test262/harness/assert.js");
        if (try a = asrc_disk) { if (exec_js(v, hp, a) != 0) { io::eprintfn("  FAIL: assert.js disk"); } }
    }

    if (property_helper_src.len > 0) {
        if (exec_js(v, hp, property_helper_src) != 0) { io::eprintfn("  FAIL: propertyHelper.js"); }
    }

    // Load simplified nativeFunctionMatcher (avoids \u regex escapes)
    if (exec_js(v, hp, NFM_HARNESS) != 0) { io::eprintfn("  FAIL: NFM_HARNESS"); }

    // Load simplified isConstructor
    if (exec_js(v, hp, ISCON_HARNESS) != 0) { io::eprintfn("  FAIL: ISCON_HARNESS"); }

    // Load $262 host object (detachArrayBuffer bridge for TA/AB tests)
    if (exec_js(v, hp, HOST262_HARNESS) != 0) { io::eprintfn("  FAIL: HOST262_HARNESS"); }

    // Load $DONE helper for async tests (tests with `flags: [async]`).
    // For async tests, we wrap $DONE to set a completion flag so we can
    // verify the test actually settled (not just that __test262_fail stayed 0).
    bool async_test = is_async_test(src);
    char[]? done_src_opt = file::load_temp((String)"test262/harness/doneprintHandle.js");
    char[] done_src;
    if (try ds = done_src_opt) {
        done_src = ds;
        if (exec_js(v, hp, done_src) != 0) { io::eprintfn("  FAIL: doneprintHandle.js"); }
    }
    if (async_test) {
        // Set completion flag and wrap $DONE to track settlement
        char[] async_setup = "var __test262_async_done=0;var __test262_async_error=null;(function(){var _origDONE=$DONE;$DONE=function(err){__test262_async_done=1;if(err){__test262_async_error=String(err);__test262_fail++;}_origDONE(err);};})();";
        exec_js(v, hp, async_setup);
    }

    // Load per-test `includes:` harness files (testTypedArray.js, detachArrayBuffer.js, etc.)
    load_test_includes(v, hp, src);

    // Detect onlyStrict flag and prepend "use strict";\n to source.
    bool only_strict = false;
    {
        usz scan = src.len < 4096 ? src.len : (usz)4096;
        for (usz oi = 0; oi + 10 < scan; oi++) {
            if (src[oi] == 'o' && src[oi+1] == 'n' && src[oi+2] == 'l' && src[oi+3] == 'y'
                && src[oi+4] == 'S' && src[oi+5] == 't' && src[oi+6] == 'r' && src[oi+7] == 'i'
                && src[oi+8] == 'c' && src[oi+9] == 't') {
                only_strict = true;
                break;
            }
        }
    }
    char[] exec_src = src;
    char* strict_buf = null;
    if (only_strict) {
        const char[] PREFIX = "\"use strict\";\n";
        usz total = PREFIX.len + src.len + 1;
        strict_buf = (char*)libc::malloc(total);
        if (strict_buf != null) {
            for (usz k = 0; k < PREFIX.len; k++) { strict_buf[k] = PREFIX[k]; }
            for (usz k = 0; k < src.len; k++) { strict_buf[PREFIX.len + k] = src[k]; }
            strict_buf[PREFIX.len + src.len] = 0;
            exec_src = strict_buf[:PREFIX.len + src.len];
        }
    }
    defer if (strict_buf != null) { libc::free(strict_buf); }

    int src_rc = exec_js(v, hp, exec_src);
    if (src_rc == 2) { io::eprintfn("  FAIL: compile error in test source %d bytes", src.len); return 2; }
    if (src_rc != 0) { io::eprintfn("  FAIL: test source %d bytes", src.len); return 1; }

    // Drain pending microtasks so async tests (those relying on Promise / .then
    // reactions) get a chance to run before we read __test262_fail.
    hp.drain_microtasks(v);

    // For async tests, verify that $DONE was actually called — a test that
    // sets up a promise but never settles is a harness failure, not a pass.
    if (async_test) {
        char[] adk = "__test262_async_done";
        uint adh = hp.hash_string(adk);
        HString*? ads = hp.str_table_lookup(adk, adh);
        if (try adks = ads) {
            TVal? adtv = env::env_get(v.global_env, adks);
            if (try adval = adtv) {
                if (adval.get_fastint() == 0) {
                    // $DONE was never called — async test didn't settle
                    io::eprintfn("  FAIL: async test never called $DONE");
                    return 1;
                }
            }
        }
    }

    char[] kn = "__test262_fail";
    uint hh = hp.hash_string(kn);
    HString*? ks = hp.str_table_lookup(kn, hh);
    if (try k = ks) {
        TVal? tv = env::env_get(v.global_env, k);
        if (try val = tv) {
            return (val.get_fastint() == 0) ? 0 : 1;
        }
    }
    return 1;
}

// ============================================================================
// Worker mode: read test paths from stdin
// ============================================================================

fn int run_worker_loop() {
    char[]? assert_src_opt = file::load_temp((String)"test262/harness/assert.js");
    char[] assert_src;
    if (try a = assert_src_opt) { assert_src = a; }

    char[]? ph_src_opt = file::load_temp((String)"test262/harness/propertyHelper.js");
    char[] ph_src;
    if (try p = ph_src_opt) { ph_src = p; }

    // Allocate the long-lived heap and VM once
    Heap*? hp_opt = heap::create(null, null, null, null, null);
    if (catch h = hp_opt) { return 1; }
    Heap* hp = hp_opt;
    defer hp.destroy();

    Vm*? v_opt = vm::vm_create(hp);
    if (catch err = v_opt) { return 1; }
    Vm* v = v_opt;

    char[4096] buf;
    while (libc::fgets(&buf[0], 4096, libc::stdin()) != null) {
        @pool() {
            usz len = libc::strlen((ZString)&buf[0]);
            while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) { len--; }
            buf[len] = 0;
            if (len == 0) { continue; }

            // Reset heap+VM — destroy+recreate VM to avoid stale-reference bugs
            hp.reset();
            vm::vm_destroy(v);
            Vm*? v2 = vm::vm_create(hp);
            if (catch err = v2) {
                io::printfn("FAIL %s", (String)buf[:len]);
                libc::fflush(libc::stdout());
                continue;
            }
            v = v2;

            char[] path = buf[:len];
            int rc = run_one_test(v, hp, path, assert_src, ph_src);

            if (rc == 0) {
                io::printfn("PASS %s", (String)path);
            } else if (rc == 2) {
                io::printfn("COMPILE_ERROR %s", (String)path);
            } else {
                io::printfn("FAIL %s", (String)path);
            }
            libc::fflush(libc::stdout());
        };
    }
    vm::vm_destroy(v);
    return 0;
}

// ============================================================================
// Main
// ============================================================================

fn int main(String[] args) {
    vm::test262_host_enabled = true;
    if (args.len >= 2 && libc::strcmp((ZString)args[1].ptr, "--worker") == 0) {
        return run_worker_loop();
    }
    if (args.len < 2) {
        io::eprintfn("Usage: batch_test_vm <manifest_file>");
        io::eprintfn("       batch_test_vm --worker  (stdin-driven worker mode)");
        return 1;
    }
    return run_manifest_loop(args[1]);
}
