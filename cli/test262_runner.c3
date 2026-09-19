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

// Unhandled rejections reported while the current test runs. Without this
// tracker, a promise that rejects with nothing watching it is invisible
// to the suite and the test still scores PASS.
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
// test262 frontmatter
// ============================================================================

// The YAML block between `/*---` and `---*/`. Every flag lookup below is
// confined to it. Scanning the whole file instead lets a test's own prose or
// code supply a flag it never declared, and the flags are what decide how the
// test is run at all: a stray `async` makes the runner wait for a $DONE that
// never comes, a stray `module` sends a script down the ESM pipeline.
// Returns an empty slice when there is no frontmatter.
fn char[] frontmatter(char[] src) {
    usz open_at = src.len;
    for (usz i = 0; i + 5 <= src.len; i++) {
        if (src[i] == '/' && src[i+1] == '*' && src[i+2] == '-' && src[i+3] == '-'
            && src[i+4] == '-') { open_at = i + 5; break; }
    }
    if (open_at >= src.len) return src[:0];
    for (usz i = open_at; i + 5 <= src.len; i++) {
        if (src[i] == '-' && src[i+1] == '-' && src[i+2] == '-' && src[i+3] == '*'
            && src[i+4] == '/') { return src[open_at:i - open_at]; }
    }
    return src[:0];
}

// Byte offset just past `key` in `hay`, or hay.len when absent. `key` carries
// its own trailing ':' so `flags:` cannot match `noFlags:`.
fn usz find_key(char[] hay, char[] key) {
    if (key.len > hay.len) return hay.len;
    usz max_i = hay.len - key.len;
    for (usz i = 0; i <= max_i; i++) {
        // A key starts a line, so only match at column 0. This keeps `type:`
        // inside a `negative:` block from matching a `type:` in a description.
        if (i != 0 && hay[i-1] != '\n') continue;
        bool match = true;
        for (usz j = 0; j < key.len; j++) {
            if (hay[i + j] != key[j]) { match = false; break; }
        }
        if (match) return i + key.len;
    }
    return hay.len;
}

// True when the frontmatter's `flags:` declares `word`. Both YAML spellings
// are accepted: the inline `flags: [async, module]` and the block form
//     flags:
//       - async
// The inline form ends at ']'; the block form ends at the next line that is
// neither blank nor indented, which is what bounds the scan for the block
// spelling — a forward search for ']' would run past the frontmatter entirely.
fn bool has_flag(char[] src, char[] word) {
    char[] fm = frontmatter(src);
    if (fm.len == 0) return false;
    usz i = find_key(fm, "flags:");
    if (i >= fm.len) return false;
    while (i < fm.len && (fm[i] == ' ' || fm[i] == '\t')) { i++; }

    usz end = fm.len;
    if (i < fm.len && fm[i] == '[') {
        for (usz k = i; k < fm.len; k++) {
            if (fm[k] == ']') { end = k; break; }
        }
    } else {
        // Block form: stop at the first line that starts a new key.
        usz k = i;
        while (k < fm.len) {
            if (fm[k] == '\n') {
                usz ls = k + 1;
                if (ls >= fm.len) { end = fm.len; break; }
                if (fm[ls] != ' ' && fm[ls] != '\t' && fm[ls] != '\n' && fm[ls] != '\r') {
                    end = ls;
                    break;
                }
            }
            k++;
        }
        if (k >= fm.len) end = fm.len;
    }
    if (end > fm.len) end = fm.len;

    // Match `word` as a whole token so `module` does not match `module-code`
    // and `async` does not match `asyncIterator`.
    char[] seg = fm[i:end - i];
    if (word.len > seg.len) return false;
    usz max_i = seg.len - word.len;
    for (usz s = 0; s <= max_i; s++) {
        bool match = true;
        for (usz j = 0; j < word.len; j++) {
            if (seg[s + j] != word[j]) { match = false; break; }
        }
        if (!match) continue;
        if (s > 0) {
            char b = seg[s-1];
            if ((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
                || b == '-' || b == '_') { continue; }
        }
        usz a_at = s + word.len;
        if (a_at < seg.len) {
            char a = seg[a_at];
            if ((a >= 'a' && a <= 'z') || (a >= 'A' && a <= 'Z') || (a >= '0' && a <= '9')
                || a == '-' || a == '_') { continue; }
        }
        return true;
    }
    return false;
}

// ============================================================================
// Helper: compile and execute JS source in a VM
// ============================================================================

// The `message` of the value currently in hp.error_value, or an empty slice
// when there is none. The thrown value is the only record of a runtime error:
// lx.err_msg is the lexer's buffer and holds compile errors only, so reading
// it after execute() returns 512 zero bytes rather than the error.
fn char[] thrown_message(Heap* hp) {
    if (!hp.error_value.is_object()) return "";
    HObject* eo = (HObject*)hp.error_value.get_heapptr();
    if (eo == null) return "";
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
                HString* str = (HString*)mv.get_heapptr();
                return str.get_data();
            }
            val_idx++;
        }
        sh = sh.parent_shape;
    }
    return "";
}

