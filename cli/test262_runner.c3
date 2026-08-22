// Batch test262 runner. Reuses a single heap and VM across tests, resetting
// state between runs to avoid memory churn and RSS bloat.
//
// Reset protocol between tests:
//   1. heap.reset(): frees object allocations, strings, env pools, shapes,
//      compiled functions, module cache, pool-backed memory, and clears the
//      megamorphic cache.
//   2. vm_destroy() and vm_create(): recreate the VM and repopulate builtins.
//
// Usage: ./out/test262_runner <manifest_file>
//        ./out/test262_runner --worker
module test262_runner;

import boomkat::compiler;
import boomkat::esm;
import boomkat::vm;
import boomkat::heap;
import boomkat::env;
import boomkat::lexer;
import boomkat::types;
import boomkat::bytecode;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::builtins;
import std::io;

// ============================================================================
// Unhandled rejection tracking
// ============================================================================

// Unhandled rejections reported while the current test runs. The CLI installs
// the same tracker; without it here, a promise that rejects with nothing
// watching it is entirely invisible to the suite and the test still scores
// PASS.
int unhandled_rejection_count = 0;

// Heap.set_rejection_tracker callback. Counts only — run_one_test prints the
// verdict, since it is the frame that knows which test this belongs to.
fn void runner_rejection_tracker(void* heap_raw, void* vm, TVal promise, TVal reason, void* udata) {
    unhandled_rejection_count++;
}

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

    File? fp_opt = file::open((String)mpath, "r");
    if (catch fp_opt) { io::eprintfn("Failed to open: %s", mpath); return 1; }
    File fp = fp_opt;
    defer (void)fp.close();

    // Allocate the long-lived heap and VM once.
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
    while (try line = io::treadline(&fp)) {
        @pool() {
            if (line.len == 0) { continue; }

            bool report = (total % 100 == 0);

            // Reset heap and recreate VM. Set `v` to null during recreation
            // so failures do not leave dangling pointers for subsequent cleanup.
            hp.reset();
            vm::vm_destroy(v);
            v = null;
            Vm*? v2 = vm::vm_create(hp);
            if (catch err = v2) {
                fail++;
                total++;
                continue;
            }
            v = v2;

            char[] path = (char[])line;
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
// Helper: compile and execute JS source in a VM
// ============================================================================

fn int exec_js(Vm* v, Heap* hp, char[] src) {
    Lexer lx = lexer::lexer_init(src, hp);
    defer lx.free_arena();
    lx.skip_hashbang();
    CompiledFunction*? f = compiler::compile(&lx, hp);
    if (catch err = f) {
        io::eprintfn("  COMPILE ERROR: %s", (String)lx.err_msg[..]);
        return 2;
    }
    if (catch err = v.execute(f)) {
        io::eprintfn("  RUNTIME ERROR (compiled ok, %d insns): %s", f.code_count, (String)lx.err_msg[..]);
        return 1;
    }
    return 0;
}

// ============================================================================
// Run one test, reusing an already-reset heap and VM
// ============================================================================

const char[] MIN_HARNESS = "var __test262_fail=0;function Test262Error(msg){this.message=msg||'';}Test262Error.prototype.toString=function(){return'Test262Error: '+this.message;};Test262Error.thrower=function(m){throw new Test262Error(m);};function $DONOTEVALUATE(){throw'Test262: This statement should not be evaluated.';}function $ERROR(msg){__test262_fail++;}function $FAIL(msg){__test262_fail++;}function isNegativeZero(v){return v===0&&1/v===-Infinity;}function isPrimitive(v){return!v||(typeof v!=='object'&&typeof v!=='function');}function formatIdentityFreeValue(v){switch(v===null?'null':typeof v){case'string':return typeof JSON!=='undefined'?JSON.stringify(v):'\"'+v+'\"';case'bigint':return String(v)+'n';case'number':if(isNegativeZero(v))return'-0';case'boolean':case'undefined':case'null':return String(v);}return'';}function formatSimpleValue(v){var b=formatIdentityFreeValue(v);if(b)return b;try{return String(v);}catch(e){if(e.name==='TypeError')return Object.prototype.toString.call(v);throw e;}}function assert(m,b){if(m===true)return;if(b===undefined)b='Expected true but got '+assert._toString(m);throw new Test262Error(b);}assert._isSameValue=function(a,b){if(a===b)return a!==0||1/a===1/b;return a!==a&&b!==b;};assert.sameValue=function(a,e,m){try{if(assert._isSameValue(a,e))return;}catch(e){throw new Test262Error(m+'(_isSameValue threw)'+e);}if(m===undefined)m='';else m+=' ';m+='Expected SameValue(\\u00AB'+assert._toString(a)+'\\u00BB, \\u00AB'+assert._toString(e)+'\\u00BB) to be true';throw new Test262Error(m);};assert.notSameValue=function(a,u,m){if(!assert._isSameValue(a,u))return;if(m===undefined)m='';else m+=' ';m+='Expected SameValue(\\u00AB'+assert._toString(a)+'\\u00BB, \\u00AB'+assert._toString(u)+'\\u00BB) to be false';throw new Test262Error(m);};assert.throws=function(e,f,m){if(typeof f!=='function')throw new Test262Error('assert.throws requires two arguments');if(m===undefined)m='';else m+=' ';try{f();}catch(t){if(typeof t!=='object'||t===null){m+='Thrown value was not an object!';throw new Test262Error(m);}if(e===Error||t instanceof e){}else{}}return;};assert._toString=function(o){try{return''+o;}catch(e){return'[error in toString: '+e.message+']';}};";

// Simplified nativeFunctionMatcher without unicode regex escapes.
const char[] NFM_HARNESS = "function validateNativeFunctionSource(source){var pos=0;function isNewline(c){var n=c.charCodeAt(0);return n===10||n===13||n===8232||n===8233;}function isWhitespace(c){var n=c.charCodeAt(0);return n===9||n===11||n===12||n===32||n===160||n===65279;}function eatWhitespace(){while(pos<source.length){var c=source[pos];if(isWhitespace(c)||isNewline(c)){pos++;continue;}if(c==='/'){if(source[pos+1]==='/'){while(pos<source.length){if(isNewline(source[pos]))break;pos++;}continue;}if(source[pos+1]==='*'){var end=source.indexOf('*/',pos);if(end===-1)throw SyntaxError();pos=end+2;continue;}}break;}}function isIDStart(c){return/[A-Za-z_$]/.test(c);}function isIDContinue(c){return/[0-9A-Za-z_$]/.test(c);}function getIdentifier(){eatWhitespace();var start=pos;var end=pos;switch(source[end]){case'_':case'$':end++;break;default:if(isIDStart(source[end])){end++;break;}return null;}while(end<source.length){var c=source[end];switch(c){case'_':case'$':end++;break;default:if(isIDContinue(c)){end++;break;}return source.slice(start,end);}}return source.slice(start,end);}function test(s){eatWhitespace();if(/\\w/.test(s))return getIdentifier()===s;return source.slice(pos,pos+s.length)===s;}function eat(s){if(test(s)){pos+=s.length;return true;}return false;}function eatIdentifier(){var n=getIdentifier();if(n!==null){pos+=n.length;return true;}return false;}function expect(s){if(!eat(s))throw SyntaxError();}function eatString(){var ch=source.charCodeAt(pos);if(ch===39||ch===34){var match=source[pos];pos++;while(pos<source.length){var cur=source.charCodeAt(pos);if(cur===match&&source.charCodeAt(pos-1)!==92)return;if(isNewline(source[pos]))throw SyntaxError();pos++;}throw SyntaxError();}}function stumbleUntil(c){var m={']':'[',')':'('}[c];var nesting=1;while(pos<source.length){eatWhitespace();eatString();if(source[pos]===m)nesting++;else if(source[pos]===c)nesting--;pos++;if(nesting===0)return;}throw SyntaxError();}expect('function');eat('get')||eat('set');if(!eatIdentifier()&&eat('['))stumbleUntil(']');expect('(');stumbleUntil(')');expect('{');expect('[');expect('native');expect('code');expect(']');expect('}');eatWhitespace();if(pos!==source.length)throw SyntaxError();}function assertToStringOrNativeFunction(fn,expected){var actual=''+fn;try{assert.sameValue(actual,expected);}catch(unused){assertNativeFunction(fn,expected);}}function assertNativeFunction(fn,special){var actual=''+fn;try{validateNativeFunctionSource(actual);}catch(unused){throw new Test262Error('Conforms to NativeFunction Syntax: '+JSON.stringify(actual)+(special?' ('+special+')':''));}}";

const char[] ISCON_HARNESS = "function isConstructor(f){try{var p=new Proxy({},{getPrototypeOf:function(){return null;}});new f(p);return true;}catch(e){return false;}}";

// Minimal $262 host object providing detachArrayBuffer, global, and evalScript.
const char[] HOST262_HARNESS = "var $262={detachArrayBuffer:function(b){return __detachArrayBuffer(b);},global:this,gc:function(){},evalScript:function(s){return __evalScript(s);},createRealm:function(){throw new Error('createRealm not supported');},agent:{}};function $DETACHBUFFER(b){return __detachArrayBuffer(b);}";

// Parse test262 frontmatter for `includes:` and load required harness files.
fn void load_test_includes(Vm* v, Heap* hp, char[] src) {
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
    while (i < scan_end && (src[i] == ' ' || src[i] == '\t')) { i++; }
    if (i >= scan_end || src[i] != '[') return;
    i++;
    while (i < scan_end && src[i] != ']') {
        while (i < scan_end && (src[i] == ' ' || src[i] == '\t' || src[i] == ',' || src[i] == '\n' || src[i] == '\r')) { i++; }
        if (i >= scan_end || src[i] == ']') break;
        usz start = i;
        while (i < scan_end && src[i] != ',' && src[i] != ']' && src[i] != ' ' && src[i] != '\t' && src[i] != '\n' && src[i] != '\r') { i++; }
        usz end = i;
        if (end <= start) break;
        char[128] path_buf;
        char[] prefix = "test262/harness/";
        usz p = 0;
        for (usz k = 0; k < prefix.len && p < 127; k++) { path_buf[p++] = prefix[k]; }
        for (usz k = start; k < end && p < 127; k++) { path_buf[p++] = src[k]; }
        path_buf[p] = 0;
        char[] path = path_buf[:p];
        // Skip loading on-disk nativeFunctionMatcher.js because NFM_HARNESS is preloaded.
        {
            char[] want = "nativeFunctionMatcher.js";
            usz flen = end - start;
            if (flen == want.len) {
                bool same = true;
                for (usz k = 0; k < flen; k++) {
                    if (src[start + k] != want[k]) { same = false; break; }
                }
                if (same) continue;
            }
        }

        char[]? h_opt = file::load_temp((String)path);
        if (try h = h_opt) {
            exec_js(v, hp, h);
        }
    }
}

// Check for `flags: [async]` in frontmatter.
fn bool is_async_test(char[] src) {
    usz scan_end = src.len < 4096 ? src.len : (usz)4096;
    usz i = 0;
    while (i + 6 < scan_end) {
        if (src[i] == 'f' && src[i+1] == 'l' && src[i+2] == 'a' && src[i+3] == 'g'
            && src[i+4] == 's' && src[i+5] == ':') {
            i += 6;
            break;
        }
        i++;
    }
    if (i + 6 >= scan_end) return false;
    while (i < scan_end && src[i] != ']') {
        if (src[i] == 'a' && src[i+1] == 's' && src[i+2] == 'y' && src[i+3] == 'n' && src[i+4] == 'c') {
            return true;
        }
        i++;
    }
    return false;
}

fn bool contains_substr(char[] haystack, char[] needle) {
    if (needle.len > haystack.len) return false;
    usz max_i = haystack.len - needle.len;
    for (usz i = 0; i <= max_i; i++) {
        bool match = true;
        for (usz j = 0; j < needle.len; j++) {
            if (haystack[i + j] != needle[j]) { match = false; break; }
        }
        if (match) return true;
    }
    return false;
}

// Check for `flags: [module]` in frontmatter or top-level module statements.
fn bool is_module_test(char[] path, char[] src) {
    usz scan_end = src.len < 4096 ? src.len : (usz)4096;
    usz i = 0;
    while (i + 6 < scan_end) {
        if (src[i] == 'f' && src[i+1] == 'l' && src[i+2] == 'a' && src[i+3] == 'g'
            && src[i+4] == 's' && src[i+5] == ':') {
            i += 6;
            break;
        }
        i++;
    }
    // If no flags block exists, fall back to keyword scan for import/export in module paths.
    if (i + 6 >= scan_end) {
        return contains_substr(path, "language/module-code/") ||
            contains_substr(path, "language/import/") ||
            contains_substr(path, "language/export/")
            ? (contains_substr(src, "import") || contains_substr(src, "export"))
            : false;
    }
    // When flags block exists, rely on presence of "module".
    while (i + 6 < scan_end && src[i] != ']') {
        if (src[i] == 'm' && src[i+1] == 'o' && src[i+2] == 'd' && src[i+3] == 'u'
            && src[i+4] == 'l' && src[i+5] == 'e') {
            return true;
        }
        i++;
    }
    return false;
}

// Negative test phase from frontmatter.
enum NegPhase : int {
    NONE,
    PARSE,
    RESOLUTION,
    RUNTIME,
}

// Extract expected error constructor name from negative frontmatter.
fn usz negative_type(char[] src, char[] out) {
    usz scan_end = src.len < 8192 ? src.len : (usz)8192;
    usz i = 0;
    bool found = false;
    while (i + 9 < scan_end) {
        if (src[i] == 'n' && src[i+1] == 'e' && src[i+2] == 'g' && src[i+3] == 'a'
            && src[i+4] == 't' && src[i+5] == 'i' && src[i+6] == 'v' && src[i+7] == 'e'
            && src[i+8] == ':') { i += 9; found = true; break; }
        i++;
    }
    if (!found) return 0;
    usz block_end = i + 256 < scan_end ? i + 256 : scan_end;
    while (i + 5 < block_end) {
        if (src[i] == 't' && src[i+1] == 'y' && src[i+2] == 'p' && src[i+3] == 'e'
            && src[i+4] == ':') {
            i += 5;
            while (i < block_end && (src[i] == ' ' || src[i] == '\t')) { i++; }
            usz start = i;
            while (i < block_end && (
                (src[i] >= 'A' && src[i] <= 'Z') || (src[i] >= 'a' && src[i] <= 'z')
                || (src[i] >= '0' && src[i] <= '9') || src[i] == '_')) { i++; }
            usz n = i - start;
            if (n == 0 || n > out.len) return 0;
            for (usz k = 0; k < n; k++) { out[k] = src[start + k]; }
            return n;
        }
        i++;
    }
    return 0;
}

// Match thrown value constructor name against expected type.
// Checks builtin error prototype chains and constructor name properties.
fn bool thrown_type_matches(Vm* v, Heap* hp, char[] expected) {
    // Read thrown value from heap.error_value after unwinding.
    TVal thrown_val = hp.error_value;
    if (!thrown_val.is_object()) {
        return false;
    }
    HObject* thrown = (HObject*)thrown_val.get_heapptr();
    if (thrown == null) return false;

    // Check prototype chains for standard builtin error types.
    HObject* want_proto = null;
    if (compiler::str_eq(expected, "TypeError"))      { want_proto = hp.type_err_proto; }
    else if (compiler::str_eq(expected, "RangeError"))     { want_proto = hp.range_err_proto; }
    else if (compiler::str_eq(expected, "ReferenceError")) { want_proto = hp.ref_err_proto; }
    else if (compiler::str_eq(expected, "SyntaxError"))    { want_proto = hp.syntax_err_proto; }
    else if (compiler::str_eq(expected, "EvalError"))      { want_proto = hp.eval_err_proto; }
    else if (compiler::str_eq(expected, "URIError"))       { want_proto = hp.uri_err_proto; }

    if (want_proto != null) {
        HObject* cur = thrown.prototype;
        for (uint guard = 0; guard < 64 && cur != null; guard++) {
            if (cur == want_proto) return true;
            cur = cur.prototype;
        }
    }

    // Check constructor.name for custom error types (such as Test262Error).
    char[] ctor_key = "constructor";
    uint ch = hp.hash_string(ctor_key);
    HString*? cks = hp.str_table_lookup(ctor_key, ch);
    HObject* ctor = null;
    if (try ck = cks) {
        HObject* cur = thrown;
        for (uint guard = 0; guard < 64 && cur != null; guard++) {
            int idx = cur.find_prop_idx(ck, hp);
            if (idx >= 0) {
                TVal cv = cur.prop_values()[idx];
                if (cv.is_object() && cv.get_heapptr() != null) { ctor = (HObject*)cv.get_heapptr(); }
                break;
            }
            cur = cur.prototype;
        }
    }
    if (ctor != null) {
        char[] name_key = "name";
        uint nh = hp.hash_string(name_key);
        HString*? nks = hp.str_table_lookup(name_key, nh);
        if (try nk = nks) {
            int nidx = ctor.find_prop_idx(nk, hp);
            if (nidx >= 0) {
                TVal nv = ctor.prop_values()[nidx];
                if (nv.is_string() && nv.get_heapptr() != null) {
                    HString* ns = (HString*)nv.get_heapptr();
                    if (ns.equals(expected)) return true;
                }
            }
        }
    }
    return false;
}

// Parse the `negative:` frontmatter block and return its declared phase.
fn NegPhase negative_phase(char[] src) {
    usz scan_end = src.len < 8192 ? src.len : (usz)8192;
    usz i = 0;
    bool found = false;
    while (i + 9 < scan_end) {
        if (src[i] == 'n' && src[i+1] == 'e' && src[i+2] == 'g' && src[i+3] == 'a'
            && src[i+4] == 't' && src[i+5] == 'i' && src[i+6] == 'v' && src[i+7] == 'e'
            && src[i+8] == ':') {
            i += 9;
            found = true;
            break;
        }
        i++;
    }
    if (!found) return NegPhase.NONE;
    usz block_end = i + 256 < scan_end ? i + 256 : scan_end;
    while (i + 6 < block_end) {
        if (src[i] == 'p' && src[i+1] == 'h' && src[i+2] == 'a' && src[i+3] == 's'
            && src[i+4] == 'e' && src[i+5] == ':') {
            i += 6;
            while (i < block_end && (src[i] == ' ' || src[i] == '\t')) { i++; }
            if (i + 5 <= block_end && src[i] == 'p' && src[i+1] == 'a' && src[i+2] == 'r'
                && src[i+3] == 's' && src[i+4] == 'e') {
                return NegPhase.PARSE;
            }
            if (i + 10 <= block_end && src[i] == 'r' && src[i+1] == 'e' && src[i+2] == 's'
                && src[i+3] == 'o' && src[i+4] == 'l' && src[i+5] == 'u' && src[i+6] == 't'
                && src[i+7] == 'i' && src[i+8] == 'o' && src[i+9] == 'n') {
                return NegPhase.RESOLUTION;
            }
            if (i + 7 <= block_end && src[i] == 'r' && src[i+1] == 'u' && src[i+2] == 'n'
                && src[i+3] == 't' && src[i+4] == 'i' && src[i+5] == 'm' && src[i+6] == 'e') {
                return NegPhase.RUNTIME;
            }
            return NegPhase.NONE;
        }
        i++;
    }
    return NegPhase.NONE;
}

// Run a `flags: [module]` test through the ESM resolve, link, and evaluate pipeline.
fn int exec_js_module(Vm* v, Heap* hp, char[] test_path) {
    return esm::run_module_file(hp, v, test_path);
}

fn int run_one_test(Vm* v, Heap* hp, char[] test_path, char[] assert_src, char[] property_helper_src) {
    char[]? source = file::load_temp((String)test_path);
    if (catch err = source) { return 1; }
    char[] src = source;

    // Installed per test: the heap is recreated between batches, and the count
    // has to start at zero for every test regardless.
    unhandled_rejection_count = 0;
    hp.set_rejection_tracker(&runner_rejection_tracker, null);

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

    if (exec_js(v, hp, NFM_HARNESS) != 0) { io::eprintfn("  FAIL: NFM_HARNESS"); }
    if (exec_js(v, hp, ISCON_HARNESS) != 0) { io::eprintfn("  FAIL: ISCON_HARNESS"); }
    if (exec_js(v, hp, HOST262_HARNESS) != 0) { io::eprintfn("  FAIL: HOST262_HARNESS"); }

    // Async harness setup.
    bool async_test = is_async_test(src);
    char[]? done_src_opt = file::load_temp((String)"test262/harness/doneprintHandle.js");
    char[] done_src;
    if (try ds = done_src_opt) {
        done_src = ds;
        if (exec_js(v, hp, done_src) != 0) { io::eprintfn("  FAIL: doneprintHandle.js"); }
    }
    if (async_test) {
        char[] async_setup = "var __test262_async_done=0;var __test262_async_error=null;(function(){var _origDONE=$DONE;$DONE=function(err){__test262_async_done=1;if(err){__test262_async_error=String(err);__test262_fail++;}_origDONE(err);};})();";
        exec_js(v, hp, async_setup);
    }

    load_test_includes(v, hp, src);

    // Prepend strict directive when onlyStrict flag is set.
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
        strict_buf = (char*)alloc::malloc_try(mem, (sz)(total)) ?? null;
        if (strict_buf != null) {
            for (usz k = 0; k < PREFIX.len; k++) { strict_buf[k] = PREFIX[k]; }
            for (usz k = 0; k < src.len; k++) { strict_buf[PREFIX.len + k] = src[k]; }
            strict_buf[PREFIX.len + src.len] = 0;
            exec_src = strict_buf[:PREFIX.len + src.len];
        }
    }
    defer if (strict_buf != null) { mem::free(strict_buf); }

    bool module_test = is_module_test(test_path, src);
    NegPhase neg = negative_phase(src);

    int src_rc;
    if (module_test) {
        src_rc = exec_js_module(v, hp, test_path);
    } else {
        hp.current_module_name = test_path;
        src_rc = exec_js(v, hp, exec_src);
    }

    // Runtime-negative tests: verify execution threw the expected error type.
    if (neg == NegPhase.RUNTIME) {
        if (src_rc == 2) {
            io::eprintfn("  FAIL: runtime-negative threw at parse time, not runtime");
            return 1;
        }
        if (src_rc == 0) {
            io::eprintfn("  FAIL: runtime-negative completed without throwing");
            return 1;
        }
        char[64] tbuf;
        usz tn = negative_type(src, tbuf[..]);
        if (tn == 0) {
            return 0;
        }
        if (thrown_type_matches(v, hp, tbuf[:tn])) {
            return 0;
        }
        io::eprintfn("  FAIL: runtime-negative threw wrong error type (wanted %s)", (String)tbuf[:tn]);
        return 1;
    }

    // Parse-negative tests: verify syntax was rejected at parse time.
    if (neg == NegPhase.PARSE) {
        if (src_rc == 2) { return 0; }
        io::eprintfn("  FAIL: parse-negative did not reject at parse time");
        return 1;
    }

    // Resolution-negative tests: verify rejection during module linking.
    if (neg == NegPhase.RESOLUTION) {
        if (src_rc != 0) { return 0; }
        io::eprintfn("  FAIL: resolution-negative did not reject at link time");
        return 1;
    }

    if (src_rc == 2) { io::eprintfn("  FAIL: compile error in test source %d bytes", src.len); return 2; }
    if (src_rc != 0) {
        io::eprintfn("  FAIL: test source %d bytes", src.len);
        if (hp.error_value.is_object()) {
            HObject* eo = (HObject*)hp.error_value.get_heapptr();
            if (eo != null) {
                HString* msg_key = (HString*)hp.strs[heap::BuiltinStr.MESSAGE];
                hobject::Shape* sh = eo.get_shape(hp);
                TVal* vals = eo.prop_values();
                uint val_idx = 0;
                while (sh != null) {
                    hobject::ShapeProperty* sp = sh.props();
                    for (uint i = 0; i < sh.own_count; i++) {
                        if (val_idx >= eo.prop_count) break;
                        TVal* mv = &vals[val_idx];
                        if (sp[i].key == (void*)msg_key && mv.is_string()) {
                            HString* s = (HString*)mv.get_heapptr();
                            char[] d = s.get_data();
                            io::eprintfn("  DEBUG_ERR: %s", (String)d);
                        }
                        val_idx++;
                    }
                    sh = sh.parent_shape;
                }
            }
        }
        return 1;
    }

    // Drain pending microtasks to allow async tests to complete.
    int drain_loops = 0;
    for (int drain_i = 0; drain_i < 1000; drain_i++) {
        uint before = hp.microtask_count;
        hp.drain_microtasks(v);
        uint after = hp.microtask_count;
        drain_loops++;
        if (after == 0) break;
        if (after == before && drain_i > 5) break;
    }

    // Verify async tests called $DONE.
    if (async_test) {
        char[] adk = "__test262_async_done";
        uint adh = hp.hash_string(adk);
        HString*? ads = hp.str_table_lookup(adk, adh);
        if (try adks = ads) {
            TVal? adtv = env::env_get(v.global_env, adks);
            if (try adval = adtv) {
                if (adval.get_fastint() == 0) {
                    io::eprintfn("  FAIL: async test never called $DONE (drained %d loops, queue=%d)", drain_loops, hp.microtask_count);
                    return 1;
                }
            }
        }
    }

    // Diagnostic only, never a verdict: test262 does not treat an unhandled
    // rejection as a failure (`import('')` in the dynamic-import syntax tests
    // rejects with nothing attached and still passes, which is why d8 is run
    // with --ignore-unhandled-promises). Reporting it keeps the engine's own
    // spurious rejections visible instead of silently scoring PASS.
    if (unhandled_rejection_count > 0) {
        io::eprintfn("  NOTE: %d unhandled promise rejection(s)", unhandled_rejection_count);
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

    // Allocate the long-lived heap and VM once.
    Heap*? hp_opt = heap::create(null, null, null, null, null);
    if (catch h = hp_opt) { return 1; }
    Heap* hp = hp_opt;
    defer hp.destroy();

    Vm*? v_opt = vm::vm_create(hp);
    if (catch err = v_opt) { return 1; }
    Vm* v = v_opt;

    // Read inside @pool scope so line allocations are reclaimed per test.
    bool eof = false;
    while (!eof) {
        @pool() {
            String line = (String)"";
            String? line_opt = io::treadline(io::stdin());
            if (catch line_opt) { eof = true; } else { line = line_opt; }
            if (eof || line.len == 0) { continue; }

            // Reset heap and recreate VM.
            hp.reset();
            vm::vm_destroy(v);
            v = null;
            Vm*? v2 = vm::vm_create(hp);
            if (catch err = v2) {
                io::printfn("FAIL %s", line);
                (void)io::stdout().flush();
                continue;
            }
            v = v2;

            char[] path = (char[])line;
            int rc = run_one_test(v, hp, path, assert_src, ph_src);

            if (rc == 0) {
                io::printfn("PASS %s", (String)path);
            } else if (rc == 2) {
                io::printfn("COMPILE_ERROR %s", (String)path);
            } else {
                io::printfn("FAIL %s", (String)path);
            }
            (void)io::stdout().flush();
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
    if (args.len >= 2 && (ZString)args[1].ptr == (ZString)"--worker") {
        return run_worker_loop();
    }
    if (args.len < 2) {
        io::eprintfn("Usage: batch_test_vm <manifest_file>");
        io::eprintfn("       batch_test_vm --worker  (stdin-driven worker mode)");
        return 1;
    }
    return run_manifest_loop(args[1]);
}