fn int exec_js(Vm* v, Heap* hp, char[] src) {
    Lexer lx = lexer::lexer_init(src, hp);
    defer lx.free_arena();
    lx.skip_hashbang();
    CompiledFunction*? f = compiler::compile(&lx, hp);
    if (catch err = f) {
        usz mlen = 0;
        while (mlen < lx.err_msg.len && lx.err_msg[mlen] != 0) { mlen++; }
        io::eprintfn("  COMPILE ERROR: %s", (String)lx.err_msg[:mlen]);
        return 2;
    }
    if (catch err = v.execute(f)) {
        io::eprintfn("  RUNTIME ERROR (compiled ok, %d insns): %s", f.code_count, (String)thrown_message(hp));
        return 1;
    }
    return 0;
}

// ============================================================================
// Run one test, reusing an already-reset heap and VM
// ============================================================================

const char[] MIN_HARNESS = "var __test262_fail=0;function Test262Error(msg){this.message=msg||'';}Test262Error.prototype.toString=function(){return'Test262Error: '+this.message;};Test262Error.thrower=function(m){throw new Test262Error(m);};function $DONOTEVALUATE(){throw'Test262: This statement should not be evaluated.';}function $ERROR(msg){__test262_fail++;}function $FAIL(msg){__test262_fail++;}function isNegativeZero(v){return v===0&&1/v===-Infinity;}function isPrimitive(v){return!v||(typeof v!=='object'&&typeof v!=='function');}function formatIdentityFreeValue(v){switch(v===null?'null':typeof v){case'string':return typeof JSON!=='undefined'?JSON.stringify(v):'\"'+v+'\"';case'bigint':return String(v)+'n';case'number':if(isNegativeZero(v))return'-0';case'boolean':case'undefined':case'null':return String(v);}return'';}function formatSimpleValue(v){var b=formatIdentityFreeValue(v);if(b)return b;try{return String(v);}catch(e){if(e.name==='TypeError')return Object.prototype.toString.call(v);throw e;}}function assert(m,b){if(m===true)return;if(b===undefined)b='Expected true but got '+assert._toString(m);throw new Test262Error(b);}assert._isSameValue=function(a,b){if(a===b)return a!==0||1/a===1/b;return a!==a&&b!==b;};assert.sameValue=function(a,e,m){try{if(assert._isSameValue(a,e))return;}catch(e){throw new Test262Error(m+'(_isSameValue threw)'+e);}if(m===undefined)m='';else m+=' ';m+='Expected SameValue(\\u00AB'+assert._toString(a)+'\\u00BB, \\u00AB'+assert._toString(e)+'\\u00BB) to be true';throw new Test262Error(m);};assert.notSameValue=function(a,u,m){if(!assert._isSameValue(a,u))return;if(m===undefined)m='';else m+=' ';m+='Expected SameValue(\\u00AB'+assert._toString(a)+'\\u00BB, \\u00AB'+assert._toString(u)+'\\u00BB) to be false';throw new Test262Error(m);};assert.throws=function(e,f,m){if(typeof f!=='function')throw new Test262Error('assert.throws requires two arguments');if(m===undefined)m='';else m+=' ';try{f();}catch(t){if(typeof t!=='object'||t===null){m+='Thrown value was not an object!';throw new Test262Error(m);}if(t instanceof e)return;m+='Expected a '+e.name+' but got a '+(t.constructor?t.constructor.name:typeof t);throw new Test262Error(m);}m+='Expected a '+e.name+' to be thrown but no exception was thrown at all';throw new Test262Error(m);};assert._toString=function(o){try{return''+o;}catch(e){return'[error in toString: '+e.message+']';}};";

// Simplified nativeFunctionMatcher without unicode regex escapes.
const char[] NFM_HARNESS = "function validateNativeFunctionSource(source){var pos=0;function isNewline(c){var n=c.charCodeAt(0);return n===10||n===13||n===8232||n===8233;}function isWhitespace(c){var n=c.charCodeAt(0);return n===9||n===11||n===12||n===32||n===160||n===65279;}function eatWhitespace(){while(pos<source.length){var c=source[pos];if(isWhitespace(c)||isNewline(c)){pos++;continue;}if(c==='/'){if(source[pos+1]==='/'){while(pos<source.length){if(isNewline(source[pos]))break;pos++;}continue;}if(source[pos+1]==='*'){var end=source.indexOf('*/',pos);if(end===-1)throw SyntaxError();pos=end+2;continue;}}break;}}function isIDStart(c){return/[A-Za-z_$]/.test(c);}function isIDContinue(c){return/[0-9A-Za-z_$]/.test(c);}function getIdentifier(){eatWhitespace();var start=pos;var end=pos;switch(source[end]){case'_':case'$':end++;break;default:if(isIDStart(source[end])){end++;break;}return null;}while(end<source.length){var c=source[end];switch(c){case'_':case'$':end++;break;default:if(isIDContinue(c)){end++;break;}return source.slice(start,end);}}return source.slice(start,end);}function test(s){eatWhitespace();if(/\\w/.test(s))return getIdentifier()===s;return source.slice(pos,pos+s.length)===s;}function eat(s){if(test(s)){pos+=s.length;return true;}return false;}function eatIdentifier(){var n=getIdentifier();if(n!==null){pos+=n.length;return true;}return false;}function expect(s){if(!eat(s))throw SyntaxError();}function eatString(){var ch=source.charCodeAt(pos);if(ch===39||ch===34){var match=ch;pos++;while(pos<source.length){var cur=source.charCodeAt(pos);if(cur===match&&source.charCodeAt(pos-1)!==92)return;if(isNewline(source[pos]))throw SyntaxError();pos++;}throw SyntaxError();}}function stumbleUntil(c){var m={']':'[',')':'('}[c];var nesting=1;while(pos<source.length){eatWhitespace();eatString();if(source[pos]===m)nesting++;else if(source[pos]===c)nesting--;pos++;if(nesting===0)return;}throw SyntaxError();}expect('function');eat('get')||eat('set');if(!eatIdentifier()&&eat('['))stumbleUntil(']');expect('(');stumbleUntil(')');expect('{');expect('[');expect('native');expect('code');expect(']');expect('}');eatWhitespace();if(pos!==source.length)throw SyntaxError();}function assertToStringOrNativeFunction(fn,expected){var actual=''+fn;try{assert.sameValue(actual,expected);}catch(unused){assertNativeFunction(fn,expected);}}function assertNativeFunction(fn,special){var actual=''+fn;try{validateNativeFunctionSource(actual);}catch(unused){throw new Test262Error('Conforms to NativeFunction Syntax: '+JSON.stringify(actual)+(special?' ('+special+')':''));}}";

const char[] ISCON_HARNESS = "function isConstructor(f){try{var p=new Proxy({},{getPrototypeOf:function(){return null;}});new f(p);return true;}catch(e){return false;}}";

// Minimal $262 host object providing detachArrayBuffer, global, and evalScript.
const char[] HOST262_HARNESS = "var $262={detachArrayBuffer:function(b){return __detachArrayBuffer(b);},global:this,gc:function(){},evalScript:function(s){return __evalScript(s);},createRealm:function(){throw new Error('createRealm not supported');},agent:{},AbstractModuleSource:__AbstractModuleSource};";

// Parse test262 frontmatter for `includes:` and load required harness files.
fn void load_test_includes(Vm* v, Heap* hp, char[] src) {
    char[] fm = frontmatter(src);
    usz i = find_key(fm, "includes:");
    if (i >= fm.len) return;
    while (i < fm.len && (fm[i] == ' ' || fm[i] == '\t')) { i++; }

    // Inline `includes: [a.js, b.js]`, or the block form
    //     includes:
    //       - a.js
    // The block ends at the first line that is neither blank nor indented.
    usz end = fm.len;
    bool inline_form = i < fm.len && fm[i] == '[';
    if (inline_form) {
        i++;
        for (usz k = i; k < fm.len; k++) {
            if (fm[k] == ']') { end = k; break; }
        }
    } else {
        usz k = i;
        while (k < fm.len) {
            if (fm[k] == '\n') {
                usz ls = k + 1;
                if (ls >= fm.len) break;
                if (fm[ls] != ' ' && fm[ls] != '\t' && fm[ls] != '\n' && fm[ls] != '\r') {
                    end = ls;
                    break;
                }
            }
            k++;
        }
    }
    if (end > fm.len) end = fm.len;

    while (i < end) {
        while (i < end && (fm[i] == ' ' || fm[i] == '\t' || fm[i] == ',' || fm[i] == '\n'
            || fm[i] == '\r' || fm[i] == '-')) { i++; }
        if (i >= end) break;
        usz start = i;
        while (i < end && fm[i] != ',' && fm[i] != ' ' && fm[i] != '\t' && fm[i] != '\n'
            && fm[i] != '\r') { i++; }
        usz stop = i;
        if (stop <= start) break;

        char[128] path_buf;
        char[] prefix = "test262/harness/";
        usz pn = 0;
        for (usz k = 0; k < prefix.len && pn < 127; k++) { path_buf[pn++] = prefix[k]; }
        for (usz k = start; k < stop && pn < 127; k++) { path_buf[pn++] = fm[k]; }
        path_buf[pn] = 0;

        // nativeFunctionMatcher.js is preloaded as NFM_HARNESS; the on-disk
        // copy uses unicode regex escapes the engine does not accept yet.
        {
            char[] want = "nativeFunctionMatcher.js";
            usz flen = stop - start;
            if (flen == want.len) {
                bool same = true;
                for (usz k = 0; k < flen; k++) {
                    if (fm[start + k] != want[k]) { same = false; break; }
                }
                if (same) continue;
            }
        }

        char[]? h_opt = file::load_temp((String)path_buf[:pn]);
        if (try h = h_opt) {
            exec_js(v, hp, h);
        }
    }
}

// Check for the `async` flag in frontmatter.
fn bool is_async_test(char[] src) {
    return has_flag(src, "async");
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

// Check for the `module` flag in frontmatter, or top-level module syntax in
// the module-only areas of the tree for tests that omit the flag.
fn bool is_module_test(char[] path, char[] src) {
    if (has_flag(src, "module")) return true;
    if (frontmatter(src).len != 0 && contains_substr(frontmatter(src), "flags:")) return false;
    return (contains_substr(path, "language/module-code/") ||
        contains_substr(path, "language/import/") ||
        contains_substr(path, "language/export/"))
        && (contains_substr(src, "import") || contains_substr(src, "export"));
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
    char[] fm = frontmatter(src);
    usz i = find_key(fm, "negative:");
    if (i >= fm.len) return 0;
    // `type:` is indented under `negative:`, so find_key's column-0 rule does
    // not apply here; search the remainder of the block directly.
    char[] rest = fm[i:fm.len - i];
    usz t = rest.len;
    for (usz k = 0; k + 5 <= rest.len; k++) {
        if (rest[k] == 't' && rest[k+1] == 'y' && rest[k+2] == 'p' && rest[k+3] == 'e'
            && rest[k+4] == ':') { t = k + 5; break; }
    }
    if (t >= rest.len) return 0;
    while (t < rest.len && (rest[t] == ' ' || rest[t] == '\t')) { t++; }
    usz st = t;
    while (t < rest.len && (
        (rest[t] >= 'A' && rest[t] <= 'Z') || (rest[t] >= 'a' && rest[t] <= 'z')
        || (rest[t] >= '0' && rest[t] <= '9') || rest[t] == '_')) { t++; }
    usz n = t - st;
    if (n == 0 || n > out.len) return 0;
    for (usz k = 0; k < n; k++) { out[k] = rest[st + k]; }
    return n;
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
    char[] fm = frontmatter(src);
    usz i = find_key(fm, "negative:");
    if (i >= fm.len) return NegPhase.NONE;
    char[] rest = fm[i:fm.len - i];
    usz ph = rest.len;
    for (usz k = 0; k + 6 <= rest.len; k++) {
        if (rest[k] == 'p' && rest[k+1] == 'h' && rest[k+2] == 'a' && rest[k+3] == 's'
            && rest[k+4] == 'e' && rest[k+5] == ':') { ph = k + 6; break; }
    }
    if (ph >= rest.len) return NegPhase.NONE;
    while (ph < rest.len && (rest[ph] == ' ' || rest[ph] == '\t')) { ph++; }
    char[] tail = rest[ph:rest.len - ph];
    if (tail.len >= 5 && tail[0] == 'p' && tail[1] == 'a' && tail[2] == 'r'
        && tail[3] == 's' && tail[4] == 'e') { return NegPhase.PARSE; }
    if (tail.len >= 10 && tail[0] == 'r' && tail[1] == 'e' && tail[2] == 's'
        && tail[3] == 'o' && tail[4] == 'l' && tail[5] == 'u' && tail[6] == 't'
        && tail[7] == 'i' && tail[8] == 'o' && tail[9] == 'n') { return NegPhase.RESOLUTION; }
    if (tail.len >= 7 && tail[0] == 'r' && tail[1] == 'u' && tail[2] == 'n'
        && tail[3] == 't' && tail[4] == 'i' && tail[5] == 'm' && tail[6] == 'e') { return NegPhase.RUNTIME; }
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

    // The real assert.js replaces MIN_HARNESS's cut-down assert. Losing it is
    // fatal rather than a warning: without it every assert.throws in the suite
    // falls back to a weaker check, and a test that should fail reports PASS.
    {
        char[] asrc = assert_src;
        char[]? asrc_disk;
        if (asrc.len == 0) {
            asrc_disk = file::load_temp((String)"test262/harness/assert.js");
            if (try a = asrc_disk) { asrc = a; }
        }
        if (asrc.len == 0) {
            io::eprintfn("  FAIL: assert.js could not be read (run from the repo root)");
            return 1;
        }
        if (exec_js(v, hp, asrc) != 0) { io::eprintfn("  FAIL: assert.js"); return 1; }
    }

    if (property_helper_src.len > 0) {
        if (exec_js(v, hp, property_helper_src) != 0) { io::eprintfn("  FAIL: propertyHelper.js"); }
    }

    if (exec_js(v, hp, NFM_HARNESS) != 0) { io::eprintfn("  FAIL: NFM_HARNESS"); }
    if (exec_js(v, hp, ISCON_HARNESS) != 0) { io::eprintfn("  FAIL: ISCON_HARNESS"); }
    if (exec_js(v, hp, HOST262_HARNESS) != 0) { io::eprintfn("  FAIL: HOST262_HARNESS"); }

    // Async harness setup. doneprintHandle.js defines $DONE and is only
    // included for `flags: [async]` tests: harness/asyncHelpers-asyncTest-
    // without-async-flag.js asserts $DONE is absent without the flag.
    bool async_test = is_async_test(src);
    if (async_test) {
        char[]? done_src_opt = file::load_temp((String)"test262/harness/doneprintHandle.js");
        if (try ds = done_src_opt) {
            if (exec_js(v, hp, ds) != 0) { io::eprintfn("  FAIL: doneprintHandle.js"); }
        }
        char[] async_setup = "var __test262_async_done=0;var __test262_async_error=null;(function(){var _origDONE=$DONE;$DONE=function(err){__test262_async_done=1;if(err){__test262_async_error=String(err);__test262_fail++;}_origDONE(err);};})();";
        exec_js(v, hp, async_setup);
    }

    load_test_includes(v, hp, src);

    // Prepend strict directive when the onlyStrict flag is set.
    bool only_strict = has_flag(src, "onlyStrict");
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
        char[] em = thrown_message(hp);
        if (em.len > 0) { io::eprintfn("  DEBUG_ERR: %s", (String)em); }
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

    // $ERROR/$FAIL bump this counter instead of throwing. The test has already
    // run to completion without an exception by this point, so a counter that
    // cannot be read is a runner fault, not a test failure: say so rather than
    // returning a bare FAIL that reads exactly like a real one.
    char[] kn = "__test262_fail";
    uint hh = hp.hash_string(kn);
    HString*? ks = hp.str_table_lookup(kn, hh);
    if (catch ks) {
        io::eprintfn("  FAIL: runner could not read %s (harness did not load)", (String)kn);
        return 1;
    }
    TVal? tv = env::env_get(v.global_env, ks);
    if (catch tv) {
        io::eprintfn("  FAIL: runner could not read %s (binding missing)", (String)kn);
        return 1;
    }
    if (tv.get_fastint() == 0) return 0;
    io::eprintfn("  FAIL: test called $ERROR/$FAIL %d time(s)", tv.get_fastint());
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
