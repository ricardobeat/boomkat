// RegExp constructor and RegExp.prototype methods.
module boomkat::builtins;
import boomkat::types;
import std::io;
import boomkat::hstring;
import boomkat::env;
import boomkat::vm;
import boomkat::heap;
import boomkat::hobject;
import boomkat::gcprofile;
import boomkat::re_bindings;
import boomkat::builtins::growvec;
import std::math;

// ============================================================================
// RegExp constructor builtins
// ============================================================================

// Helper: extract the compiled regexp data pointer from 'this'.
// Returns null if 'this' is not a REGEXP-class object.
fn HObject* regexp_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) return null;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.REGEXP) return null;
    return obj;
}

// RegExp(pattern, flags), ECMA-262 §15.10.3 (called as function) / §15.10.4 (constructor).
// When called as a function (not constructor), behaviour is identical to construction.
fn void builtin_regexp(BuiltinContext* ctx) {
    // Get pattern
    bool is_regexp = false;
    HObject* pattern_regexp = null;  // Saved pointer for RegExp→RegExp constructor shortcut
    HString* pattern_hs = null;  // null stands for the empty pattern
    int js_flags = 0;  // JS flag bits: 1=g, 2=i, 4=m
    HString* flags_hs = null;    // null stands for no flags
    // References to strings that a getter or a coercion returned: the result
    // of a call belongs to the pending return value until the next call
    // replaces it, and the checks below make further calls.
    HString* held_pattern = null;
    HString* held_flags = null;
    defer builtin_unhold(ctx, held_pattern);
    defer builtin_unhold(ctx, held_flags);
    TVal pattern_arg;
    pattern_arg.set_undefined();
    // ECMA-262 §22.2.4.1 step 1.c: `flags is undefined` -- whether the CALLER
    // passed an explicit flags argument, distinct from flags_hs (which also
    // gets populated later from pattern.flags in the regexp-like-object
    // fallback path, e.g. `RegExp(obj)` with no second arg but obj.flags ===
    // "i" leaves flags_hs set). The identity-return shortcut below must
    // gate on the former, not the latter.
    bool flags_arg_provided = ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined();
    // ECMA-262 §22.2.4.1 steps 3-4: ToString(P) and ToString(F) belong to
    // RegExpInitialize, which runs AFTER RegExpAlloc(newTarget) has read
    // newTarget.prototype. Both coercions are observable (user toString) and
    // so is the prototype getter, so the pattern coercion is only recorded
    // here and performed below, once the object exists.
    bool pattern_needs_tostring = false;

    if (ctx.argc > 0) {
        pattern_arg = ctx.regs[ctx.base_reg];
        if (pattern_arg.is_object() && pattern_arg.get_heapptr() != null) {
            HObject* obj = (HObject*)pattern_arg.get_heapptr();
            // ECMA-262 §22.2.3.1 step 1: IsRegExp(pattern), check @@match to detect
            // regexp-like objects.
            bool pattern_is_regexp = false;
            bool is_actual_regexp = (obj.get_class() == hobject::ObjClass.REGEXP && (*obj.extra_ptr()).regexp.regexp_data != null);
            if (ctx.vm != null) {
                // IsRegExp spec steps 2-3: Get(obj, @@match). If defined, return ToBoolean.
                HString* match_sym = ensure_match_symbol(ctx.heap);
                bool checked_match = false;
                if (match_sym != null) {
                    TVal? match_opt = builtins_generic_get(obj, match_sym, ctx);
                    if (ctx.should_throw) return;
                    if (try mv = match_opt) {
                        if (!mv.is_undefined()) {
                            // @@match is defined: IsRegExp = ToBoolean(@@match)
                            pattern_is_regexp = builtin_to_boolean(&mv);
                            checked_match = true;
                        }
                    }
                }
                // IsRegExp spec step 4: if @@match was undefined and has [[RegExpMatcher]], return true.
                if (!checked_match && is_actual_regexp) {
                    pattern_is_regexp = true;
                }
            } else if (is_actual_regexp) {
                // No VM available: fall back to internal slot check.
                pattern_is_regexp = true;
            }
            if (is_actual_regexp && pattern_is_regexp) {
                // Pattern is an actual RegExp object with truthy @@match, extract its pattern
                is_regexp = true;
                pattern_regexp = obj;
                if ((*obj.extra_ptr()).prim.primitive_value.is_string()) {
                    HString* phs = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
                    pattern_hs = phs;
                }
            } else if (pattern_is_regexp) {
                // ECMA-262 §22.2.3.1 step 6: regexp-like non-RegExp object, extract source and flags.
                is_regexp = true;

                // ECMA-262 §22.2.4.1 step 1.c: the "return the pattern unchanged"
                // shortcut (`RegExp(re)` called as a function, no explicit
                // flags, pattern's own "constructor" is the RegExp
                // constructor) must be checked BEFORE ever reading
                // "source"/"flags" -- those getters must not fire at all
                // when the shortcut applies (they're irrelevant to the
                // decision and the object is returned as-is regardless of
                // what they'd report).
                if (!ctx.is_constructor && flags_arg_provided == false) {
                    HString* ctor_key_early = ctx.heap.str(heap::BuiltinStr.CONSTRUCTOR);
                    TVal? ctor_opt_early = builtins_generic_get(obj, ctor_key_early, ctx);
                    if (ctx.should_throw) return;
                    if (try cv = ctor_opt_early) {
                        if (cv.is_object() && cv.get_heapptr() != null) {
                            HObject* ctor_obj_early = (HObject*)cv.get_heapptr();
                            if (ctor_obj_early.get_class() == hobject::ObjClass.FUNCTION &&
                                (*ctor_obj_early.extra_ptr()).func.builtin_fn_index == (int)Builtin.REGEXP.ordinal
                                && (*ctor_obj_early.extra_ptr()).func.realm == ctx.heap.realm) {
                                ctx.copy_result(pattern_arg);
                                return;
                            }
                        }
                    }
                }

                // Step 6a: P = Get(pattern, "source")
                HString* source_key = ctx.heap.str(heap::BuiltinStr.SOURCE);
                TVal? src_opt = builtins_generic_get(obj, source_key, ctx);
                if (ctx.should_throw) return;
                if (try sv = src_opt) {
                    if (sv.is_string() && sv.get_heapptr() != null) {
                        HString* src_hs = (HString*)sv.get_heapptr();
                        if (src_hs.is_symbol()) {
                            arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
                            return;
                        }
                        held_pattern = builtin_hold(src_hs);
                        pattern_hs = src_hs;
                    } else {
                        HString* src_hs = builtin_to_string_vm(ctx, &sv);
                        if (ctx.should_throw) return;
                        if (src_hs != null) {
                            held_pattern = builtin_hold(src_hs);
                            pattern_hs = src_hs;
                        }
                    }
                }
                // Step 6c: If flags argument is undefined, F = Get(pattern, "flags")
                if (!flags_arg_provided) {
                    HString* flags_key = ctx.heap.str(heap::BuiltinStr.FLAGS);
                    TVal? fl_opt = builtins_generic_get(obj, flags_key, ctx);
                    if (ctx.should_throw) return;
                    if (try fv = fl_opt) {
                        // If Get(pattern, "flags") is undefined, treat as empty string
                        // (RegExpInitialize step 3: if flags is undefined, use "").
                        if (!fv.is_undefined() && !fv.is_null()) {
                            if (fv.is_string() && fv.get_heapptr() != null) {
                                HString* fl_hs = (HString*)fv.get_heapptr();
                                if (fl_hs.is_symbol()) {
                                    arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
                                    return;
                                }
                                held_flags = builtin_hold(fl_hs);
                                flags_hs = fl_hs;
                            } else {
                                HString* fl_hs = builtin_to_string_vm(ctx, &fv);
                                if (ctx.should_throw) return;
                                if (fl_hs != null) {
                                    held_flags = builtin_hold(fl_hs);
                                    flags_hs = fl_hs;
                                }
                            }
                        }
                        // undefined/null flags → flags_hs stays null (empty).
                    }
                }
                // Skip the ToString fallthrough and flags-from-arg below.
            } else {
                // Not a regexp-like object: the pattern needs ToString, but
                // RegExpInitialize (step 4) runs it only AFTER RegExpAlloc
                // (step 3) has read newTarget.prototype. Defer it.
                pattern_needs_tostring = true;
            }
        } else if (pattern_arg.is_string() && pattern_arg.get_heapptr() != null) {
            pattern_hs = (HString*)pattern_arg.get_heapptr();
        } else if (!pattern_arg.is_undefined()) {
            // ECMA-262 §15.10.4.1: if pattern is undefined, use empty string.
            // Only convert to string when pattern is not undefined. Deferred
            // past RegExpAlloc for the same ordering reason as above.
            pattern_needs_tostring = true;
        }
        // else: pattern_arg is undefined → use the empty pattern (pattern_hs = null)
    }

    // ECMA-262 §22.2.4.1 step 3.a: the "return the pattern unchanged" shortcut is
    // reachable only when NewTarget is undefined, i.e. `RegExp(re)` called as a
    // function. Step 1 takes it only `If NewTarget is undefined`; with `new` the
    // constructor must always allocate a fresh object, so `new RegExp(re) !== re`.
    // Returning the same object let a later
    // `Object.defineProperty(copy, "lastIndex", {writable: false})` freeze the
    // ORIGINAL regexp's lastIndex, so an unrelated `re.lastIndex = n` then threw.
    // This is the actual-RegExp-instance path only now (pattern_regexp != null);
    // the regexp-like-object shortcut above already handled (and returned for)
    // its own case before ever reading source/flags.
    if (!ctx.is_constructor && is_regexp && flags_arg_provided == false && pattern_regexp != null) {
        // Use pattern_regexp (set for actual RegExp) or the original arg (for regexp-like)
        HObject* ctor_check_obj = pattern_regexp;
        if (ctor_check_obj == null && pattern_arg.is_object() && pattern_arg.get_heapptr() != null) {
            ctor_check_obj = (HObject*)pattern_arg.get_heapptr();
        }
        if (ctor_check_obj != null) {
            // Check if the pattern's constructor is the RegExp constructor itself
            HString* ctor_key = ctx.heap.str(heap::BuiltinStr.CONSTRUCTOR);
            TVal? ctor_opt = builtins_generic_get(ctor_check_obj, ctor_key, ctx);
            if (ctx.should_throw) return;
            if (try cv = ctor_opt) {
                if (cv.is_object() && cv.get_heapptr() != null) {
                    HObject* ctor_obj = (HObject*)cv.get_heapptr();
                    // Check if ctor_obj is the global RegExp constructor
                    // (builtin_fn_index == Builtin.REGEXP.ordinal)
                    if (ctor_obj.get_class() == hobject::ObjClass.FUNCTION &&
                        (*ctor_obj.extra_ptr()).func.builtin_fn_index == (int)Builtin.REGEXP.ordinal
                        && (*ctor_obj.extra_ptr()).func.realm == ctx.heap.realm) {
                        // SameValue: same constructor → return the original pattern object
                        ctx.copy_result(pattern_arg);
                        return;
                    }
                }
            }
        }
        // Constructor mismatch, fall through to create a new RegExp with pattern's source/flags
        // Extract pattern source and flags from the original regexp (if actual RegExp object)
        if (pattern_regexp != null) {
            js_flags = (*pattern_regexp.extra_ptr()).regexp.flags;
            flags_hs = null;  // Clear flags so we don't re-parse
        }
    } else if (is_regexp && !flags_arg_provided && pattern_regexp != null) {
        // `new RegExp(re)`: no shortcut, but the copy still inherits the
        // source pattern's flags (step 3.a passes them to RegExpInitialize).
        // Gated on flags_arg_provided, not flags_len: the flags argument is
        // now coerced AFTER this point (see step 3/4 ordering below), so
        // flags_hs is still null here even for `new RegExp(re, "")`, which must
        // NOT inherit the source's flags.
        js_flags = (*pattern_regexp.extra_ptr()).regexp.flags;
    }

    // ECMA-262 §22.2.4.1 step 3: O = RegExpAlloc(newTarget). This reads
    // newTarget.prototype (an observable, possibly-throwing user getter) and
    // must happen BEFORE RegExpInitialize's ToString(P)/ToString(F) below.
    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.REGEXP);
    if (catch err = obj_raw) {
        ctx.result_undefined();
        return;
    }
    HObject* obj = obj_raw;
    ctx.heap.set_prototype(obj, builtin_proto_from_new_target(ctx, ctx.heap.regexp_proto));
    if (ctx.should_throw) return;
    // Pooled memory is not zeroed, clear the regexp fields before
    // regexp_initialize reads them (it re_frees any previous compiled data).
    (*obj.extra_ptr()).regexp.regexp_data = null;
    (*obj.extra_ptr()).regexp.flags = 0;
    (*obj.extra_ptr()).prim.primitive_value.set_undefined();

    // ECMA-262 §22.2.4.1 step 4: RegExpInitialize(O, P, F) -- the deferred
    // ToString coercions, now correctly ordered after the prototype read.
    // `obj` is temproot-pinned by alloc_object, so it survives any GC these
    // user-visible calls may trigger.
    if (pattern_needs_tostring) {
        HString* phs;
        if (ctx.vm != null) {
            phs = builtin_to_string_vm(ctx, &pattern_arg);
            if (ctx.should_throw) return;
        } else {
            phs = builtin_to_string(ctx.heap, &pattern_arg);
        }
        if (phs != null) {
            held_pattern = builtin_hold(phs);
            pattern_hs = phs;
        }
    }
    if (ctx.argc > 1) {
        TVal* flags_arg = &ctx.regs[ctx.base_reg + 1];
        if (flags_arg.is_string() && flags_arg.get_heapptr() != null) {
            flags_hs = (HString*)flags_arg.get_heapptr();
        } else if (!flags_arg.is_undefined()) {
            HString* fhs;
            if (ctx.vm != null) {
                fhs = builtin_to_string_vm(ctx, flags_arg);
                if (ctx.should_throw) return;
            } else {
                fhs = builtin_to_string(ctx.heap, flags_arg);
            }
            if (fhs != null) {
                held_flags = builtin_hold(fhs);
                flags_hs = fhs;
            }
        }
    }

    if (!regexp_initialize(ctx, obj, pattern_hs, flags_hs, js_flags)) return;
    ctx.result_object(obj);
}

// RegExpInitialize (ECMA-262 §22.2.3.2.2): parse `flags_str`, compile
// `pattern_str`, and install the result on `obj` (REGEXP class), replacing
// any previous compiled data (re_free is refcounted) and resetting
// lastIndex to 0. `js_flags` seeds the JS flag bits for callers that take
// flags from another RegExp's internals instead of a string (pass 0
// otherwise). On invalid flags or a pattern that fails to compile, throws
// SyntaxError via ctx and returns false leaving `obj` untouched.
fn bool regexp_initialize(BuiltinContext* ctx, HObject* obj,
                          HString* pattern, HString* flag_text,
                          int js_flags = 0) {
    // Parse the flags string into JS flag bits.
    // ECMA-262 §21.2.3.2.2 step 5: if F contains the same code unit more than
    // once, or an unrecognized one, throw SyntaxError.
    int seen_flags = 0;
    uint flags_len = flag_text == null ? 0 : flag_text.unit_len();
    for (uint i = 0; i < flags_len; i++) {
        uint unit = flag_text.unit_at(i);
        char f = unit < 0x80 ? (char)unit : 0;
        int flag_bit;
        switch (f) {
            case 'g': flag_bit = 1;
            case 'i': flag_bit = 2;
            case 'm': flag_bit = 4;
            case 's': flag_bit = 8;
            case 'u': flag_bit = 16;
            case 'y': flag_bit = 32;
            case 'd': flag_bit = 64;
            case 'v': flag_bit = 128;
            default:  flag_bit = 0;
        }
        // Invalid or duplicate flag, throw SyntaxError.
        if (flag_bit == 0 || (seen_flags & flag_bit) != 0) {
            char[80] buf;
            int len = f == 0 ? 0 : (int)(io::bprintf(&buf, "Invalid flags supplied to RegExp constructor '%c'", f) ?? buf[:0]).len;
            builtin_throw_no_result_change(ctx, ctx.heap.syntax_err_proto,
                (len > 0 && len < 80) ? buf[:len] : "Invalid flags supplied to RegExp constructor");
            return false;
        }
        seen_flags |= flag_bit;
        js_flags |= flag_bit;
    }

    // Derive libregexp flag bits from the JS flag bits (covers both parsed
    // flags and flags inherited from another RegExp's internals).
    int flags = 0;
    if ((js_flags & 2)   != 0) flags |= re_bindings::RE_FLAG_IGNORECASE;
    if ((js_flags & 4)   != 0) flags |= re_bindings::RE_FLAG_MULTILINE;
    if ((js_flags & 8)   != 0) flags |= re_bindings::RE_FLAG_DOTALL;
    if ((js_flags & 16)  != 0) flags |= re_bindings::RE_FLAG_UNICODE;
    if ((js_flags & 32)  != 0) flags |= re_bindings::RE_FLAG_STICKY;
    if ((js_flags & 64)  != 0) flags |= re_bindings::RE_FLAG_INDICES;
    if ((js_flags & 128) != 0) flags |= re_bindings::RE_FLAG_UNICODE_SETS;

    // Compile the regexp from the pattern's CESU-8 text.
    StrBuf pattern_text;
    pattern_text.init(ctx.heap);
    defer pattern_text.free();
    char[] pattern_bytes = pattern == null ? (char[])"" : cesu8_text(&pattern_text, pattern);
    char[128] error_buf;
    void* compiled = re_bindings::re_compile(
        pattern_bytes.ptr, pattern_bytes.len,
        flags, &error_buf, 128
    );
    if (compiled == null) {
        // Compilation failed, throw SyntaxError (ECMA-262 §15.10.4.1).
        // Slice to the null-terminated length instead of the full 128-byte
        // buffer, which would include trailing NUL bytes in the message.
        usz msg_len = (usz)((ZString)&error_buf).len();
        builtin_throw_no_result_change(ctx, ctx.heap.syntax_err_proto, error_buf[:msg_len]);
        return false;
    }

    // Drop any previous compiled data (re-initialization via compile();
    // re_free only frees at refcount zero).
    void* old_data = (*obj.extra_ptr()).regexp.regexp_data;
    if (old_data != null) re_bindings::re_free(old_data);
    // Takes over re_compile's initial ref, released by re_free on finalize.
    (*obj.extra_ptr()).regexp.regexp_data = compiled;
    (*obj.extra_ptr()).regexp.flags = js_flags;

    // Store pattern string as primitive_value
    HString* pattern_hs = pattern == null ? ctx.heap.str(heap::BuiltinStr.EMPTY)
                                          : ctx.heap.ensure_interned(pattern);
    ctx.heap.set_reg_string(&(*obj.extra_ptr()).prim.primitive_value, pattern_hs);

    // Set lastIndex = 0 (ECMA-262 §15.10.7.5), writable, non-enumerable,
    // non-configurable own data property. RegExpInitialize step 12 is
    // Set(obj, "lastIndex", 0, true): throws TypeError when an existing
    // lastIndex is non-writable (the internals above stay updated).
    HString* lastindex_key = ctx.heap.str(heap::BuiltinStr.LAST_INDEX);
    if (!obj.is_prop_writable((void*)lastindex_key, ctx.heap)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot assign to read only property 'lastIndex'");
        return false;
    }
    TVal lastindex_tv;
    lastindex_tv.set_fastint(0);
    obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WENC, ctx.heap);
    return true;
}

// RegExp.prototype.compile(pattern, flags), ECMA-262 Annex B §B.2.4.1.
// Re-initializes the receiver RegExp in place (recompiles the bytecode,
// updates source/flags internals, resets lastIndex to 0) and returns it.
fn void builtin_regexp_proto_compile(BuiltinContext* ctx) {
    // Steps 1-2: receiver must have a [[RegExpMatcher]] internal slot.
    HObject* obj = regexp_get_this(ctx);
    if (obj == null || (*obj.extra_ptr()).regexp.regexp_data == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "RegExp.prototype.compile called on incompatible receiver");
        return;
    }

    TVal pattern_arg;
    pattern_arg.set_undefined();
    TVal flags_arg;
    flags_arg.set_undefined();
    if (ctx.argc > 0) pattern_arg = ctx.regs[ctx.base_reg];
    if (ctx.argc > 1) flags_arg = ctx.regs[ctx.base_reg + 1];

    HString* pattern_hs = null;
    HString* flags_hs = null;
    // Coercion results belong to the pending return value until the next call
    // replaces it; see builtin_regexp.
    HString* held_pattern = null;
    HString* held_flags = null;
    defer builtin_unhold(ctx, held_pattern);
    defer builtin_unhold(ctx, held_flags);
    int js_flags = 0;

    HObject* src = null;
    if (pattern_arg.is_object() && pattern_arg.get_heapptr() != null) {
        HObject* pobj = (HObject*)pattern_arg.get_heapptr();
        if (pobj.get_class() == hobject::ObjClass.REGEXP && (*pobj.extra_ptr()).regexp.regexp_data != null) {
            src = pobj;
        }
    }
    if (src != null) {
        // Step 3: pattern has [[RegExpMatcher]], flags must be undefined,
        // then take pattern/flags from its internals.
        if (!flags_arg.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot supply flags when constructing one RegExp from another");
            return;
        }
        if ((*src.extra_ptr()).prim.primitive_value.is_string()) {
            pattern_hs = (HString*)(*src.extra_ptr()).prim.primitive_value.get_heapptr();
        }
        js_flags = (*src.extra_ptr()).regexp.flags;
    } else {
        // Step 4: P = pattern undefined ? "" : ToString(pattern),
        //         F = flags undefined ? "" : ToString(flags).
        if (!pattern_arg.is_undefined()) {
            HString* phs = builtin_to_string_vm(ctx, &pattern_arg);
            if (ctx.should_throw) return;
            if (phs != null) {
                held_pattern = builtin_hold(phs);
                pattern_hs = phs;
            }
        }
        if (!flags_arg.is_undefined()) {
            HString* fhs = builtin_to_string_vm(ctx, &flags_arg);
            if (ctx.should_throw) return;
            if (fhs != null) {
                held_flags = builtin_hold(fhs);
                flags_hs = fhs;
            }
        }
    }

    // Step 5: re-run RegExpInitialize on the SAME object; return the receiver.
    if (!regexp_initialize(ctx, obj, pattern_hs, flags_hs, js_flags)) {
        ctx.result_undefined();
        return;
    }
    ctx.result_object(obj);
}

// RegExp.prototype.test(string), ECMA-262 §22.2.6.15
//
// Delegates to RegExpExec (`regexp_exec_call`, ECMA-262 §22.2.7.1) so that a
// custom `exec` override is honored and lastIndex is handled in UTF-16
// code-unit terms throughout, matching `RegExp.prototype.exec`.
fn void builtin_regexp_proto_test(BuiltinContext* ctx) {
    // Steps 1-2: the receiver need only be an Object. A `this` with no
    // [[RegExpMatcher]] is still valid as long as it carries a callable
    // `exec`; RegExpExec is what rejects a receiver that has neither.
    HObject* obj = regexp_get_symbol_this(ctx);
    if (obj == null) return;

    // Step 3: Let S be ? ToString(string). If no argument, ToString(undefined).
    HString* s_hstr;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        s_hstr = regexp_plain_input(arg);
        if (s_hstr == null) {
            s_hstr = builtin_to_string_vm(ctx, arg);
            if (ctx.should_throw) return;
            if (s_hstr == null) s_hstr = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
        }
    } else {
        s_hstr = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }

    // Step 4: Let match be ? RegExpExec(R, S).
    TVal s_tv; s_tv.set_string(s_hstr);
    defer ctx.heap.decref_tval(&s_tv);
    // The test result is only match success, so intrinsic execution can skip
    // constructing the match array. Custom exec still runs and is validated.
    if (!regexp_exec_call(ctx, obj, &s_tv, true)) return;
}

// The text of `s` between two offsets; all of `s` is `s` itself, which is
// already canonical, so no new string is looked up.
fn HString* regexp_slice(Heap* heap, HString* s, uint from, uint to) @inline {
    if (from == 0 && to == s.length) return s;
    return heap.str_slice(s, from, to);
}

// The null-prototype `groups` object of a match: each group name, in pattern
// order, set to its capture.
fn void regexp_fill_groups(BuiltinContext* ctx, HObject* groups, void* re_data, HString* input_str,
                           int* caps, int num_caps) {
    groups.prototype = null;
    int name_count = re_bindings::re_get_capture_count(re_data) - 1;
    char* p = re_bindings::re_get_groupnames(re_data);
    for (int gi = 0; gi < name_count; gi++) {
        usz name_len = (usz)((ZString)p).len();
        if (name_len > 0) {
            HString* name_str = builtin_intern_string(ctx.heap, p[:name_len]);
            TVal cap_val;
            if (gi < num_caps && caps[2 * gi + 2] >= 0 && caps[2 * gi + 3] >= 0) {
                cap_val.set_string_borrowed(regexp_slice(ctx.heap, input_str, (uint)caps[2 * gi + 2], (uint)caps[2 * gi + 3]));
            } else {
                cap_val.set_undefined();
            }
            // Duplicate names (one per alternative) share this loop;
            // a defined value always wins, but an undefined one must
            // not clobber a value already set by an earlier alternative.
            if (!cap_val.is_undefined() || !groups.has_prop(name_str, ctx.heap)) {
                groups.put_prop(name_str, cap_val, hobject::PROP_FLAGS_WEC, ctx.heap);
            }
        }
        // Each entry is: name bytes + '\0' + scope byte (2 bytes minimum)
        p += (long)(name_len + 2);
    }
}

// Build a RegExp exec/match result array with .groups and optional .indices.
// Its elements are dense, a non-participating capture an `undefined` element
// of a packed array.
fn HObject* regexp_build_match_result(BuiltinContext* ctx, void* re_data, HString* input_str,
                                      int* caps, int num_caps, bool with_indices) {
    Heap* heap = ctx.heap;
    int out_start = caps[0];
    int out_end = caps[1];
    uint elements = (uint)(1 + num_caps);

    // Without `d` the named properties are index, input, groups and length,
    // whatever the capture count. Once one array has settled that shape, the
    // next is allocated with it and each slot written once.
    bool cacheable = !with_indices;
    if (cacheable && heap.match_shape != 0 && heap.match_shape_epoch == heap.shape_recycle_epoch) {
        HObject*? arr_raw;
        if (4 + elements <= hobject::ARRAY_INLINE_MAX_CAPACITY) {
            arr_raw = heap.alloc_inline_array_uninit(4, elements);
        } else {
            arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try a = arr_raw) {
                if (!a.reserve_array_storage(hobject::PROPS_INITIAL_CAPACITY, elements, heap)) return null;
            }
        }
        if (catch err = arr_raw) return null;
        HObject* arr = arr_raw;
        heap.set_prototype(arr, heap.array_proto);
        regexp_fill_match_result(ctx, arr, heap.match_shape, re_data, input_str, caps, num_caps);
        return arr;
    }

    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) return null;
    HObject* arr = arr_raw;
    if (!arr.reserve_array_storage(hobject::PROPS_INITIAL_CAPACITY, elements, heap)) return null;
    heap.set_prototype(arr, heap.array_proto);
    bool packed = regexp_fill_match_elements(heap, arr, input_str, caps, num_caps);
    int total_captures = 1 + num_caps;

    TVal idx_tv; idx_tv.set_fastint((long)out_start);
    arr.put_prop_new(ctx.heap.str(heap::BuiltinStr.INDEX), idx_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

    // input property
    TVal input_tv; input_tv.set_string_borrowed(input_str);
    arr.put_prop_new(ctx.heap.str(heap::BuiltinStr.INPUT), input_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

    // groups property
    char* group_names = re_bindings::re_has_group_names(re_data) ? re_bindings::re_get_groupnames(re_data) : null;
    if (group_names != null) {
        HObject*? groups_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try groups = groups_raw) {
            regexp_fill_groups(ctx, groups, re_data, input_str, caps, num_caps);
            TVal groups_val; groups_val.set_object(groups);
            arr.put_prop_new(ctx.heap.str(heap::BuiltinStr.GROUPS), groups_val, hobject::PROP_FLAGS_WEC, ctx.heap);
        }
    } else {
        TVal groups_undef; groups_undef.set_undefined();
        arr.put_prop_new(ctx.heap.str(heap::BuiltinStr.GROUPS), groups_undef, hobject::PROP_FLAGS_WEC, ctx.heap);
    }

    // indices property (ECMA-262 d-flag)
    if (with_indices) {
        HObject*? indices_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (try indices_arr = indices_raw) {
            ctx.heap.set_prototype(indices_arr, ctx.heap.array_proto);

            // indices[0]
            HObject*? pair0_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try pair0 = pair0_raw) {
                ctx.heap.set_prototype(pair0, ctx.heap.array_proto);
                TVal p0s; p0s.set_fastint((long)out_start);
                TVal p0e; p0e.set_fastint((long)out_end);
                pair0.put_prop(ctx.heap.int_to_hstring(0), p0s, hobject::PROP_FLAGS_WEC, ctx.heap);
                pair0.put_prop(ctx.heap.int_to_hstring(1), p0e, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal pair0_tv; pair0_tv.set_object(pair0);
                indices_arr.put_prop(ctx.heap.int_to_hstring(0), pair0_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
            }

            for (int i = 0; i < num_caps; i++) {
                HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (catch err = pair_raw) continue;
                HObject* pair = pair_raw;
                ctx.heap.set_prototype(pair, ctx.heap.array_proto);
                TVal pair_tv;
                if (caps[2 * i + 2] >= 0 && caps[2 * i + 3] >= 0) {
                    TVal ps; ps.set_fastint((long)caps[2 * i + 2]);
                    TVal pe; pe.set_fastint((long)caps[2 * i + 3]);
                    pair.put_prop(ctx.heap.int_to_hstring(0), ps, hobject::PROP_FLAGS_WEC, ctx.heap);
                    pair.put_prop(ctx.heap.int_to_hstring(1), pe, hobject::PROP_FLAGS_WEC, ctx.heap);
                    pair_tv.set_object(pair);
                } else {
                    pair_tv.set_undefined();
                }
                indices_arr.put_prop(ctx.heap.int_to_hstring((long)(i + 1)), pair_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
            }

            // indices.groups
            if (group_names != null) {
                HObject*? igroups_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (try igroups = igroups_raw) {
                    igroups.prototype = null;
                    int name_count = re_bindings::re_get_capture_count(re_data) - 1;
                    char* p = group_names;
                    for (int gi = 0; gi < name_count; gi++) {
                        usz name_len = (usz)((ZString)p).len();
                        if (name_len > 0) {
                            HString* name_str = builtin_intern_string(ctx.heap, p[:name_len]);
                            TVal pair_tv;
                            if (gi < num_caps && caps[2 * gi + 2] >= 0 && caps[2 * gi + 3] >= 0) {
                                HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
                                if (try pair = pair_raw) {
                                    ctx.heap.set_prototype(pair, ctx.heap.array_proto);
                                    TVal ps; ps.set_fastint((long)caps[2 * gi + 2]);
                                    TVal pe; pe.set_fastint((long)caps[2 * gi + 3]);
                                    pair.put_prop(ctx.heap.int_to_hstring(0), ps, hobject::PROP_FLAGS_WEC, ctx.heap);
                                    pair.put_prop(ctx.heap.int_to_hstring(1), pe, hobject::PROP_FLAGS_WEC, ctx.heap);
                                    pair_tv.set_object(pair);
                                } else {
                                    pair_tv.set_undefined();
                                }
                            } else {
                                pair_tv.set_undefined();
                            }
                            // Duplicate names (one per alternative) share this loop;
                            // a defined value always wins, but an undefined one must
                            // not clobber a value already set by an earlier alternative.
                            if (!pair_tv.is_undefined() || !igroups.has_prop(name_str, ctx.heap)) {
                                igroups.put_prop(name_str, pair_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                            }
                        }
                        // Each entry is: name bytes + '\0' + scope byte (2 bytes minimum)
                        p += (sz)(name_len + 2);
                    }
                    TVal igroups_tv; igroups_tv.set_object(igroups);
                    indices_arr.put_prop(ctx.heap.str(heap::BuiltinStr.GROUPS), igroups_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                }
            } else {
                TVal igroups_undef; igroups_undef.set_undefined();
                indices_arr.put_prop(ctx.heap.str(heap::BuiltinStr.GROUPS), igroups_undef, hobject::PROP_FLAGS_WEC, ctx.heap);
            }

            TVal indices_len; indices_len.set_fastint((long)total_captures);
            indices_arr.put_prop(ctx.heap.str(heap::BuiltinStr.LENGTH), indices_len, hobject::PROP_FLAGS_WEC, ctx.heap);

            TVal indices_tv; indices_tv.set_object(indices_arr);
            arr.put_prop(ctx.heap.str(heap::BuiltinStr.INDICES), indices_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
        }
    }

    TVal len_tv; len_tv.set_fastint((long)total_captures);
    arr.put_prop(ctx.heap.str(heap::BuiltinStr.LENGTH), len_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

    arr.gc.packed = packed;

    // Remember the shape when every property above was added, in order, on a
    // shape shared through the transition table.
    if (cacheable && arr.prop_count == 4) {
        hobject::Shape* shape = heap.get_shape(arr.shape_id);
        if (shape != null && shape.parent != hobject::PRIVATE_SHAPE_PARENT && !shape.dict) {
            // Later arrays reach this shape without a transition lookup, which is
            // what marks a shape as shared; without it each would build its own
            // property hash.
            shape.shared = true;
            heap.match_shape = arr.shape_id;
            heap.match_shape_epoch = heap.shape_recycle_epoch;
        }
    }
    return arr;
}

// Gives a freshly allocated RegExp its one own property, lastIndex = 0
// (writable, not enumerable, not configurable; RegExpAlloc step 2). Once one
// RegExp has reached that shape through the transition table, later ones take
// it in a single step.
fn bool regexp_init_last_index(Heap* heap, HObject* rx) {
    TVal zero;
    zero.set_fastint(0);
    if (heap.regexp_shape != 0 && heap.regexp_shape_epoch == heap.shape_recycle_epoch
        && rx.prop_count == 0 && rx.prop_capacity >= 1 && !rx.gc.prototype_observed) {
        hobject::PropValue* slots = rx.prop_values();
        mem::clear(&slots[0], (sz)hobject::PropValue::size);
        heap.store_slot(rx, &slots[0], zero);
        rx.prop_count = 1;
        rx.shape_id = heap.regexp_shape;
        rx.flags.has_nondefault_flags = true;
        return true;
    }
    if (!rx.put_prop(heap.str(heap::BuiltinStr.LAST_INDEX), zero, hobject::PROP_FLAGS_WENC, heap)) return false;
    if (rx.prop_count == 1) {
        hobject::Shape* shape = heap.get_shape(rx.shape_id);
        if (shape != null && shape.parent != hobject::PRIVATE_SHAPE_PARENT && !shape.dict) {
            // As for match arrays: a shape reached without a transition lookup
            // must be marked shared, or each object would build its own hash.
            shape.shared = true;
            heap.regexp_shape = rx.shape_id;
            heap.regexp_shape_epoch = heap.shape_recycle_epoch;
        }
    }
    return true;
}

// Writes the elements of a match array whose dense slots hold nothing yet:
// each group of `caps` (the match first) or `undefined`. Returns whether a
// capture did not participate, which makes the array packed.
fn bool regexp_fill_match_elements(Heap* heap, HObject* arr, HString* input_str, int* caps, int num_caps) {
    hobject::PropValue* part = arr.array_part();
    uint unmatched = 0;
    for (int i = 0; i <= num_caps; i++) {
        if (caps[2 * i] < 0 || caps[2 * i + 1] < 0) {
            part[i].set_untraced(types::make_undefined());
            unmatched++;
            continue;
        }
        TVal elem;
        elem.set_string_borrowed(regexp_slice(heap, input_str, (uint)caps[2 * i], (uint)caps[2 * i + 1]));
        heap.init_slot_ref(arr, &part[i], &elem);
    }
    arr.array_used = (uint)(1 + num_caps) - unmatched;
    *arr.array_len_ptr() = (uint)(1 + num_caps);
    return unmatched != 0;
}

// Fills a fresh array whose storage was laid out for the shape `shape_id`,
// writing each slot once: its elements, then the named slots in shape order.
// The result is the array the property-by-property path builds, down to the
// flag bits that path leaves set.
fn void regexp_fill_match_result(BuiltinContext* ctx, HObject* arr, uint shape_id, void* re_data,
                                 HString* input_str, int* caps, int num_caps) {
    Heap* heap = ctx.heap;
    arr.gc.packed = regexp_fill_match_elements(heap, arr, input_str, caps, num_caps);
    hobject::PropValue* slots = arr.prop_values();
    TVal tv;
    tv.set_fastint((long)caps[0]);
    slots[0] = (hobject::PropValue)tv;
    tv.set_string_borrowed(input_str);
    heap.init_slot_ref(arr, &slots[1], &tv);
    // `groups` is undefined unless the pattern names a group.
    TVal groups;
    groups.set_undefined();
    if (re_bindings::re_has_group_names(re_data)) {
        HObject*? groups_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try g = groups_raw) {
            regexp_fill_groups(ctx, g, re_data, input_str, caps, num_caps);
            groups.set_object(g);
        }
    }
    heap.init_slot_ref(arr, &slots[2], &groups);
    tv.set_fastint((long)(1 + num_caps));
    slots[3] = (hobject::PropValue)tv;
    arr.prop_count = 4;
    arr.shape_id = shape_id;
    arr.flags.has_nondefault_flags = true;
}

// RegExp.prototype.exec(string), ECMA-262 §15.10.6.2
fn void builtin_regexp_proto_exec(BuiltinContext* ctx) {
    // Step 1-3: the receiver must carry a [[RegExpMatcher]]; unlike the
    // @@-method entry points this one is not reached through RegExpExec, so
    // a plain Object with an `exec` property is not a valid `this` here.
    HObject* obj = regexp_get_this(ctx);
    if (obj == null || (*obj.extra_ptr()).regexp.regexp_data == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "RegExp.prototype.exec called on incompatible receiver");
        return;
    }
    TVal arg;
    arg.set_undefined();
    if (ctx.argc > 0) arg = ctx.regs[ctx.base_reg];
    regexp_builtin_exec(ctx, obj, &arg);
}

// RegExp.prototype.toString(), ECMA-262 §22.2.6.13
fn void builtin_regexp_proto_toString(BuiltinContext* ctx) {
    // Step 1: RequireObjectCoercible(R) - Type(R) must be Object
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "RegExp.prototype.toString called on incompatible receiver");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();

    // Check if this is RegExp.prototype itself or a REGEXP-class object
    bool is_proto = (ctx.heap.regexp_proto != null && obj == ctx.heap.regexp_proto);
    bool is_regexp = (obj.get_class() == hobject::ObjClass.REGEXP && (*obj.extra_ptr()).regexp.regexp_data != null);

    // Get source: for regexp objects use internal slot, for prototype return "(?:)"
    HString* source_str = null;
    if (is_proto) {
        // RegExp.prototype receiver: source is "(?:)"
        source_str = builtin_intern_string(ctx.heap, "(?:)");
    } else if (is_regexp && (*obj.extra_ptr()).prim.primitive_value.is_string() && (*obj.extra_ptr()).prim.primitive_value.get_heapptr() != null) {
        // Regular RegExp object: apply EscapeRegExpPattern to internal source
        HString* phs = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        source_str = regexp_escaped_source(ctx, phs);
        if (source_str == null) return;
    } else {
        // For non-regexp objects or regexp with no source, get via property lookup
        HString* source_key = ctx.heap.str(heap::BuiltinStr.SOURCE);
        TVal? source_opt = builtins_generic_get(obj, source_key, ctx);
        if (ctx.should_throw) return;
        if (try src = source_opt) {
            HString* src_str = builtin_to_string_vm(ctx, &src);
            if (ctx.should_throw) return;
            if (src_str != null) {
                source_str = regexp_escaped_source(ctx, src_str);
                if (source_str == null) return;
            } else {
                source_str = builtin_intern_string(ctx.heap, "(?:)");
            }
        } else {
            source_str = builtin_intern_string(ctx.heap, "(?:)");
        }
    }

    // Get flags: for regexp objects use internal slot, for others via property lookup
    HString* flags_str;
    if (is_proto) {
        // RegExp.prototype receiver: flags is ""
        flags_str = ctx.heap.str(heap::BuiltinStr.EMPTY);
    } else if (is_regexp) {
        // Regular RegExp object: build flags from internal slot
        int jsf = (*obj.extra_ptr()).regexp.flags;
        char[8] buf;
        int pos = 0;
        if ((jsf & 1) != 0) buf[pos++] = 'g';
        if ((jsf & 2) != 0) buf[pos++] = 'i';
        if ((jsf & 4) != 0) buf[pos++] = 'm';
        if ((jsf & 8) != 0) buf[pos++] = 's';
        if ((jsf & 16) != 0) buf[pos++] = 'u';
        if ((jsf & 32) != 0) buf[pos++] = 'y';
        if ((jsf & 64) != 0) buf[pos++] = 'd';
        if ((jsf & 128) != 0) buf[pos++] = 'v';
        flags_str = builtin_intern_string(ctx.heap, buf[:pos]);
    } else {
        // Non-regexp object: get flags via property lookup (ToString(R.flags))
        HString* flags_key = ctx.heap.str(heap::BuiltinStr.FLAGS);
        TVal? flags_opt = builtins_generic_get(obj, flags_key, ctx);
        if (ctx.should_throw) return;
        if (try fl = flags_opt) {
            HString* fl_str = builtin_to_string_vm(ctx, &fl);
            if (ctx.should_throw) return;
            if (fl_str != null) {
                flags_str = fl_str;
            } else {
                flags_str = ctx.heap.str(heap::BuiltinStr.EMPTY);
            }
        } else {
            flags_str = ctx.heap.str(heap::BuiltinStr.EMPTY);
        }
    }

    UnitBuf out;
    out.init(ctx.heap);
    defer out.free();
    out.append_char('/');
    out.append_hstring(source_str);
    out.append_char('/');
    out.append_hstring(flags_str);
    out.finish(ctx);
}

// @@match for a pristine receiver. A global receiver collects the matched
// substrings directly; a non-global one is a single RegExpBuiltinExec.
fn void regexp_match_pristine(BuiltinContext* ctx, HObject* rx, HString* s_hstr) {
    Heap* heap = ctx.heap;
    if (((*rx.extra_ptr()).regexp.flags & 1) == 0) {
        TVal s_tv;
        s_tv.set_string_borrowed(s_hstr);
        regexp_builtin_exec(ctx, rx, &s_tv);
        return;
    }
    growvec::GrowVec{int} spans = { .heap = heap };
    defer spans.free();
    if (!regexp_find_matches(ctx, rx, s_hstr, &spans, 0)) return;
    if (spans.len == 0) { ctx.result_null(); return; }
    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result_null(); return; }
    HObject* arr = arr_raw;
    heap.set_prototype(arr, heap.array_proto);
    ulong count = 0;
    for (usz at = 0; at < spans.len; at += 2) {
        TVal piece;
        piece.set_string_borrowed(heap.str_slice(s_hstr, (uint)spans.items[at], (uint)spans.items[at + 1]));
        regexp_split_push(heap, arr, &count, piece);
    }
    TVal len_tv;
    len_tv.set_fastint((long)count);
    arr.put_prop(heap.str(heap::BuiltinStr.LENGTH), len_tv, hobject::PROP_FLAGS_WEC, heap);
    ctx.result_object(arr);
}

// ============================================================================
// RegExp.prototype[@@match], ECMA-262 §21.2.5.6
// ============================================================================
fn void builtin_regexp_proto_symbol_match(BuiltinContext* ctx) {
    HObject* rx = regexp_get_symbol_this(ctx);
    if (rx == null) return;

    // 3. Let S be ? ToString(string).
    TVal s_tv; s_tv.set_undefined();
    if (ctx.argc > 0) s_tv = ctx.regs[ctx.base_reg];
    HString* s_hstr;
    if (s_tv.is_string() && s_tv.get_heapptr() != null
        && !((HString*)s_tv.get_heapptr()).is_symbol()) {
        s_hstr = (HString*)s_tv.get_heapptr();
    } else {
        s_hstr = builtin_to_string_vm(ctx, &s_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) s_hstr = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }

    if (regexp_is_pristine(ctx.heap, rx) && ((*rx.extra_ptr()).regexp.flags & 32) == 0) {
        regexp_match_pristine(ctx, rx, s_hstr);
        return;
    }

    // 4. Let flags be ? ToString(? Get(rx, "flags")).
    // 5. Parse "g" and "u"/"v" from flags (spec steps 5-6).
    // Reading "flags" once avoids triggering "global"/"unicode" getters (which tests poison).
    HString* flags_key_m = ctx.heap.str(heap::BuiltinStr.FLAGS);
    TVal? flags_opt_m = builtins_generic_get(rx, flags_key_m, ctx);
    if (ctx.should_throw) return;
    TVal flags_tv_m; flags_tv_m.set_undefined();
    if (try fvm = flags_opt_m) { flags_tv_m = fvm; }
    HString* flags_hstr_m = builtin_to_string_vm(ctx, &flags_tv_m);
    if (ctx.should_throw) return;
    if (flags_hstr_m == null) { flags_hstr_m = ctx.heap.str(heap::BuiltinStr.EMPTY); }
    bool global_flag = false;
    bool full_unicode = false;
    for (uint i = 0; i < flags_hstr_m.unit_len(); i++) {
        uint fc = flags_hstr_m.unit_at(i);
        if (fc == 'g') global_flag = true;
        if (fc == 'u' || fc == 'v') full_unicode = true;
    }

    if (!global_flag) {
        // 7.a. Return ? RegExpExec(rx, S).
        // Pass the ToString-coerced string S, per spec, Call(exec, R, «S»)
        // passes S as the arg, not the original input.
        TVal s_hstr_tv; s_hstr_tv.set_string(s_hstr);
        defer ctx.heap.decref_tval(&s_hstr_tv);
        if (!regexp_exec_call(ctx, rx, &s_hstr_tv)) {
            return;
        }
        return;
    }

    // 8. global === true
    // 8.a. Perform ? Set(rx, "lastIndex", 0, true), throws TypeError if non-writable.
    HString* li_key = ctx.heap.str(heap::BuiltinStr.LAST_INDEX);
    TVal zero_tv; zero_tv.set_fastint(0);
    if (!builtins_generic_set(ctx, rx, li_key, zero_tv, "lastIndex")) return;

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result_null(); return; }
    HObject* arr = arr_raw;
    ctx.heap.set_prototype(arr, ctx.heap.array_proto);

    uint arr_idx = 0;

    while (true) {
        // 8.c. Let result be ? RegExpExec(rx, S).
        TVal s_hstr_tv; s_hstr_tv.set_string(s_hstr);
        defer ctx.heap.decref_tval(&s_hstr_tv);
        if (!regexp_exec_call(ctx, rx, &s_hstr_tv)) return;
        TVal result = ctx.result.get();
        if (result.is_null()) break;
        // Skip our internal hstring wrapping when handing off, re_run
        // returns a TVal containing an Array object pointer.
        // `regexp_exec_call` set ctx.result; mirror it locally so we
        // don't re-run the function on the next iteration.

        HObject* match_arr;
        if (result.is_object() && result.get_heapptr() != null) {
            match_arr = (HObject*)result.get_heapptr();
        } else {
            break;
        }

        // 8.e. Let matchStr be ? ToString(? Get(result, "0")).
        HString* zero_key = ctx.heap.int_to_hstring(0);
        TVal? ms_opt = builtins_generic_get(match_arr, zero_key, ctx);
        if (ctx.should_throw) return;
        TVal ms_tv; ms_tv.set_undefined();
        if (try mv = ms_opt) { ms_tv = mv; }
        HString* match_str = builtin_to_string_vm(ctx, &ms_tv);
        if (ctx.should_throw) return;
        if (match_str == null) match_str = ctx.heap.str(heap::BuiltinStr.UNDEFINED);

        // 8.f. Perform ! CreateDataProperty(A, ! ToString(n), matchStr).
        TVal elem; elem.set_string_borrowed(match_str);
        arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC, ctx.heap);
        arr_idx++;

        // 8.g. If matchStr is the empty String, then
        //    i. Let thisIndex be ? ToLength(? Get(rx, "lastIndex")).
        //    ii. Let nextIndex be AdvanceStringIndex(S, thisIndex, fullUnicode).
        //    iii. Perform ? Set(rx, "lastIndex", nextIndex, true).
        if (match_str.unit_len() == 0) {
            // 8.g.i. Let thisIndex be ? ToLength(? Get(rx, "lastIndex")).
            TVal? li_opt = builtins_generic_get(rx, li_key, ctx);
            if (ctx.should_throw) return;
            TVal li_raw; li_raw.set_fastint(0);
            if (try lv = li_opt) { li_raw = lv; }
            double this_d = builtin_to_integer_vm(ctx, &li_raw);
            if (ctx.should_throw) return;
            if (this_d < 0.0) this_d = 0.0;
            long this_index = (long)this_d;
            // AdvanceStringIndex(S, thisIndex, fullUnicode): at or beyond S's
            // length it is just thisIndex + 1.
            long next_index = (ulong)this_index >= (ulong)s_hstr.unit_len()
                ? this_index + 1
                : (long)hstring::advance_string_index(s_hstr, (uint)this_index, full_unicode);
            TVal next_tv; next_tv.set_fastint(next_index);
            // 8.g.iii. Perform ? Set(rx, "lastIndex", nextIndex, true).
            if (!builtins_generic_set(ctx, rx, li_key, next_tv, "lastIndex")) return;
        }
        // continue loop
    }

    if (arr_idx == 0) {
        ctx.result_null();
        return;
    }

    TVal len_tv; len_tv.set_fastint((long)arr_idx);
    HString* len_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
    arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

    ctx.result_object(arr);
}

// @@search for a pristine receiver: the spec saves lastIndex, zeroes it, runs
// one exec and restores it, which leaves lastIndex as it was.
fn void regexp_search_pristine(BuiltinContext* ctx, HObject* rx, HString* s_hstr) {
    int[2] m;
    if (regexp_run(ctx, (*rx.extra_ptr()).regexp.regexp_data, s_hstr, 0, &m, 2) != re_bindings::RE_MATCH) {
        if (ctx.should_throw) return;
        ctx.result_fastint(-1);
        return;
    }
    ctx.result_fastint((long)m[0]);
}

// ============================================================================
// RegExp.prototype[@@search], ECMA-262 §21.2.5.9
// ============================================================================
fn void builtin_regexp_proto_symbol_search(BuiltinContext* ctx) {
    HObject* rx = regexp_get_symbol_this(ctx);
    if (rx == null) return;

    // 3. Let S be ? ToString(string).
    TVal s_tv; s_tv.set_undefined();
    if (ctx.argc > 0) s_tv = ctx.regs[ctx.base_reg];
    HString* s_hstr;
    if (s_tv.is_string() && s_tv.get_heapptr() != null
        && !((HString*)s_tv.get_heapptr()).is_symbol()) {
        s_hstr = (HString*)s_tv.get_heapptr();
    } else {
        s_hstr = builtin_to_string_vm(ctx, &s_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) s_hstr = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }

    if (regexp_is_pristine(ctx.heap, rx)) {
        regexp_search_pristine(ctx, rx, s_hstr);
        return;
    }

    HString* li_key = ctx.heap.str(heap::BuiltinStr.LAST_INDEX);

    // 4. Let previousLastIndex be ? Get(rx, "lastIndex").
    TVal? prev_opt = builtins_generic_get(rx, li_key, ctx);
    if (ctx.should_throw) return;
    TVal previous_last_index; previous_last_index.set_undefined();
    if (try p = prev_opt) { previous_last_index = p; }

    // 5. If SameValue(previousLastIndex, 0) is false, Set(rx, "lastIndex", 0, true).
    TVal zero_tv; zero_tv.set_fastint(0);
    if (!same_value(previous_last_index, zero_tv)) {
        if (!builtins_generic_set(ctx, rx, li_key, zero_tv, "lastIndex")) return;
    }

    // 6. Let result be ? RegExpExec(rx, S).
    TVal s_hstr_tv; s_hstr_tv.set_string(s_hstr);
    defer ctx.heap.decref_tval(&s_hstr_tv);
    if (!regexp_exec_call(ctx, rx, &s_hstr_tv)) return;
    TVal result = ctx.result.get();

    // 7. Let currentLastIndex be ? Get(rx, "lastIndex").
    TVal? cur_opt = builtins_generic_get(rx, li_key, ctx);
    if (ctx.should_throw) return;
    TVal current_last_index; current_last_index.set_undefined();
    if (try c = cur_opt) { current_last_index = c; }

    // 8. If SameValue(currentLastIndex, previousLastIndex) is false, restore it.
    if (!same_value(current_last_index, previous_last_index)) {
        if (!builtins_generic_set(ctx, rx, li_key, previous_last_index, "lastIndex")) return;
    }

    if (result.is_null()) {
        ctx.result_fastint(-1);
        return;
    }
    if (!result.is_object() || result.get_heapptr() == null) {
        ctx.result_fastint(-1);
        return;
    }

    // 14. Return Get(result, "index").
    HObject* match_arr = (HObject*)result.get_heapptr();
    HString* index_key = ctx.heap.str(heap::BuiltinStr.INDEX);
    TVal? idx_opt = builtins_generic_get(match_arr, index_key, ctx);
    if (ctx.should_throw) return;
    if (catch err = idx_opt) {
        ctx.result_fastint(-1);
        return;
    }
    TVal idx_tv = idx_opt;
    if (idx_tv.is_fastint()) {
        ctx.result_fastint(idx_tv.get_fastint());
        return;
    }
    if (idx_tv.is_number()) {
        ctx.result_number(idx_tv.get_number());
        return;
    }
    ctx.result_fastint(0);
}

// ============================================================================
// Runs @@replace for a pristine receiver whose pattern has no named groups.
// False leaves everything untouched for the generic path. `known_pristine`
// says the caller has checked the receiver with no script run since.
fn bool regexp_replace_try_pristine(BuiltinContext* ctx, HObject* rx, HString* s_hstr,
                                    bool replace_is_fn, TVal replace_val, HString* replace_hs,
                                    bool known_pristine = false) {
    if (!known_pristine && !regexp_is_pristine(ctx.heap, rx)) return false;
    if (!replace_is_fn) {
        HString* out = regexp_replace_direct(ctx.heap, s_hstr, rx, replace_hs, false);
        if (out != null) {
            ctx.result_string(out);
            return true;
        }
    }
    void* re_data = (*rx.extra_ptr()).regexp.regexp_data;
    int jsf = (*rx.extra_ptr()).regexp.flags;
    if (re_bindings::re_get_groupnames(re_data) != null || ((jsf & 32) != 0 && (jsf & 1) == 0)) return false;
    regexp_replace_pristine(ctx, rx, s_hstr, replace_is_fn, replace_val, replace_hs);
    return true;
}

// String.prototype.replace(rx, replaceValue) with a pristine `rx`: the
// property read of rx[@@replace] and the call through the VM are skipped.
// `regexp_proto_pristine` covers @@replace itself, and `rx` owns nothing but
// lastIndex, so that read can only find the intrinsic. Returns false, having
// run no script, when the generic protocol must run instead.
fn bool regexp_string_replace_fast(BuiltinContext* ctx, HObject* rx, HString* s_hstr) {
    Heap* heap = ctx.heap;
    if (rx.get_class() != hobject::ObjClass.REGEXP || !regexp_is_pristine(heap, rx)) return false;
    TVal replace_val;
    replace_val.set_undefined();
    bool replace_is_fn = false;
    if (ctx.argc > 1) {
        replace_val = ctx.regs[ctx.base_reg + 1];
        replace_is_fn = replace_val.is_lightfunc() ||
            (replace_val.is_object() && replace_val.get_heapptr() != null &&
             ((HObject*)replace_val.get_heapptr()).is_callable());
        // ToString of an object can run script that changes the receiver.
        if (!replace_is_fn && replace_val.is_object()) return false;
    }
    HString* replace_hs = null;
    if (!replace_is_fn) {
        replace_hs = ctx.argc > 1 ? builtin_to_string_vm(ctx, &replace_val) : heap.str(heap::BuiltinStr.UNDEFINED);
        if (ctx.should_throw) return true;
        if (replace_hs == null) replace_hs = heap.str(heap::BuiltinStr.UNDEFINED);
    }
    // ToString of a primitive runs no script, so the receiver is as checked.
    return regexp_replace_try_pristine(ctx, rx, s_hstr, replace_is_fn, replace_val, replace_hs, true);
}

// RegExp.prototype[@@replace], ECMA-262 §22.2.5.8
// ============================================================================

// A range of code units of a string. A null string stands for an undefined
// capture.
struct StrSlice {
    HString* str;
    uint     from;
    uint     to;
}

// The whole of `s`, or an undefined capture when `s` is null.
fn StrSlice slice_of(HString* s) @inline {
    return s == null ? (StrSlice){} : (StrSlice){ .str = s, .from = 0, .to = s.unit_len() };
}

fn bool UnitBuf.append_slice(&self, StrSlice slice) {
    return slice.str == null || self.append_hstring_range(slice.str, slice.from, slice.to);
}

// GetSubstitution (ECMA-262 Table 58) over code units. An undefined capture is a
// slice with a null string. `namedCaptures` is a TVal (already ToObject'd when
// not undefined). Appends the substituted string to `out`; an abrupt completion
// leaves ctx.should_throw set.
fn void rr_get_substitution(
    BuiltinContext* ctx,
    UnitBuf* out,
    StrSlice matched,        // ToString(result[0])
    HString* str,            // full input string
    uint position,           // unit offset of match start
    uint match_end,          // unit offset of match end
    StrSlice[] captures,
    TVal named_captures_tv,  // groups value (object or any type after ToObject)
    bool have_named_captures,// true when groups !== undefined
    HString* rep             // replacement template
) {
    uint num_caps = (uint)captures.len;
    uint rep_len = rep.unit_len();
    uint i = 0;
    while (i < rep_len && !out.failed) {
        uint lit = i;
        while (lit < rep_len && rep.unit_at(lit) != '$') lit++;
        if (lit > i) {
            out.append_hstring_range(rep, i, lit);
            i = lit;
            continue;
        }
        uint next = i + 1 < rep_len ? rep.unit_at(i + 1) : 0;
        if (next == '$') {
            out.append_char('$');
            i += 2;
            continue;
        }
        if (next == '&') {
            out.append_slice(matched);
            i += 2;
            continue;
        }
        if (next == '`') {
            out.append_hstring_range(str, 0, position);
            i += 2;
            continue;
        }
        if (next == '\'') {
            out.append_hstring_range(str, match_end, str.unit_len());
            i += 2;
            continue;
        }
        if (next >= '0' && next <= '9') {
            // Try 2-digit index first; fall back to 1-digit.
            uint idx1 = next - '0';
            bool use2 = false;
            uint idx2 = 0;
            if (i + 2 < rep_len && rep.unit_at(i + 2) >= '0' && rep.unit_at(i + 2) <= '9') {
                idx2 = idx1 * 10 + (rep.unit_at(i + 2) - '0');
                if (idx2 >= 1 && idx2 <= num_caps) use2 = true;
            }
            uint idx = use2 ? idx2 : idx1;
            uint consumed = use2 ? 2 : 1;
            if (idx >= 1 && idx <= num_caps) {
                out.append_slice(captures[idx - 1]);
                i += 1 + consumed;
                continue;
            }
            // Out of range → emit '$' literally; re-process next char.
            out.append_char('$');
            i++;
            continue;
        }
        if (next == '<') {
            if (!have_named_captures) {
                out.append_latin1("$<");
                i += 2;
                continue;
            }
            uint name_start = i + 2;
            uint name_end = name_start;
            while (name_end < rep_len && rep.unit_at(name_end) != '>') name_end++;
            if (name_end >= rep_len) {
                // No closing '>' → emit "$<" literally.
                out.append_latin1("$<");
                i += 2;
                continue;
            }
            if (name_end == name_start) {
                // $<> empty group name → empty substitution.
                i = name_end + 1;
                continue;
            }
            HString* gname_hs = ctx.heap.str_slice(rep, name_start, name_end);
            // Get(namedCaptures, groupName).
            if (named_captures_tv.is_object() && named_captures_tv.get_heapptr() != null) {
                HObject* nc_obj = (HObject*)named_captures_tv.get_heapptr();
                TVal? cap_opt = builtins_generic_get(nc_obj, gname_hs, ctx);
                if (ctx.should_throw) return;
                if (try cap_tv = cap_opt) {
                    if (!cap_tv.is_undefined()) {
                        HString* cs = builtin_to_string_vm(ctx, &cap_tv);
                        if (ctx.should_throw) return;
                        if (cs != null) out.append_hstring(cs);
                    }
                    // undefined capture → empty substitution
                }
            }
            i = name_end + 1;
            continue;
        }
        // Unknown $ sequence → emit '$' literally.
        out.append_char('$');
        i++;
    }
}

// Matches collected by the first pass of the generic @@replace. The match
// objects stay alive through the native frame's temproot pins.
alias RrMatches = growvec::GrowVec{TVal};

// ----------------------------------------------------------------------------
// Pristine RegExps
//
// A RegExp that still has its original prototype and nothing but its own
// `lastIndex` behaves exactly as the intrinsic algorithm says: every Get the
// generic @@replace performs (`flags`, the flag getters, `exec`) resolves to
// an intrinsic that reads the compiled matcher. Such a receiver runs the
// match loop directly, with no property reads, getter calls or match arrays.
// ----------------------------------------------------------------------------

// The guarded properties of RegExp.prototype: `exec`, `constructor` and
// `test` are data properties holding builtin function objects, `[Symbol.match]`
// is a data property holding a lightfunc, and the rest are accessors whose
// getter is a builtin. Everything the generic @@replace and @@split read about
// a receiver is on this list, as is `[Symbol.match]`, which `new RegExp(rx,
// flags)` reads through IsRegExp, and `test`, which RETEST calls.
const usz REGEXP_GUARD_SLOTS = 16;
const usz REGEXP_GUARD_MATCH = 2;
// Slots 3..11 are the accessors. `test` follows them; it is a data property
// like `exec`, and so are the @@replace, @@split and @@search entry points,
// which String.prototype.replace, split and search call after one property read.
const usz REGEXP_GUARD_FIRST_GETTER = 3;
const usz REGEXP_GUARD_TEST = 12;
const usz REGEXP_GUARD_REPLACE = 13;
const usz REGEXP_GUARD_SPLIT = 14;
const usz REGEXP_GUARD_SEARCH = 15;
const String[REGEXP_GUARD_SLOTS] REGEXP_GUARD_KEYS = {
    "exec", "constructor", "",
    "flags", "hasIndices", "global", "ignoreCase", "multiline", "dotAll",
    "unicode", "unicodeSets", "sticky", "test", "", "", "",
};
const int[REGEXP_GUARD_SLOTS] REGEXP_GUARD_FNS = {
    Builtin.REGEXP_PROTO_EXEC.ordinal,
    Builtin.REGEXP.ordinal,
    Builtin.REGEXP_PROTO_SYMBOL_MATCH.ordinal,
    Builtin.REGEXP_PROTO_GET_FLAGS.ordinal,
    Builtin.REGEXP_PROTO_GET_HASINDICES.ordinal,
    Builtin.REGEXP_PROTO_GET_GLOBAL.ordinal,
    Builtin.REGEXP_PROTO_GET_IGNORECASE.ordinal,
    Builtin.REGEXP_PROTO_GET_MULTILINE.ordinal,
    Builtin.REGEXP_PROTO_GET_DOTALL.ordinal,
    Builtin.REGEXP_PROTO_GET_UNICODE.ordinal,
    Builtin.REGEXP_PROTO_GET_UNICODESETS.ordinal,
    Builtin.REGEXP_PROTO_GET_STICKY.ordinal,
    Builtin.REGEXP_PROTO_TEST.ordinal,
    Builtin.REGEXP_PROTO_SYMBOL_REPLACE.ordinal,
    Builtin.REGEXP_PROTO_SYMBOL_SPLIT.ordinal,
    Builtin.REGEXP_PROTO_SYMBOL_SEARCH.ordinal,
};

fn bool regexp_guard_is_getter(usz i) @inline {
    return i >= REGEXP_GUARD_FIRST_GETTER && i < REGEXP_GUARD_TEST;
}

fn HString* regexp_guard_key(Heap* heap, usz i) {
    switch (i) {
        case REGEXP_GUARD_MATCH: return ensure_match_symbol(heap);
        case REGEXP_GUARD_REPLACE: return ensure_replace_symbol(heap);
        case REGEXP_GUARD_SPLIT: return ensure_split_symbol(heap);
        case REGEXP_GUARD_SEARCH: return ensure_search_symbol(heap);
        default: return builtin_intern_string(heap, REGEXP_GUARD_KEYS[i]);
    }
}

// Locates the guarded properties on RegExp.prototype. Fails when one is
// missing or has changed kind.
fn bool regexp_guard_locate(Heap* heap) {
    HObject* proto = heap.regexp_proto;
    for (usz i = 0; i < REGEXP_GUARD_SLOTS; i++) {
        HString* key = regexp_guard_key(heap, i);
        if (key == null) return false;
        int idx = proto.find_prop_idx((void*)key, heap);
        if (idx < 0 || proto.get_prop_flags((uint)idx, heap).is_accessor != regexp_guard_is_getter(i)) return false;
        heap.regexp_guard.slots[i] = (ushort)idx;
    }
    return true;
}

// True when `v` is the builtin function `builtin`, as an object or a lightfunc.
fn bool regexp_is_builtin(TVal v, int builtin) @inline {
    if (v.is_lightfunc()) return (int)(usz)v.get_heapptr() == builtin;
    if (!v.is_object()) return false;
    HObject* callee = (HObject*)v.get_heapptr();
    return callee.is_callable() && callee.callable_kind() == hobject::CallableKind.BUILTIN_FN
        && (*callee.extra_ptr()).func.builtin_fn_index == builtin;
}

// True while every guarded property of RegExp.prototype is still its
// intrinsic: one load while the guard is armed.
fn bool regexp_proto_pristine(Heap* heap) @inline {
    return heap.regexp_pristine || regexp_guard_arm(heap);
}

// Verifies every guarded property of RegExp.prototype and, when all hold their
// intrinsics, sets Heap.regexp_pristine until the next write to the prototype or
// to one of its guarded accessor pairs. Those objects are marked watched: the
// write barrier, flag edits and deletes on a watched object clear the word, and
// no store inline cache is filled for one. The prototype is watched from its
// creation (register_regexp_constructor), so no cache filled earlier describes
// it. The guarded builtins are promoted to objects, so replacing one, with any
// value, is a store of or over a heap value and passes the barrier.
fn bool regexp_guard_arm(Heap* heap) @noinline {
    HObject* proto = heap.regexp_proto;
    if (!regexp_guard_locate(heap)) return false;
    PropValue* values = proto.prop_values();
    for (usz i = 0; i < REGEXP_GUARD_SLOTS; i++) {
        TVal v = values[heap.regexp_guard.slots[i]].get();
        if (regexp_guard_is_getter(i)) v = hobject::hobject_access_getter(v);
        if (!regexp_is_builtin(v, REGEXP_GUARD_FNS[i])) return false;
    }
    for (usz i = 0; i < REGEXP_GUARD_SLOTS; i++) {
        PropValue* slot = &values[heap.regexp_guard.slots[i]];
        TVal v = slot.get();
        if (regexp_guard_is_getter(i)) {
            ((HObject*)v.get_heapptr()).gc.watched = true;
        } else if (v.is_lightfunc()) {
            if (!promote_lightfunc_tval(heap, &v)) return false;
            heap.store_slot_ref(proto, slot, &v);
        }
    }
    heap.regexp_pristine = true;
    return true;
}

// The species constructor of a pristine receiver is %RegExp% itself: its
// `[Symbol.species]` getter, the only property SpeciesConstructor reads beyond
// the guarded `constructor`, is still the intrinsic.
fn bool regexp_species_pristine(Heap* heap) {
    HObject* proto = heap.regexp_proto;
    HObject* ctor = (HObject*)proto.prop_values()[heap.regexp_guard.slots[1]].get().get_heapptr();
    int idx = ctor.find_prop_idx((void*)ensure_species_symbol(heap), heap);
    return idx >= 0 && ctor.get_prop_flags((uint)idx, heap).is_accessor
        && regexp_is_builtin(hobject::hobject_access_getter(ctor.prop_values()[idx].get()),
                             Builtin.REGEXP_SPECIES_GETTER.ordinal);
}

// `rx` is a live RegExp that inherits the intrinsic prototype, owns only a
// writable integer `lastIndex`, and sees an unmodified RegExp.prototype.
fn bool regexp_is_pristine(Heap* heap, HObject* rx) {
    if (rx.get_class() != hobject::ObjClass.REGEXP || rx.is_proxy()
        || rx.prototype != heap.regexp_proto || rx.prop_count != 1
        || (*rx.extra_ptr()).regexp.regexp_data == null) return false;
    hobject::PropFlags lf = rx.get_prop_flags(0, heap);
    return !lf.is_accessor && lf.writable && rx.prop_values()[0].get().is_fastint()
        && regexp_proto_pristine(heap);
}

// The matches a pristine receiver produces for `s_hstr`, as the exec loop of
// @@replace and @@match would find them with no script able to run between
// them. `spans` receives, per match, [start, end] unit offsets followed by a
// start/end pair for each of the first `ncap` capture groups (-1 for a group
// that did not participate). A global receiver is left with lastIndex 0, which
// is where its final failing exec puts it; a non-global one is not touched.
// Returns false, with a RangeError pending, when memory runs out.
fn bool regexp_find_matches(BuiltinContext* ctx, HObject* rx, HString* s_hstr,
                            growvec::GrowVec{int}* spans, usz ncap) {
    Heap* heap = ctx.heap;
    void* re_data = (*rx.extra_ptr()).regexp.regexp_data;
    int jsf = (*rx.extra_ptr()).regexp.flags;
    bool global = (jsf & 1) != 0;
    bool full_unicode = (jsf & (16 | 128)) != 0;
    int input_len = (int)s_hstr.unit_len();

    int[32] bounds_storage;
    growvec::GrowVec{int} bounds = { .heap = heap };
    bounds.use_storage(&bounds_storage, 32);
    defer bounds.free();
    if (!bounds.reserve(2 * ncap + 2)) {
        builtin_throw(ctx, heap.range_err_proto, "Invalid string length");
        return false;
    }
    int* caps = bounds.items;
    int pos = 0;
    char[] lit = re_bindings::re_whole_literal(re_data);
    if (lit.len > 0) {
        // Each match is the next occurrence of the literal, which is never empty.
        while (pos <= input_len) {
            int at = regexp_find_literal(s_hstr, lit, (uint)pos);
            if (at < 0) break;
            pos = at + (int)lit.len;
            if (!spans.push(at) || !spans.push(pos)) {
                builtin_throw(ctx, heap.range_err_proto, "Invalid string length");
                return false;
            }
            if (!global) break;
        }
    }
    while (lit.len == 0 && pos <= input_len) {
        if (regexp_run(ctx, re_data, s_hstr, pos, caps, (int)(2 * ncap + 2)) != re_bindings::RE_MATCH) {
            if (ctx.should_throw) return false;
            break;
        }
        int m_start = caps[0];
        int m_end = caps[1];
        bool ok = spans.push(m_start) && spans.push(m_end);
        for (usz i = 1; i <= ncap && ok; i++) {
            bool matched_cap = caps[2 * i] >= 0 && caps[2 * i + 1] >= 0;
            ok = spans.push(matched_cap ? caps[2 * i] : -1) && spans.push(matched_cap ? caps[2 * i + 1] : -1);
        }
        if (!ok) {
            builtin_throw(ctx, heap.range_err_proto, "Invalid string length");
            return false;
        }
        if (!global || m_end >= input_len && m_end == m_start) break;
        pos = m_end == m_start
            ? (int)hstring::advance_string_index(s_hstr, (uint)m_end, full_unicode)
            : m_end;
    }
    if (global) {
        TVal zero;
        zero.set_fastint(0);
        regexp_fast_last_index_write(ctx, rx, heap.str(heap::BuiltinStr.LAST_INDEX), &zero);
    }
    return true;
}

// One piece of a replacement template (GetSubstitution): template units
// [a, b), or what a `$` reference stands for in each match.
struct ReplacePiece {
    PieceKind kind;
    // TEXT: the template range. GROUP: the group in a, 0 for the match. NAMED:
    // in a, a bit per group of that name.
    uint a;
    uint b;
}

enum PieceKind : char {
    TEXT,
    GROUP,
    NAMED,
    BEFORE,
    AFTER,
}

// The most pieces a template may have for regexp_replace_direct.
const uint REPLACE_PIECES_MAX = 32;

// Whether the units of `str` in [from, to) need a wide result.
fn bool regexp_range_wide(HString* str, uint from, uint to) @inline {
    if (!str.is_wide() || from >= to) return false;
    return !hstring::fits_latin1({ .ptr = str.data_ptr() + (usz)from * 2, .len = to - from, .wide = true });
}

// Whether `rep` holds a `$`, remembered on the string after the first look.
fn bool regexp_has_dollar(HString* rep) @inline {
    if (rep.flags.dollar_known) return rep.flags.has_dollar;
    bool found = rep.is_wide() ? regexp_find_literal(rep, "$", 0) >= 0 : hstring::find_bytes(rep.latin1(), "$") >= 0;
    rep.flags.has_dollar = found;
    rep.flags.dollar_known = true;
    return found;
}

// Whether the UTF-8 group name `name` spells units [from, to) of `rep`.
fn bool regexp_name_is(char[] name, HString* rep, uint from, uint to) {
    uint at = from;
    for (usz i = 0; i < name.len;) {
        uint width = hstring::utf8_seq_len(name[i]);
        if (i + width > name.len) return false;
        uint cp = width == 1 ? (uint)name[i] : (uint)name[i] & (0xFFu >> (width + 1));
        for (uint k = 1; k < width; k++) cp = (cp << 6) | ((uint)name[i + k] & 0x3F);
        i += width;
        if (cp >= 0x10000) {
            if (at + 2 > to) return false;
            cp -= 0x10000;
            if (rep.unit_at(at) != 0xD800 + (cp >> 10) || rep.unit_at(at + 1) != 0xDC00 + (cp & 0x3FF)) return false;
            at += 2;
        } else {
            if (at >= to || rep.unit_at(at) != cp) return false;
            at++;
        }
    }
    return at == to;
}

// A bit per group of `re_data`, below `groups`, whose name is units [from, to)
// of `rep`.
fn uint regexp_named_mask(void* re_data, int groups, HString* rep, uint from, uint to) {
    char* p = re_bindings::re_get_groupnames(re_data);
    uint mask = 0;
    for (int g = 1; g < groups && p != null; g++) {
        usz len = (usz)((ZString)p).len();
        if (len > 0 && regexp_name_is(p[:len], rep, from, to)) mask |= 1u << g;
        // Each entry is the name, its terminator and a scope byte.
        p += (sz)(len + 2);
    }
    return mask;
}

// GetSubstitution's template `rep` as pieces, for a pattern of `groups` groups
// (the match included) that names a group when `named`: the piece count, or -1
// when `out` cannot hold them.
fn int regexp_parse_template(HString* rep, void* re_data, int groups, bool named, ReplacePiece[] out) {
    uint n = 0;
    uint len = rep.length;
    uint text = 0;
    uint i = 0;
    while (i + 1 < len) {
        if (rep.unit_at(i) != '$') {
            i++;
            continue;
        }
        uint c = rep.unit_at(i + 1);
        ReplacePiece piece;
        uint next = i + 2;
        switch {
            case c == '$':
                // The second `$` opens the text that follows.
                piece = { .kind = TEXT, .a = i + 1, .b = i + 1 };
            case c == '&':
                piece = { .kind = GROUP, .a = 0 };
            case c == '`':
                piece = { .kind = BEFORE };
            case c == '\'':
                piece = { .kind = AFTER };
            case c >= '0' && c <= '9':
                uint index = c - '0';
                if (i + 2 < len && rep.unit_at(i + 2) >= '0' && rep.unit_at(i + 2) <= '9') {
                    uint two = index * 10 + rep.unit_at(i + 2) - '0';
                    if (two < (uint)groups) {
                        index = two;
                        next = i + 3;
                    }
                }
                if (index < 1 || index >= (uint)groups) {
                    i++;
                    continue;
                }
                piece = { .kind = GROUP, .a = index };
            case c == '<' && named:
                uint close = i + 2;
                while (close < len && rep.unit_at(close) != '>') close++;
                if (close >= len) {
                    i++;
                    continue;
                }
                piece = { .kind = NAMED, .a = regexp_named_mask(re_data, groups, rep, i + 2, close) };
                next = close + 1;
            default:
                i++;
                continue;
        }
        if ((usz)n + 3 > out.len) return -1;
        if (text < i) out[n++] = { .kind = TEXT, .a = text, .b = i };
        if (piece.kind == TEXT) {
            text = i + 1;
        } else {
            out[n++] = piece;
            text = next;
        }
        i = next;
    }
    if (text < len) out[n++] = { .kind = TEXT, .a = text, .b = len };
    return (int)n;
}

// The subject units a reference piece stands for in the match whose group
// bounds `m` holds (-1 for a group that did not participate), into *from and
// *to; an empty range for a group that did not.
fn void regexp_piece_range(ReplacePiece* p, int* m, uint len, uint* from, uint* to) @inline {
    int g = -1;
    switch (p.kind) {
        case GROUP:
            g = (int)p.a;
        case NAMED:
            for (int k = 1; k < 32; k++) {
                if ((p.a & (1u << k)) != 0 && m[2 * k] >= 0) {
                    g = k;
                    break;
                }
            }
        case BEFORE:
            *from = 0;
            *to = (uint)m[0];
            return;
        case AFTER:
            *from = (uint)m[1];
            *to = len;
            return;
        case TEXT:
            break;
    }
    if (g < 0 || m[2 * g] < 0 || m[2 * g + 1] < 0) {
        *from = 0;
        *to = 0;
        return;
    }
    *from = (uint)m[2 * g];
    *to = (uint)m[2 * g + 1];
}

// Units [from, to) of `src` stored at `dest`, a result of width `wide`; past
// them returned. A wide range copied into a narrow result fits Latin-1.
fn char* regexp_put(char* dest, bool wide, HString* src, uint from, uint to) @inline {
    if (from >= to) return dest;
    uint n = to - from;
    if (!src.is_wide()) {
        hstring::copy_units(dest, wide, hstring::narrow_units(src.data_ptr()[from:n]));
    } else if (wide) {
        mem::copy(dest, src.data_ptr() + (usz)from * 2, (usz)n * 2);
    } else {
        ushort* units = (ushort*)src.data_ptr() + from;
        for (uint k = 0; k < n; k++) dest[k] = (char)units[k];
    }
    return dest + ((usz)n << (wide ? 1 : 0));
}

// The longest result, in bytes, regexp_replace_direct interns.
const usz REPLACE_INTERN_MAX = 64;

// String.prototype.replace, or replaceAll when `all`, on `s` with the plain
// RegExp `rx` and the replacement string `rep`: the result @@replace computes,
// without a builtin frame. The match bounds are found first, then one string of
// the exact size is filled, the template's `$` references expanded; with no
// match the result is `s`. Null, with nothing done, when the generic path must
// run: another receiver, a sticky non-global pattern, a non-global replaceAll
// (which throws), more groups than the stack buffer, a template of too many
// pieces, an interrupted run or a result past the length cap.
fn HString* regexp_replace_direct(Heap* heap, HString* s, HObject* rx, HString* rep, bool all) {
    if (!regexp_plain(heap, rx) || rx.prototype != heap.regexp_proto || !regexp_proto_pristine(heap)) return null;
    void* re_data = (*rx.extra_ptr()).regexp.regexp_data;
    int jsf = (*rx.extra_ptr()).regexp.flags;
    bool global = (jsf & 1) != 0;
    if ((all || (jsf & 32) != 0) && !global) return null;
    int groups = re_bindings::re_captures(re_data);
    if (groups > REGEXP_SMALL_GROUPS) return null;
    ReplacePiece[REPLACE_PIECES_MAX] piece_buf @noinit;
    ReplacePiece[] pieces;
    // Per match, the bounds of every group when a piece reads one, else the match's.
    uint stride = 2;
    if (regexp_has_dollar(rep)) {
        int count = regexp_parse_template(rep, re_data, groups, re_bindings::re_has_group_names(re_data), &piece_buf);
        if (count < 0) return null;
        pieces = piece_buf[:count];
        stride = 2 * (uint)groups;
    } else {
        piece_buf[0] = { .kind = TEXT, .a = 0, .b = rep.length };
        pieces = piece_buf[:1];
    }
    int[2 * REGEXP_SMALL_GROUPS] caps @noinit;
    int[64] span_buf @noinit;
    growvec::GrowVec{int} spans = { .heap = heap };
    spans.use_storage(&span_buf, span_buf.len);
    defer spans.free();
    re_bindings::ReInterrupt interrupt = { &heap::regexp_interrupt, heap };
    char[] lit = stride == 2 ? re_bindings::re_whole_literal(re_data) : {};
    bool unicode = (jsf & (16 | 128)) != 0;
    uint len = s.unit_len();
    uint pos = 0;
    while (pos <= len) {
        if (lit.len > 0) {
            int at = regexp_find_literal(s, lit, pos);
            if (at < 0) break;
            caps[0] = at;
            caps[1] = at + (int)lit.len;
        } else {
            int ret = re_bindings::re_run_direct(re_data, s.data_ptr(), len, s.is_wide(), pos, &caps, caps.len, &interrupt);
            if (heap.uncatchable_throw || ret < 0) return null;
            if (ret != re_bindings::RE_MATCH) break;
        }
        for (uint k = 0; k < stride; k++) {
            if (!spans.push(caps[k])) return null;
        }
        if (!global) break;
        uint end = (uint)caps[1];
        pos = end == (uint)caps[0] ? hstring::advance_string_index(s, end, unicode) : end;
    }
    if (global) {
        TVal zero;
        zero.set_fastint(0);
        rx.prop_values()[0] = (hobject::PropValue)zero;
    }
    if (spans.len == 0) return s;
    // The size and width of the result.
    ulong total = 0;
    bool wide = false;
    uint last = 0;
    foreach (&p : pieces) {
        if (p.kind == TEXT) wide |= regexp_range_wide(rep, p.a, p.b);
    }
    for (usz at = 0; at < spans.len; at += stride) {
        int* m = &spans.items[at];
        total += (ulong)((uint)m[0] - last);
        wide |= regexp_range_wide(s, last, (uint)m[0]);
        foreach (&p : pieces) {
            uint from;
            uint to;
            if (p.kind == TEXT) {
                total += (ulong)(p.b - p.a);
                continue;
            }
            regexp_piece_range(p, m, len, &from, &to);
            total += (ulong)(to - from);
            wide |= regexp_range_wide(s, from, to);
        }
        last = (uint)m[1];
    }
    total += (ulong)(len - last);
    wide |= regexp_range_wide(s, last, len);
    if (total == 0) return heap.str(heap::BuiltinStr.EMPTY);
    if (hstring::length_exceeds_max(total)) return null;
    // A short result is interned, so a replace that repeats finds its string.
    char[REPLACE_INTERN_MAX] short_buf @noinit;
    HString* out = null;
    char* dest = &short_buf;
    bool interned = (total << (wide ? 1 : 0)) <= REPLACE_INTERN_MAX;
    if (!interned) {
        out = hstring::hstring_alloc_storage(heap, (uint)total, wide, hstring::HASH_DEFERRED, (uint)total) ?? null;
        if (out == null) return null;
        dest = out.data_ptr();
    }
    last = 0;
    for (usz at = 0; at < spans.len; at += stride) {
        int* m = &spans.items[at];
        dest = regexp_put(dest, wide, s, last, (uint)m[0]);
        foreach (&p : pieces) {
            if (p.kind == TEXT) {
                dest = regexp_put(dest, wide, rep, p.a, p.b);
                continue;
            }
            uint from;
            uint to;
            regexp_piece_range(p, m, len, &from, &to);
            dest = regexp_put(dest, wide, s, from, to);
        }
        last = (uint)m[1];
    }
    regexp_put(dest, wide, s, last, len);
    if (interned) return heap.str_intern_units({ .ptr = &short_buf, .len = (uint)total, .wide = wide });
    out.finish_data();
    heap.large_string_register(out);
    return out;
}

// The first occurrence of the ASCII `lit` in `s` at or after `from`, or -1.
fn int regexp_find_literal(HString* s, char[] lit, uint from) {
    if (!s.is_wide()) return hstring::find_bytes(s.latin1(), lit, from);
    ushort* data = (ushort*)s.data_ptr();
    for (uint i = from; i + lit.len <= s.length; i++) {
        usz k = 0;
        while (k < lit.len && data[i + k] == lit[k]) k++;
        if (k == lit.len) return (int)i;
    }
    return -1;
}

// @@replace for a pristine receiver whose pattern has no named groups. The
// matches are all found before any replacer callback runs, as in the spec.
fn void regexp_replace_pristine(BuiltinContext* ctx, HObject* rx, HString* s_hstr,
                                bool replace_is_fn, TVal replace_val, HString* replace_hs) {
    Heap* heap = ctx.heap;
    void* re_data = (*rx.extra_ptr()).regexp.regexp_data;
    uint input_len = s_hstr.unit_len();
    usz ncap = (usz)(re_bindings::re_get_capture_count(re_data) - 1);
    usz stride = 2 + 2 * ncap;

    int[48] spans_storage;
    growvec::GrowVec{int} spans = { .heap = heap };
    spans.use_storage(&spans_storage, 48);
    defer spans.free();
    if (!regexp_find_matches(ctx, rx, s_hstr, &spans, ncap)) return;
    // No match leaves the input as the result; there is nothing to rebuild.
    if (spans.len == 0) {
        ctx.result_string(s_hstr);
        return;
    }

    UnitBuf out;
    out.init(heap);
    defer out.free();
    uint last_end = 0;
    growvec::GrowVec{StrSlice} slices = { .heap = heap };
    growvec::GrowVec{TVal} args = { .heap = heap };
    defer slices.free();
    defer args.free();
    if (!slices.reserve(ncap) || (replace_is_fn && !args.reserve(ncap + 3))) {
        builtin_throw(ctx, heap.range_err_proto, "Invalid string length");
        return;
    }
    StrSlice[] cap_slices = slices.items[:ncap];
    // A template without `$` is its own substitution.
    bool plain = !replace_is_fn && !replace_hs.is_wide() && hstring::find_bytes(replace_hs.latin1(), "$") < 0;
    for (usz at = 0; at < spans.len; at += stride) {
        uint m_start = (uint)spans.items[at];
        uint m_end = (uint)spans.items[at + 1];
        out.append_hstring_range(s_hstr, last_end, m_start);
        for (usz i = 0; i < ncap; i++) {
            int cs = spans.items[at + 2 + 2 * i];
            int ce = spans.items[at + 3 + 2 * i];
            cap_slices[i] = cs < 0 ? (StrSlice){} : (StrSlice){ s_hstr, (uint)cs, (uint)ce };
        }
        if (replace_is_fn) {
            TVal* argv = args.items;
            usz argc = 0;
            argv[argc++].set_string_borrowed(heap.str_slice(s_hstr, m_start, m_end));
            for (usz i = 0; i < ncap; i++) {
                if (cap_slices[i].str == null) {
                    argv[argc++].set_undefined();
                } else {
                    argv[argc++].set_string_borrowed(heap.str_slice(s_hstr, cap_slices[i].from, cap_slices[i].to));
                }
            }
            argv[argc++].set_fastint((long)m_start);
            argv[argc++].set_string_borrowed(s_hstr);
            TVal undef_this; undef_this.set_undefined();
            TVal res = heap.call_fn(ctx.vm, replace_val, argv, (uint)argc, undef_this);
            if (heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = heap.error_value;
                heap.has_error = false;
                return;
            }
            HString* rep = builtin_to_string_vm(ctx, &res);
            if (ctx.should_throw) return;
            if (rep == null) { out.append_latin1("undefined"); } else { out.append_hstring(rep); }
        } else if (plain) {
            out.append_hstring(replace_hs);
        } else {
            TVal no_groups; no_groups.set_undefined();
            rr_get_substitution(ctx, &out, { s_hstr, m_start, m_end }, s_hstr, m_start, m_end,
                cap_slices, no_groups, false, replace_hs);
            if (ctx.should_throw) return;
        }
        last_end = m_end;
    }
    out.append_hstring_range(s_hstr, last_end, input_len);
    out.finish(ctx);
}

// RegExp.prototype[@@replace], ECMA-262 §22.2.5.8
fn void builtin_regexp_proto_symbol_replace(BuiltinContext* ctx) {
    // Step 1-2: rx must be Object.
    HObject* rx = regexp_get_symbol_this(ctx);
    if (rx == null) return;

    Heap* heap = ctx.heap;

    // Step 3: S = ? ToString(string).
    HString* s_hstr;
    if (ctx.argc > 0) {
        if (ctx.regs[ctx.base_reg].is_string()) {
            s_hstr = (HString*)ctx.regs[ctx.base_reg].get_heapptr();
        } else {
            s_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
            if (ctx.should_throw) return;
        }
    } else {
        s_hstr = heap.str(heap::BuiltinStr.UNDEFINED);
    }
    if (s_hstr == null) { ctx.result_string(heap.str(heap::BuiltinStr.EMPTY)); return; }

    int input_len = (int)s_hstr.unit_len();

    // Step 5: functionalReplace = IsCallable(replaceValue).
    TVal replace_val;
    replace_val.set_undefined();
    bool replace_is_fn = false;
    if (ctx.argc > 1) {
        replace_val = ctx.regs[ctx.base_reg + 1];
        replace_is_fn = replace_val.is_lightfunc() ||
            (replace_val.is_object() && replace_val.get_heapptr() != null &&
             ((HObject*)replace_val.get_heapptr()).is_callable());
    }

    // Step 6: if not functional → replaceValue = ? ToString(replaceValue).
    HString* replace_str_hstr = null;
    if (!replace_is_fn) {
        if (ctx.argc > 1) {
            replace_str_hstr = builtin_to_string_vm(ctx, &replace_val);
        } else {
            replace_str_hstr = heap.str(heap::BuiltinStr.UNDEFINED);
        }
        if (ctx.should_throw) return;
        if (replace_str_hstr == null) replace_str_hstr = heap.str(heap::BuiltinStr.UNDEFINED);
    }

    // Nothing above can run script once the arguments are coerced, so the
    // receiver's state is what the match loop sees.
    if (regexp_replace_try_pristine(ctx, rx, s_hstr, replace_is_fn, replace_val, replace_str_hstr)) return;

    // Step 8: flags = ? ToString(? Get(rx, "flags")).
    HString* flags_key = heap.str(heap::BuiltinStr.FLAGS);
    TVal? flags_opt = builtins_generic_get(rx, flags_key, ctx);
    if (ctx.should_throw) return;
    TVal flags_tv; flags_tv.set_undefined();
    if (try fv = flags_opt) { flags_tv = fv; }
    HString* flags_hstr = builtin_to_string_vm(ctx, &flags_tv);
    if (ctx.should_throw) return;
    if (flags_hstr == null) flags_hstr = heap.str(heap::BuiltinStr.EMPTY);

    // Parse flags for global, sticky, fullUnicode.
    bool global_flag = false;
    bool rr_full_unicode = false;
    for (uint fi = 0; fi < flags_hstr.unit_len(); fi++) {
        uint fc = flags_hstr.unit_at(fi);
        if (fc == 'g') global_flag = true;
        if (fc == 'u' || fc == 'v') rr_full_unicode = true;
    }

    HString* li_key = heap.str(heap::BuiltinStr.LAST_INDEX);

    // Step 11: if global → Set(rx, "lastIndex", 0, true), throws if non-writable.
    if (global_flag) {
        TVal zero_tv; zero_tv.set_fastint(0);
        if (!builtins_generic_set(ctx, rx, li_key, zero_tv, "lastIndex")) return;
    }

    // Collect all results first, then process (per spec two-pass structure).
    RrMatches matches = { .heap = heap };
    defer matches.free();
    bool done = false;

    while (!done) {
        TVal s_tv2; s_tv2.set_string(s_hstr);
        defer ctx.heap.decref_tval(&s_tv2);
        if (!regexp_exec_call(ctx, rx, &s_tv2)) return;
        TVal match_result = ctx.result.get();
        if (match_result.is_null()) {
            done = true;
        } else {
            if (!matches.push(match_result)) {
                builtin_throw(ctx, heap.range_err_proto, "Invalid string length");
                return;
            }
            if (!global_flag) {
                done = true;
            } else {
                if (!match_result.is_object() || match_result.get_heapptr() == null) {
                    done = true;
                } else {
                    HObject* mr = (HObject*)match_result.get_heapptr();
                    HString* zero_key2 = heap.int_to_hstring(0);
                    TVal? ms_opt2 = builtins_generic_get(mr, zero_key2, ctx);
                    if (ctx.should_throw) return;
                    TVal ms_raw2; ms_raw2.set_undefined();
                    if (try msv = ms_opt2) { ms_raw2 = msv; }
                    HString* ms_hstr2 = builtin_to_string_vm(ctx, &ms_raw2);
                    if (ctx.should_throw) return;
                    if (ms_hstr2 == null) ms_hstr2 = heap.str(heap::BuiltinStr.UNDEFINED);
                    if (ms_hstr2.unit_len() == 0) {
                        // Empty match: AdvanceStringIndex(S, ToLength(lastIndex), fullUnicode).
                        TVal? li_opt2 = builtins_generic_get(rx, li_key, ctx);
                        if (ctx.should_throw) return;
                        TVal li_raw2; li_raw2.set_fastint(0);
                        if (try lv2 = li_opt2) { li_raw2 = lv2; }
                        // ToLength coercion (calls valueOf on objects).
                        double li_d2 = builtin_to_integer_vm(ctx, &li_raw2);
                        if (ctx.should_throw) return;
                        if (li_d2 < 0.0) li_d2 = 0.0;
                        double max53 = 9007199254740991.0;
                        if (li_d2 > max53) li_d2 = max53;
                        long this_li = (long)li_d2;
                        // AdvanceStringIndex: if thisIndex >= length, return thisIndex + 1.
                        long next_li2 = this_li >= (long)s_hstr.unit_len()
                            ? this_li + 1
                            : (long)hstring::advance_string_index(s_hstr, (uint)this_li, rr_full_unicode);
                        TVal next_li_tv2;
                        if (next_li2 >= types::FASTINT_MIN && next_li2 <= types::FASTINT_MAX) {
                            next_li_tv2.set_fastint(next_li2);
                        } else {
                            next_li_tv2.set_number((double)next_li2);
                        }
                        if (!builtins_generic_set(ctx, rx, li_key, next_li_tv2, "lastIndex")) return;
                    }
                }
            }
        }
    }

    // Process collected results to build the output string.
    UnitBuf out;
    out.init(heap);
    defer out.free();
    int last_end = 0;
    // Per-match scratch, sized by each result's capture count.
    growvec::GrowVec{HString*} cap_strs_v = { .heap = heap };
    growvec::GrowVec{StrSlice} cap_slices_v = { .heap = heap };
    growvec::GrowVec{TVal} fn_args_v = { .heap = heap };
    defer cap_strs_v.free();
    defer cap_slices_v.free();
    defer fn_args_v.free();

    for (usz ri = 0; ri < matches.len; ri++) {
        TVal m_tv = matches.items[ri];
        if (!m_tv.is_object() || m_tv.get_heapptr() == null) continue;
        HObject* m = (HObject*)m_tv.get_heapptr();

        // Step 14.a: nCaptures = ToLength(Get(result,"length")) - 1.
        HString* len_key = heap.str(heap::BuiltinStr.LENGTH);
        TVal? len_opt = builtins_generic_get(m, len_key, ctx);
        if (ctx.should_throw) return;
        TVal len_raw; len_raw.set_fastint(0);
        if (try lv = len_opt) { len_raw = lv; }
        double len_d = builtin_to_integer_vm(ctx, &len_raw);
        if (ctx.should_throw) return;
        if (len_d < 0.0) len_d = 0.0;
        double max53 = 9007199254740991.0;
        if (len_d > max53) len_d = max53;
        long num_caps_l = (long)len_d - 1;
        if (num_caps_l < 0) num_caps_l = 0;
        usz num_caps = (usz)num_caps_l;
        if (!cap_strs_v.reserve(num_caps) || !cap_slices_v.reserve(num_caps)
            || !fn_args_v.reserve(num_caps + 4)) {
            builtin_throw(ctx, heap.range_err_proto, "Invalid string length");
            return;
        }
        HString** cap_strs = cap_strs_v.items;

        // Step 14.b: matched = ? ToString(? Get(result, "0")).
        HString* zero_key = heap.int_to_hstring(0);
        TVal? z_opt = builtins_generic_get(m, zero_key, ctx);
        if (ctx.should_throw) return;
        TVal z_raw; z_raw.set_undefined();
        if (try zv = z_opt) { z_raw = zv; }
        HString* matched_hstr = builtin_to_string_vm(ctx, &z_raw);
        if (ctx.should_throw) return;
        if (matched_hstr == null) matched_hstr = heap.str(heap::BuiltinStr.UNDEFINED);

        // Step 14.e: position = ? ToInteger(? Get(result, "index")), clamped
        // to [0,|S|], where |S| is the UTF-16 code-unit length.
        HString* idx_key = heap.str(heap::BuiltinStr.INDEX);
        TVal? idx_opt = builtins_generic_get(m, idx_key, ctx);
        if (ctx.should_throw) return;
        TVal idx_raw; idx_raw.set_fastint(0);
        if (try iv = idx_opt) { idx_raw = iv; }
        double pos_d = builtin_to_integer_vm(ctx, &idx_raw);
        if (ctx.should_throw) return;
        if (pos_d < 0.0) pos_d = 0.0;
        double str_charlen_d = (double)s_hstr.unit_len();
        if (pos_d > str_charlen_d) pos_d = str_charlen_d;
        int out_start = (int)pos_d;
        // Step 14.h: endOfLastMatch is position + the match's length in code
        // units. `matched` comes from the exec result and is its own string;
        // with an exec override it need not occur in the input at all.
        double end_charunit = pos_d + (double)matched_hstr.unit_len();
        if (end_charunit > str_charlen_d) end_charunit = str_charlen_d;
        int out_end = (int)end_charunit;

        // Step 14.f: coerce each capture to HString* (null = undefined).
        for (usz ci = 0; ci < num_caps; ci++) {
            HString* cap_key_hs = heap.int_to_hstring((long)(ci + 1));
            TVal? cap_opt = builtins_generic_get(m, cap_key_hs, ctx);
            if (ctx.should_throw) return;
            TVal cap_tv; cap_tv.set_undefined();
            if (try cv = cap_opt) { cap_tv = cv; }
            if (cap_tv.is_undefined()) {
                cap_strs[ci] = null;
            } else {
                HString* cs = builtin_to_string_vm(ctx, &cap_tv);
                if (ctx.should_throw) return;
                cap_strs[ci] = cs != null ? cs : heap.str(heap::BuiltinStr.UNDEFINED);
            }
        }

        // Step 14.j: namedCaptures = ? Get(result, "groups").
        HString* groups_key = heap.str(heap::BuiltinStr.GROUPS);
        TVal? groups_opt = builtins_generic_get(m, groups_key, ctx);
        if (ctx.should_throw) return;
        TVal named_captures_tv; named_captures_tv.set_undefined();
        if (try gv = groups_opt) { named_captures_tv = gv; }
        bool have_named_captures = !named_captures_tv.is_undefined();

        if (replace_is_fn) {
            // Step 14.k: functional replace.
            // replacerArgs = [matched, cap1..capN, position, S, ?namedCaptures]
            TVal* fn_args = fn_args_v.items;
            usz arg_count = 0;
            TVal matched_tv; matched_tv.set_string_borrowed(matched_hstr);
            fn_args[arg_count++] = matched_tv;
            for (usz ci = 0; ci < num_caps; ci++) {
                if (cap_strs[ci] != null) {
                    TVal cap_tv; cap_tv.set_string_borrowed(cap_strs[ci]);
                    fn_args[arg_count++] = cap_tv;
                } else {
                    TVal cap_undef; cap_undef.set_undefined();
                    fn_args[arg_count++] = cap_undef;
                }
            }
            TVal pos_tv; pos_tv.set_fastint((long)pos_d);
            fn_args[arg_count++] = pos_tv;
            TVal str_tv; str_tv.set_string_borrowed(s_hstr);
            fn_args[arg_count++] = str_tv;
            // Append namedCaptures only if not undefined (step 14.k.iv).
            if (have_named_captures) {
                fn_args[arg_count++] = named_captures_tv;
            }
            TVal undef_this; undef_this.set_undefined();
            TVal res = heap.call_fn(ctx.vm, replace_val, fn_args, (uint)arg_count, undef_this);
            if (heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = heap.error_value;
                heap.has_error = false;
                return;
            }
            HString* rep_hs = builtin_to_string_vm(ctx, &res);
            if (ctx.should_throw) return;
            if (rep_hs == null) rep_hs = heap.str(heap::BuiltinStr.UNDEFINED);

            if (out_start >= last_end) {
                out.append_hstring_range(s_hstr, (uint)last_end, (uint)out_start);
                out.append_hstring(rep_hs);
                last_end = out_end > input_len ? input_len : out_end;
            }
        } else {
            // Step 14.l: string GetSubstitution.
            // If namedCaptures is not undefined, ToObject(namedCaptures).
            if (have_named_captures) {
                if (named_captures_tv.is_null()) {
                    builtin_throw_no_result_change(ctx, heap.type_err_proto,
                        "Cannot convert null namedCaptures to object");
                    return;
                }
                if (!named_captures_tv.is_object()) {
                    // Box primitive as wrapper object for property lookup.
                    if (named_captures_tv.is_string() && named_captures_tv.get_heapptr() != null) {
                        HObject*? box_raw = heap.alloc_object(hobject::ObjClass.STRING);
                        if (try box = box_raw) {
                            heap.set_prototype(box, heap.string_proto);
                            ctx.heap.tval_copy_ref(&(*box.extra_ptr()).prim.primitive_value, &named_captures_tv);
                            // Set own .length (non-writable, non-enum, non-configurable)
                            HString* str_len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                            TVal str_len_tv;
                            HString* s_hs = (HString*)named_captures_tv.get_heapptr();
                            str_len_tv.set_fastint((long)s_hs.unit_len());
                            box.put_prop(str_len_key, str_len_tv, hobject::PROP_FLAGS_NNC, ctx.heap);
                            named_captures_tv.set_object(box);
                        }
                    } else if (named_captures_tv.is_fastint() || named_captures_tv.is_number()) {
                        HObject*? box_raw = heap.alloc_object(hobject::ObjClass.NUMBER);
                        if (try box = box_raw) {
                            heap.set_prototype(box, heap.number_proto);
                            ctx.heap.tval_copy_ref(&(*box.extra_ptr()).prim.primitive_value, &named_captures_tv);
                            named_captures_tv.set_object(box);
                        }
                    } else if (named_captures_tv.is_boolean()) {
                        HObject*? box_raw = heap.alloc_object(hobject::ObjClass.BOOLEAN);
                        if (try box = box_raw) {
                            heap.set_prototype(box, heap.bool_proto);
                            ctx.heap.tval_copy_ref(&(*box.extra_ptr()).prim.primitive_value, &named_captures_tv);
                            named_captures_tv.set_object(box);
                        }
                    }
                }
            }

            // The substitution is evaluated even for a match that starts before
            // endOfLastMatch (its named-capture reads are observable); the
            // text is then dropped.
            usz keep = out.len;
            bool append = out_start >= last_end;
            if (append) out.append_hstring_range(s_hstr, (uint)last_end, (uint)out_start);
            StrSlice[] cap_slices = cap_slices_v.items[:num_caps];
            for (usz ci = 0; ci < num_caps; ci++) cap_slices[ci] = slice_of(cap_strs[ci]);
            rr_get_substitution(ctx, &out,
                slice_of(matched_hstr),
                s_hstr, (uint)out_start, (uint)out_end,
                cap_slices,
                named_captures_tv, have_named_captures,
                replace_str_hstr);
            if (ctx.should_throw) return;
            if (append) {
                last_end = out_end > input_len ? input_len : out_end;
            } else {
                out.truncate(keep);
            }
        }
    }

    // Append tail [last_end, input_len).
    out.append_hstring_range(s_hstr, (uint)last_end, (uint)input_len);
    out.finish(ctx);
}

// ============================================================================
// RegExp.prototype[@@split], ECMA-262 §21.2.5.11
// ============================================================================
// Step 16-17 of @@split: lim = ToUint32(limit), or 2^32-1 when undefined.
// test262's coerce-limit tests need a Symbol limit to throw a TypeError, so the
// coercion goes through ToInteger. Returns false with an exception pending.
fn bool regexp_split_limit(BuiltinContext* ctx, ulong* limit) {
    Heap* heap = ctx.heap;
    *limit = 0xFFFFFFFF;
    if (ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
        TVal limit_arg = ctx.regs[ctx.base_reg + 1];
        if (limit_arg.is_string() && limit_arg.get_heapptr() != null &&
            ((HString*)limit_arg.get_heapptr()).is_symbol()) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto,
                "Cannot convert Symbol to number");
            return false;
        }
        double limit_d = builtin_to_integer_vm(ctx, &limit_arg);
        if (ctx.should_throw) return false;
        // ToUint32 wraps modulo 2^32; NaN and the infinities become 0.
        if (math::is_nan(limit_d) || !math::is_finite(limit_d)) {
            *limit = 0;
        } else {
            double two32 = 4294967296.0;
            double n = limit_d - math::floor(limit_d / two32) * two32;
            *limit = (ulong)(uint)n;
        }
    }
    return true;
}

// Appends `value` as element `*count` of a split result.
fn void regexp_split_push(Heap* heap, HObject* arr, ulong* count, TVal value) {
    if (value.is_undefined()) {
        arr.put_prop(heap.int_to_hstring((long)*count), value, hobject::PROP_FLAGS_WEC, heap);
    } else {
        arr.set_array_idx((uint)*count, value, heap);
    }
    (*count)++;
}

// @@split for a pristine receiver (see regexp_is_pristine) whose species
// constructor is %RegExp%. The spec builds a sticky copy of the receiver and
// tries it at every index; trying each index in turn is the same as one
// forward search, so the receiver's own matcher is searched from `q` and the
// copy is never made.
fn void regexp_split_pristine(BuiltinContext* ctx, HObject* rx, HString* s_hstr, ulong limit) {
    Heap* heap = ctx.heap;
    void* re_data = (*rx.extra_ptr()).regexp.regexp_data;
    bool full_unicode = ((*rx.extra_ptr()).regexp.flags & (16 | 128)) != 0;
    int input_len = (int)s_hstr.unit_len();
    usz ncap = (usz)(re_bindings::re_get_capture_count(re_data) - 1);

    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result_null(); return; }
    HObject* arr = arr_raw;
    heap.set_prototype(arr, heap.array_proto);
    if (limit == 0) { ctx.result_object(arr); return; }

    int[32] bounds_storage;
    growvec::GrowVec{int} bounds = { .heap = heap };
    bounds.use_storage(&bounds_storage, 32);
    defer bounds.free();
    if (!bounds.reserve(2 * ncap + 2)) {
        builtin_throw(ctx, heap.range_err_proto, "Invalid string length");
        return;
    }
    int* caps = bounds.items;
    int cap_slots = (int)(2 * ncap + 2);

    ulong count = 0;
    if (input_len == 0) {
        // The empty subject is [] when the matcher accepts it and [S] when not.
        if (regexp_run(ctx, re_data, s_hstr, 0, caps, cap_slots) != re_bindings::RE_MATCH) {
            if (ctx.should_throw) return;
            TVal whole;
            whole.set_string_borrowed(s_hstr);
            regexp_split_push(heap, arr, &count, whole);
        }
    }
    int p = 0;
    int q = 0;
    while (q < input_len) {
        // Positions below the next match fail, as the sticky search would. A
        // match that starts at the end of the subject is never tried.
        if (regexp_run(ctx, re_data, s_hstr, q, caps, cap_slots) != re_bindings::RE_MATCH || caps[0] >= input_len) {
            if (ctx.should_throw) return;
            break;
        }
        int m_start = caps[0];
        int m_end = caps[1];
        q = m_start;
        if (m_end == p) {
            q = (int)hstring::advance_string_index(s_hstr, (uint)q, full_unicode);
            continue;
        }
        TVal piece;
        piece.set_string_borrowed(heap.str_slice(s_hstr, (uint)p, (uint)m_start));
        regexp_split_push(heap, arr, &count, piece);
        if (count == limit) break;
        for (usz i = 1; i <= ncap && count < limit; i++) {
            TVal cap;
            cap.set_undefined();
            if (caps[2 * i] >= 0 && caps[2 * i + 1] >= 0) {
                cap.set_string_borrowed(heap.str_slice(s_hstr, (uint)caps[2 * i], (uint)caps[2 * i + 1]));
            }
            regexp_split_push(heap, arr, &count, cap);
        }
        if (count == limit) break;
        p = m_end;
        q = p;
    }
    if (input_len > 0 && count < limit) {
        TVal tail;
        if (p == 0) {
            tail.set_string_borrowed(s_hstr);
        } else {
            tail.set_string_borrowed(heap.str_slice(s_hstr, (uint)p, (uint)input_len));
        }
        regexp_split_push(heap, arr, &count, tail);
    }
    TVal len_tv;
    len_tv.set_fastint((long)count);
    arr.put_prop(heap.str(heap::BuiltinStr.LENGTH), len_tv, hobject::PROP_FLAGS_WEC, heap);
    ctx.result_object(arr);
}

// SpeciesConstructor(rx, %RegExp%) into *out. False when it threw.
fn bool regexp_species_constructor(BuiltinContext* ctx, HObject* rx, TVal* out) {
    Heap* heap = ctx.heap;
    out.set_undefined();
    // Resolve %RegExp% default constructor.
    // The constructor object is stored on RegExp.prototype as its "constructor"
    // property, this is available directly via heap.regexp_proto.
    TVal default_ctor_tv; default_ctor_tv.set_undefined();
    // Look up %RegExp% from the global environment via the VM's global_env.
    // ctx.global_env is null when the builtin is called via call_fn (internal
    // path), but ctx.vm always holds the Vm* pointer when available.
    EnvRecord* genv = ctx.global_env;
    if (genv == null && ctx.vm != null) {
        genv = ((vm::Vm*)ctx.vm).global_env;
    }
    if (genv != null) {
        HString* regexp_gkey = builtin_intern_string(heap, "RegExp");
        if (regexp_gkey != null) {
            TVal? gv = env::env_get(genv, regexp_gkey);
            if (try rgv = gv) { default_ctor_tv = rgv; }
        }
    }

    HString* ctor_key = heap.str(heap::BuiltinStr.CONSTRUCTOR);
    TVal? ctor_opt = builtins_generic_get(rx, ctor_key, ctx);
    if (ctx.should_throw) return false;
    TVal ctor_tv; ctor_tv.set_undefined();
    if (try cv = ctor_opt) { ctor_tv = cv; }

    if (ctor_tv.is_undefined()) {
        // Step 4: C is undefined → return defaultConstructor (%RegExp%).
        *out = default_ctor_tv;
    } else {
        if (!ctor_tv.is_object() || ctor_tv.get_heapptr() == null) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto,
                "constructor is not an object");
            return false;
        }
        HObject* ctor_obj = (HObject*)ctor_tv.get_heapptr();
        HString* species_sym = ensure_species_symbol(heap);
        if (species_sym != null) {
            TVal? sp_opt = builtins_generic_get(ctor_obj, species_sym, ctx);
            if (ctx.should_throw) return false;
            if (try spv = sp_opt) {
                if (!spv.is_undefined() && !spv.is_null()) {
                    // Step 5: species is the constructor to use.
                    *out = spv;
                } else {
                    // species is null/undefined → return defaultConstructor.
                    *out = default_ctor_tv;
                }
            } else {
                // @@species not found → return defaultConstructor.
                *out = default_ctor_tv;
            }
        } else {
            *out = default_ctor_tv;
        }
    }
    return true;
}

fn void builtin_regexp_proto_symbol_split(BuiltinContext* ctx) {
    HObject* rx = regexp_get_symbol_this(ctx);
    if (rx == null) return;

    Heap* heap = ctx.heap;
    HString* li_key   = heap.str(heap::BuiltinStr.LAST_INDEX);
    HString* len_key  = heap.str(heap::BuiltinStr.LENGTH);

    // Step 3: Let S be ? ToString(string).
    TVal s_tv; s_tv.set_undefined();
    if (ctx.argc > 0) { s_tv = ctx.regs[ctx.base_reg]; }
    HString* s_hstr;
    if (s_tv.is_string() && s_tv.get_heapptr() != null
        && !((HString*)s_tv.get_heapptr()).is_symbol()) {
        HString* tmp_hs = (HString*)s_tv.get_heapptr();
        // Symbols cannot be converted to string, throw TypeError.
        if (tmp_hs.is_symbol()) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto,
                "Cannot convert Symbol to string");
            return;
        }
        s_hstr = tmp_hs;
    } else {
        s_hstr = builtin_to_string_vm(ctx, &s_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) { s_hstr = heap.str(heap::BuiltinStr.UNDEFINED); }
    }

    // A pristine, non-sticky receiver with the default species constructor
    // needs no sticky copy of itself. Only a limit that is undefined or a
    // number is safe to coerce after the guard has passed: anything else can run
    // script that changes what the guard saw.
    if (regexp_is_pristine(heap, rx) && ((*rx.extra_ptr()).regexp.flags & 32) == 0
        && regexp_species_pristine(heap)) {
        TVal limit_arg;
        limit_arg.set_undefined();
        if (ctx.argc > 1) limit_arg = ctx.regs[ctx.base_reg + 1];
        if (limit_arg.is_undefined() || limit_arg.is_number() || limit_arg.is_fastint()) {
            ulong limit;
            if (!regexp_split_limit(ctx, &limit)) return;
            regexp_split_pristine(ctx, rx, s_hstr, limit);
            return;
        }
    }

    // Step 4: Let C be ? SpeciesConstructor(rx, %RegExp%).
    // SpeciesConstructor(O, defaultConstructor):
    //   1. C = Get(O, "constructor"); if undefined → return defaultConstructor.
    //   2. If C is not an object → throw TypeError.
    //   3. species = Get(C, @@species); if null/undefined → return defaultConstructor.
    //   4. If species is not a constructor → throw TypeError.
    //   5. Return species.
    // We always track the resolved constructor in species_ctor_tv.
    // For the default path (%RegExp%), look it up from global_env.
    TVal species_ctor_tv;
    if (!regexp_species_constructor(ctx, rx, &species_ctor_tv)) return;

    // Step 7: Let flags be ? ToString(? Get(rx, "flags")).
    HString* flags_key = heap.str(heap::BuiltinStr.FLAGS);
    TVal? flags_opt = builtins_generic_get(rx, flags_key, ctx);
    if (ctx.should_throw) return;
    TVal flags_tv; flags_tv.set_undefined();
    if (try fv = flags_opt) { flags_tv = fv; }
    HString* flags_str = builtin_to_string_vm(ctx, &flags_tv);
    if (ctx.should_throw) return;
    if (flags_str == null) { flags_str = heap.str(heap::BuiltinStr.EMPTY); }

    // Step 8: newFlags = flags; if 'y' not in flags, append 'y'.
    bool has_y = false;
    bool has_u = false;
    uint flen = flags_str.unit_len();
    for (uint i = 0; i < flen; i++) {
        if (flags_str.unit_at(i) == 'y') { has_y = true; }
        if (flags_str.unit_at(i) == 'u') { has_u = true; }
    }
    HString* new_flags_str;
    if (has_y) {
        new_flags_str = flags_str;
    } else {
        // Append 'y'.
        UnitBuf nf;
        nf.init(heap);
        defer nf.free();
        nf.append_hstring(flags_str);
        nf.append_char('y');
        new_flags_str = nf.to_hstring(ctx);
        if (new_flags_str == null) return;
    }

    // Step 9: Let splitter be ? Construct(C, «rx, newFlags»).
    // If species_ctor_tv is callable and construct_fn is available, use it.
    // Otherwise, fall through to use rx itself as the splitter (built-in path).
    HObject* splitter = null;
    bool have_external_splitter = false;
    if (!species_ctor_tv.is_undefined() && heap.construct_fn != null && ctx.vm != null) {
        TVal rx_tv; rx_tv.set_object(rx);
        TVal new_flags_tv; new_flags_tv.set_string(new_flags_str);
        defer ctx.heap.decref_tval(&new_flags_tv);
        TVal[2] ctor_args;
        ctor_args[0] = rx_tv;
        ctor_args[1] = new_flags_tv;
        TVal splitter_tv = heap.construct_fn(ctx.vm, species_ctor_tv, &ctor_args[0], 2, species_ctor_tv);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            return;
        }
        if (splitter_tv.is_object() && splitter_tv.get_heapptr() != null) {
            splitter = (HObject*)splitter_tv.get_heapptr();
            have_external_splitter = true;
        } else {
            builtin_throw_no_result_change(ctx, heap.type_err_proto,
                "species constructor did not return an object");
            return;
        }
    }

    // If no external splitter, use rx itself as splitter (built-in fast path).
    if (splitter == null) { splitter = rx; }

    ulong limit;
    if (!regexp_split_limit(ctx, &limit)) return;

    // Create result array.
    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result_null(); return; }
    HObject* arr = arr_raw;
    heap.set_prototype(arr, heap.array_proto);

    if (limit == 0) {
        ctx.result_object(arr);
        return;
    }

    int input_len = (int)s_hstr.unit_len();

    // Step 22: if size = 0, handle empty string case.
    if (input_len == 0) {
        TVal s_tv2; s_tv2.set_string(s_hstr);
        defer ctx.heap.decref_tval(&s_tv2);
        if (!regexp_exec_call(ctx, splitter, &s_tv2)) return;
        TVal z = ctx.result.get();
        if (z.is_null()) {
            // No match on empty string, return [S].
            TVal elem; elem.set_string_borrowed(s_hstr);
            arr.put_prop(heap.int_to_hstring(0), elem, hobject::PROP_FLAGS_WEC, ctx.heap);
            TVal lv; lv.set_fastint(1);
            arr.put_prop(len_key, lv, hobject::PROP_FLAGS_WEC, ctx.heap);
        }
        // else: match, return [] (empty).
        ctx.result_object(arr);
        return;
    }

    ulong arr_idx = 0;
    int q = 0;  // current search position in code units
    int p = 0;  // start of current substring in code units

    // Main loop: ES §21.2.5.11 step 24.
    while (q < input_len) {
        // Step 24.a: Set(splitter, "lastIndex", q, true).
        {
            TVal q_tv; q_tv.set_fastint((long)q);
            if (!regexp_set_last_index(ctx, splitter, li_key, q_tv)) return;
        }

        // Step 24.c: Let z be ? RegExpExec(splitter, S).
        TVal s_tv2; s_tv2.set_string(s_hstr);
        defer ctx.heap.decref_tval(&s_tv2);
        if (!regexp_exec_call(ctx, splitter, &s_tv2)) return;
        TVal z = ctx.result.get();

        // Step 24.e: If z is null, let q be AdvanceStringIndex(S, q, unicodeMatching).
        if (z.is_null()) {
            q = (int)hstring::advance_string_index(s_hstr, (uint)q, has_u);
            continue;
        }

        if (!z.is_object() || z.get_heapptr() == null) {
            // Treat as no match.
            q = (int)hstring::advance_string_index(s_hstr, (uint)q, has_u);
            continue;
        }
        HObject* z_obj = (HObject*)z.get_heapptr();

        // Step 24.f.i: Let e be ? ToLength(? Get(splitter, "lastIndex")).
        TVal li_raw; li_raw.set_fastint(0);
        if (!regexp_fast_last_index_read(ctx, splitter, li_key, &li_raw)) {
            TVal? li_opt = builtins_generic_get(splitter, li_key, ctx);
            if (ctx.should_throw) return;
            if (try lv = li_opt) { li_raw = lv; }
        }
        double e_d = builtin_to_integer_vm(ctx, &li_raw);
        if (ctx.should_throw) return;
        if (e_d < 0.0) { e_d = 0.0; }
        // Clamp e to size.
        if (e_d > (double)input_len) { e_d = (double)input_len; }
        int e = (int)e_d;

        // Step 24.f.ii: If e == p, advance q (no forward progress).
        if (e == p) {
            q = (int)hstring::advance_string_index(s_hstr, (uint)q, has_u);
            continue;
        }

        // Step 24.f.iv: e != p, we have a real match boundary.
        // Push substring [p, q) as the next result element.
        {
            HString* substr = heap.str_slice(s_hstr, (uint)p, (uint)q);
            TVal elem; elem.set_string_borrowed(substr);
            arr.put_prop(heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC, ctx.heap);
            arr_idx++;
            if (arr_idx >= limit) {
                TVal lv; lv.set_fastint((long)arr_idx);
                arr.put_prop(len_key, lv, hobject::PROP_FLAGS_WEC, ctx.heap);
                ctx.result_object(arr);
                return;
            }
        }

        // Step 24.f.iv.7: numberOfCaptures = ToLength(Get(z, "length")) - 1.
        TVal? zlen_opt = builtins_generic_get(z_obj, len_key, ctx);
        if (ctx.should_throw) return;
        TVal zlen_raw; zlen_raw.set_fastint(0);
        if (try zlv = zlen_opt) { zlen_raw = zlv; }
        double zlen_d = builtin_to_integer_vm(ctx, &zlen_raw);
        if (ctx.should_throw) return;
        if (zlen_d < 0.0) { zlen_d = 0.0; }
        int num_caps = (int)zlen_d - 1;
        if (num_caps < 0) { num_caps = 0; }

        // Step 24.f.iv.11: For each capture group i in 1..numberOfCaptures.
        for (int i = 1; i <= num_caps; i++) {
            HString* cap_key = heap.int_to_hstring((long)i);
            TVal? cap_opt = builtins_generic_get(z_obj, cap_key, ctx);
            if (ctx.should_throw) return;
            TVal cap_tv; cap_tv.set_undefined();
            if (try cv = cap_opt) { cap_tv = cv; }
            // Captures are pushed as-is (undefined stays undefined).
            arr.put_prop(heap.int_to_hstring((long)arr_idx), cap_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
            arr_idx++;
            if (arr_idx >= limit) {
                TVal lv; lv.set_fastint((long)arr_idx);
                arr.put_prop(len_key, lv, hobject::PROP_FLAGS_WEC, ctx.heap);
                ctx.result_object(arr);
                return;
            }
        }

        p = e;
        q = e;
    }

    // Tail: push [p, size) as the final element.
    if (arr_idx < limit) {
        HString* tail_str = heap.str_slice(s_hstr, (uint)p, (uint)input_len);
        TVal elem; elem.set_string_borrowed(tail_str);
        arr.put_prop(heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC, ctx.heap);
        arr_idx++;
    }

    TVal len_val; len_val.set_fastint((long)arr_idx);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC, ctx.heap);
    ctx.result_object(arr);
}

// ============================================================================
// RegExp.prototype accessor getters (ECMA-262 §21.2.5)
// These are getter functions registered on RegExp.prototype via accessor properties.
// js_flags encoding: 1=g, 2=i, 4=m, 8=s(dotAll), 16=u(unicode), 32=y(sticky)
// ============================================================================

// RegExp.prototype[@@matchAll], ECMA-262 §21.2.5.8 (MatchAllIterator)
fn void builtin_regexp_proto_symbol_matchAll(BuiltinContext* ctx) {
    if (ctx.is_constructor) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "RegExp.prototype[Symbol.matchAll] is not a constructor");
        return;
    }
    // Step 1: Let R be the this value.
    // Step 2: If Type(R) is not Object, throw a TypeError.
    HObject* rx = regexp_get_symbol_this(ctx);
    if (rx == null) return;

    Heap* heap = ctx.heap;

    // Step 3: Return ? MatchAllIterator(R, string).
    // MatchAllIterator steps:
    // 1. Let S be ? ToString(O).
    TVal s_tv; s_tv.set_undefined();
    if (ctx.argc > 0) s_tv = ctx.regs[ctx.base_reg];
    HString* s_hstr;
    if (s_tv.is_string() && s_tv.get_heapptr() != null
        && !((HString*)s_tv.get_heapptr()).is_symbol()) {
        HString* tmp = (HString*)s_tv.get_heapptr();
        if (tmp.is_symbol()) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto,
                "Cannot convert Symbol to string");
            return;
        }
        s_hstr = tmp;
    } else {
        s_hstr = builtin_to_string_vm(ctx, &s_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) s_hstr = heap.str(heap::BuiltinStr.UNDEFINED);
    }
    s_tv.set_string(s_hstr);
    defer heap.decref_tval(&s_tv);

    // 2. If ? IsRegExp(R) is true, and
    //    SameValue(? Get(R, "flags"), undefined), actually:
    //    IsRegExp just checks @@match on R to determine if it "looks like" a regexp.
    //    The spec doesn't throw here; the Construct call below triggers IsRegExp on rx.

    // 3. Let C be ? SpeciesConstructor(R, %RegExp%).
    TVal species_ctor_tv;
    if (!regexp_species_constructor(ctx, rx, &species_ctor_tv)) return;

    // 4. Let flags be ? ToString(? Get(R, "flags")).
    HString* flags_key = heap.str(heap::BuiltinStr.FLAGS);
    TVal? flags_opt = builtins_generic_get(rx, flags_key, ctx);
    if (ctx.should_throw) return;
    HString* flags_str = heap.str(heap::BuiltinStr.EMPTY);
    if (try fv = flags_opt) {
        if (fv.is_string() && fv.get_heapptr() != null) {
            flags_str = (HString*)fv.get_heapptr();
        } else {
            HString* fs = builtin_to_string_vm(ctx, &fv);
            if (ctx.should_throw) return;
            if (fs != null) flags_str = fs;
        }
    }

    // 5. Let matcher be ? Construct(C, «R, flags»).
    // When C is undefined (SpeciesConstructor failed to resolve), use rx itself.
    HObject* matcher = null;
    if (!species_ctor_tv.is_undefined() && heap.construct_fn != null && ctx.vm != null) {
        TVal rx_tv; rx_tv.set_object(rx);
        TVal flags_tv; flags_tv.set_string(flags_str);
        defer ctx.heap.decref_tval(&flags_tv);
        TVal[2] ctor_args;
        ctor_args[0] = rx_tv;
        ctor_args[1] = flags_tv;
        TVal matcher_tv = heap.construct_fn(ctx.vm, species_ctor_tv, &ctor_args[0], 2, species_ctor_tv);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            return;
        }
        if (matcher_tv.is_object() && matcher_tv.get_heapptr() != null) {
            matcher = (HObject*)matcher_tv.get_heapptr();
        } else {
            builtin_throw_no_result_change(ctx, heap.type_err_proto,
                "species constructor did not return an object");
            return;
        }
    }
    if (matcher == null) { matcher = rx; }

    // 6. Let lastIndex be ? ToLength(? Get(R, "lastIndex")).
    HString* li_key = heap.str(heap::BuiltinStr.LAST_INDEX);
    TVal li_raw; li_raw.set_fastint(0);
    {
        TVal? li_opt = builtins_generic_get(rx, li_key, ctx);
        if (ctx.should_throw) return;
        if (try lv = li_opt) { li_raw = lv; }
    }
    double li_d = builtin_to_integer_vm(ctx, &li_raw);
    if (ctx.should_throw) return;
    if (li_d < 0.0) li_d = 0.0;
    TVal li_tv; li_tv.set_fastint((long)li_d);

    // 7. Perform ? Set(matcher, "lastIndex", lastIndex, true).
    if (!builtins_generic_set(ctx, matcher, li_key, li_tv, "lastIndex")) return;

    // 8. If flags contains "g", let global be true.
    bool global_flag = false;
    bool unicode_flag = false;
    for (uint i = 0; i < flags_str.unit_len(); i++) {
        uint fc = flags_str.unit_at(i);
        if (fc == 'g') global_flag = true;
        if (fc == 'u' || fc == 'v') unicode_flag = true;
    }

    // 9. Return CreateRegExpStringIterator(matcher, S, global, unicode).
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.REGEXP_STRING_ITERATOR);
    if (catch err = iter_raw) { ctx.result_null(); return; }
    HObject* iter = iter_raw;
    (*iter.extra_ptr()).regexp_iter.string.set(heap, s_hstr);
    ctx.heap.@set_edge(iter, (*iter.extra_ptr()).regexp_iter.regexp, matcher);
    // flags bits: bit 0 = global, bit 1 = done, bit 2 = unicode
    uint iter_flags = 0;
    if (global_flag) iter_flags |= 1;
    if (unicode_flag) iter_flags |= 4;
    (*iter.extra_ptr()).regexp_iter.flags = iter_flags;
    heap.set_prototype(iter, heap.regexp_string_iterator_proto);

    ctx.result_object(iter);
}

// Result of regexp_get_this_or_throw: the HObject and whether it's the prototype.
struct RegexpThisResult {
    HObject* obj;
    bool is_proto;
}

// Helper: get regexp this or throw TypeError.
// Returns obj with is_proto=false for normal RegExp objects, or (RegExp.prototype, true)
// when `this` is the RegExp prototype itself (for spec-compliant "undefined" returns).
fn RegexpThisResult regexp_get_this_or_throw(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    RegexpThisResult err_result;
    err_result.obj = null;
    err_result.is_proto = false;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Method get RegExp.prototype.flags called on incompatible receiver");
        return err_result;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.REGEXP) {
        // ECMA-262 §21.2.5.[flags]: if SameValue(R, %RegExpPrototype%) is true, return undefined.
        if (ctx.heap.regexp_proto != null && obj == ctx.heap.regexp_proto) {
            RegexpThisResult proto_result;
            proto_result.obj = obj;
            proto_result.is_proto = true;
            return proto_result;
        }
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Method get RegExp.prototype.flags called on incompatible receiver");
        return err_result;
    }
    RegexpThisResult ok_result;
    ok_result.obj = obj;
    ok_result.is_proto = false;
    return ok_result;
}

// Helper: get the `this` for RegExp.prototype[@@*] methods (relaxed:
// any Object, not just REGEXP-class, per ECMA-262 §21.2.5.[6-12] step 1, any
// `this` is accepted, then `IsRegExp` / RegExpExec abstract operations are
// applied later). Returns the HObject or sets ctx.should_throw and returns
// null when the receiver is not an Object.
fn HObject* regexp_get_symbol_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "RegExp method called on incompatible receiver");
        return null;
    }
    return (HObject*)this_val.get_heapptr();
}

// RegExpExec abstract operation (ECMA-262 §21.2.5.2.1), sets ctx.result to its
// normal Object-or-Null result, or to a Boolean when requested by `test`:
//   - Calls `Get(rx, "exec")`, invokes it as a function if callable
//   - Validates the returned value (must be Object or null)
//   - Falls back to RegExpBuiltinExec (re_run) for built-in regexps
//   - Sets ctx.should_throw on error; returns false in that case
// Whether `rx` is a RegExp whose `exec` is the intrinsic, read without a lookup:
// its only own property is lastIndex (the plain RegExp shape) and it inherits
// a pristine RegExp.prototype. Get(R, "exec") then reads a data property, which
// nothing can observe.
fn bool regexp_inherits_exec(Heap* heap, HObject* rx) @inline {
    return rx != null && regexp_plain_shape(heap, rx) && rx.prototype == heap.regexp_proto
        && regexp_proto_pristine(heap);
}

fn bool regexp_exec_call(BuiltinContext* ctx, HObject* rx, TVal* input_str_tv,
                         bool boolean_result = false) {
    if (regexp_inherits_exec(ctx.heap, rx)) {
        regexp_builtin_exec(ctx, rx, input_str_tv, boolean_result);
        return !ctx.should_throw;
    }
    // 3. Let exec be ? Get(R, "exec").
    HString* exec_key = ctx.heap.str(heap::BuiltinStr.EXEC);
    TVal? exec_opt = builtins_generic_get(rx, exec_key, ctx);
    if (ctx.should_throw) return false;
    TVal exec_tv;
    exec_tv.set_undefined();
    if (try ev = exec_opt) { exec_tv = ev; }
    // 4. If IsCallable(exec) is true, then
    bool exec_callable = exec_tv.is_lightfunc() ||
        (exec_tv.is_object() && exec_tv.get_heapptr() != null &&
         ((HObject*)exec_tv.get_heapptr()).is_callable());
    if (exec_callable) {
        // Preserve the observable Get above, then avoid nested VM entry when
        // it resolves to the exact intrinsic and the receiver has a live
        // RegExp matcher. RegExpBuiltinExec still performs input coercion and
        // reads lastIndex before loading the matcher and flags, since either
        // coercion can run script that recompiles the receiver.
        if (exec_tv.is_object() && rx != null
            && rx.get_class() == hobject::ObjClass.REGEXP
            && !rx.is_proxy()
            && (*rx.extra_ptr()).regexp.regexp_data != null) {
            HObject* exec_obj = (HObject*)exec_tv.get_heapptr();
            if (exec_obj != null && exec_obj.is_callable()
                && exec_obj.callable_kind() == hobject::CallableKind.BUILTIN_FN
                && (*exec_obj.extra_ptr()).func.builtin_fn_index
                    == (int)Builtin.REGEXP_PROTO_EXEC.ordinal) {
                regexp_builtin_exec(ctx, rx, input_str_tv, boolean_result);
                return !ctx.should_throw;
            }
        }

        // a. Let result be ? Call(exec, R, «S»).
        TVal[1] call_args;
        call_args[0] = *input_str_tv;
        TVal this_val; this_val.set_object(rx);
        TVal res = ctx.heap.call_fn(ctx.vm, exec_tv, &call_args[0], 1, this_val);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return false;
        }
        // b. If Type(result) is neither Object nor Null, throw TypeError.
        if (!res.is_null() && !res.is_object()) {
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
                "RegExp exec method returned neither object nor null");
            return false;
        }
        if (boolean_result) {
            ctx.result_boolean(!res.is_null());
        } else if (res.is_null()) {
            ctx.result_null();
        } else {
            ctx.copy_result(res);
        }
        return true;
    }
    // 5. If R does not have a [[RegExpMatcher]] internal slot, throw TypeError.
    if (rx.get_class() != hobject::ObjClass.REGEXP ||
        (*rx.extra_ptr()).regexp.regexp_data == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "RegExp method called on incompatible receiver");
        return false;
    }
    // 6. Return ? RegExpBuiltinExec(R, S).
    regexp_builtin_exec(ctx, rx, input_str_tv, boolean_result);
    return !ctx.should_throw;
}

// Own numeric `lastIndex` values are common on genuine RegExp objects. Resolve
// the slot each time: ToInteger may run script that changes the value or its
// writable attribute, so neither a slot pointer nor its flags survive it.
// The slot of `rx`'s own lastIndex when it is a data property (a writable
// one if `writable`), else -1. A RegExp still on the shape
// regexp_init_last_index gives it holds a writable one in slot 0.
fn int regexp_last_index_slot(Heap* heap, HObject* rx, HString* key, bool writable) @inline {
    if (rx.shape_id == heap.regexp_shape && heap.regexp_shape != 0
        && heap.regexp_shape_epoch == heap.shape_recycle_epoch
        && key == heap.str(heap::BuiltinStr.LAST_INDEX)) return 0;
    int idx = rx.find_prop_idx((void*)key, heap);
    if (idx < 0) return -1;
    hobject::PropFlags flags = rx.get_prop_flags((uint)idx, heap);
    if (flags.is_accessor || (writable && !flags.writable)) return -1;
    return idx;
}

fn bool regexp_fast_last_index_read(BuiltinContext* ctx, HObject* rx,
                                    HString* key, TVal* value) {
    if (rx == null || rx.get_class() != hobject::ObjClass.REGEXP
        || rx.is_proxy()) return false;
    int idx = regexp_last_index_slot(ctx.heap, rx, key, false);
    if (idx < 0) return false;
    TVal current = rx.prop_values()[idx].get();
    if (!current.is_fastint()) return false;
    *value = current;
    gcprofile::gcprof_regexp_lastindex_fast_read();
    return true;
}

fn bool regexp_fast_last_index_write(BuiltinContext* ctx, HObject* rx,
                                     HString* key, TVal* value) {
    if (rx == null || rx.get_class() != hobject::ObjClass.REGEXP
        || rx.is_proxy()) return false;
    int idx = regexp_last_index_slot(ctx.heap, rx, key, true);
    if (idx < 0) return false;
    ctx.heap.store_slot_ref(rx, &rx.prop_values()[idx], value);
    gcprofile::gcprof_regexp_lastindex_fast_write();
    return true;
}

fn bool regexp_set_last_index(BuiltinContext* ctx, HObject* rx, HString* key,
                              TVal value) {
    if (regexp_fast_last_index_write(ctx, rx, key, &value)) return true;
    return builtins_generic_set(ctx, rx, key, value, "lastIndex");
}

// Whether `rx` is a RegExp whose only own property is a writable data
// `lastIndex` in slot 0 holding a small integer, so RegExpBuiltinExec reads
// and writes nothing observable but that slot.
fn bool regexp_plain(Heap* heap, HObject* rx) @inline {
    return regexp_plain_shape(heap, rx) && rx.prop_values()[0].get().is_fastint();
}

// Whether `rx` is a live RegExp whose only own property is lastIndex.
fn bool regexp_plain_shape(Heap* heap, HObject* rx) @inline {
    return rx.shape_id == heap.regexp_shape && heap.regexp_shape != 0
        && heap.regexp_shape_epoch == heap.shape_recycle_epoch
        && rx.get_class() == hobject::ObjClass.REGEXP && !rx.is_proxy()
        && (*rx.extra_ptr()).regexp.regexp_data != null;
}

// A string argument RegExpBuiltinExec takes as is, or null.
fn HString* regexp_plain_input(TVal* v) @inline {
    if (!v.is_string()) return null;
    HString* s = (HString*)v.get_heapptr();
    return s != null && !s.is_symbol() ? s : null;
}

// The string RegExpBuiltinExec matches for the argument `v` when its ToString
// runs no script: a string as is, an undefined, null, boolean or number
// converted; null for anything else.
fn HString* regexp_exec_input(Heap* heap, TVal* v) @inline {
    switch (v.get_tag()) {
        case STRING: return regexp_plain_input(v);
        case UNDEFINED: case NULL_VAL: case BOOLEAN: case FASTINT: case NUMBER: return builtin_to_string(heap, v);
        default: return null;
    }
}

// The match array for the group bounds in `caps`, as re_run reports them.
fn HObject* regexp_match_array(Heap* heap, void* re_data, HString* s, int* caps, bool has_indices) {
    int num_caps = re_bindings::re_captures(re_data) - 1;
    BuiltinContext ctx = { .heap = heap };
    return regexp_build_match_result(&ctx, re_data, s, caps, num_caps, has_indices);
}

// Groups, group 0 included, whose bounds fit the capture buffer of the common
// RegExpBuiltinExec frame; a pattern with more takes regexp_exec_plain_large.
const int REGEXP_SMALL_GROUPS = 16;

// RegExpBuiltinExec (ECMA-262 §22.2.7.2) of a RegExp regexp_plain accepts over
// the string `s`, into `result`, which holds no value yet: the match array or
// null, or a Boolean when `boolean_result`. False, with nothing observable
// done, when the run was interrupted, which the generic path then reports.
fn bool regexp_exec_plain(Heap* heap, HObject* rx, HString* s, bool boolean_result, TVal* result) @inline {
    void* re_data = (*rx.extra_ptr()).regexp.regexp_data;
    if (re_bindings::re_group_count(re_data) > REGEXP_SMALL_GROUPS) {
        return regexp_exec_plain_large(heap, rx, s, boolean_result, result);
    }
    int[2 * REGEXP_SMALL_GROUPS] caps @noinit;
    return regexp_exec_into(heap, rx, s, boolean_result, result, &caps, caps.len);
}

fn bool regexp_exec_plain_large(Heap* heap, HObject* rx, HString* s, bool boolean_result, TVal* result) @noinline {
    int[2 * re_bindings::RE_MAX_CAPTURES] caps @noinit;
    return regexp_exec_into(heap, rx, s, boolean_result, result, &caps, caps.len);
}

// regexp_exec_plain with `cap_slots` ints at `caps`, which hold every group.
fn bool regexp_exec_into(Heap* heap, HObject* rx, HString* s, bool boolean_result, TVal* result,
                         int* caps, int cap_slots) @inline {
    void* re_data = (*rx.extra_ptr()).regexp.regexp_data;
    int jsf = (*rx.extra_ptr()).regexp.flags;
    hobject::PropValue* last_index = &rx.prop_values()[0];
    // A non-global, non-sticky match starts at 0 and leaves lastIndex alone.
    bool advances = (jsf & (1 | 32)) != 0;
    int start = 0;
    TVal value;
    if (advances) {
        long li = last_index.get().get_fastint();
        if (li < 0) li = 0;
        if (li > (long)s.unit_len()) {
            value.set_fastint(0);
            *last_index = (hobject::PropValue)value;
            value.set_boolean(false);
            if (!boolean_result) value.set_null();
            *result = value;
            return true;
        }
        start = (int)li;
    }
    re_bindings::ReInterrupt interrupt = { &heap::regexp_interrupt, heap };
    int ret = re_bindings::re_run_direct(re_data, s.data_ptr(), s.unit_len(), s.is_wide(), (uint)start,
                                         caps, cap_slots, &interrupt);
    if (@unlikely(heap.uncatchable_throw)) return false;
    if (ret != re_bindings::RE_MATCH) {
        if (advances) {
            value.set_fastint(0);
            *last_index = (hobject::PropValue)value;
        }
        value.set_boolean(false);
        if (!boolean_result) value.set_null();
        *result = value;
        return true;
    }
    if (advances) {
        // lastIndex = e; an empty match's AdvanceStringIndex is the caller's
        // (@@match step 8.g, @@replace step 11.d), so it is not done here.
        value.set_fastint((long)caps[1]);
        *last_index = (hobject::PropValue)value;
    }
    if (boolean_result) {
        result.set_boolean(true);
        return true;
    }
    HObject* arr = regexp_match_array(heap, re_data, s, caps, (jsf & 64) != 0);
    if (arr == null) {
        result.set_null();
        return true;
    }
    value.set_object(arr);
    heap.tval_copy_ref(result, &value);
    return true;
}

// RegExpBuiltinExec (ECMA-262 §22.2.7.2), sets ctx.result to the match array or
// null, or directly to a Boolean for RegExp.prototype.test. `rx` must already
// be a REGEXP-class object with a compiled matcher.
fn void regexp_builtin_exec(BuiltinContext* ctx, HObject* rx, TVal* input_str_tv,
                            bool boolean_result = false) {
    HString* s_hstr = regexp_plain_input(input_str_tv);
    if (s_hstr != null && regexp_plain(ctx.heap, rx)) {
        TVal result;
        result.set_undefined();
        if (regexp_exec_plain(ctx.heap, rx, s_hstr, boolean_result, &result)) {
            ctx.take_result(&result);
            return;
        }
    }
    if (s_hstr == null) {
        s_hstr = builtin_to_string_vm(ctx, input_str_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) s_hstr = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }

    // Step 3: ToLength(Get(R, "lastIndex")). Both halves can run arbitrary
    // script -- a getter on the receiver, then `valueOf` on what it returns --
    // and `RegExp.prototype.compile` called from there replaces this object's
    // matcher and flags in place. The spec reads `global` and `sticky` in
    // steps 5-6, after this, so the matcher and flags are loaded below rather
    // than before; a pointer latched up here would also be to a matcher
    // `compile` has already freed.
    HString* li_key = ctx.heap.str(heap::BuiltinStr.LAST_INDEX);
    double li_d;
    {
        TVal li_raw; li_raw.set_fastint(0);
        if (regexp_fast_last_index_read(ctx, rx, li_key, &li_raw)) {
            li_d = (double)li_raw.get_fastint();
        } else {
        TVal? li_opt = builtins_generic_get(rx, li_key, ctx);
        if (ctx.should_throw) return;
        if (try lv = li_opt) { li_raw = lv; }
        li_d = builtin_to_integer_vm(ctx, &li_raw);
        if (ctx.should_throw) return;
        }
        if (li_d < 0.0) li_d = 0.0;
    }

    void* re_data = (*rx.extra_ptr()).regexp.regexp_data;
    int jsf = (*rx.extra_ptr()).regexp.flags;
    bool global_flag = (jsf & 1) != 0;
    bool sticky_flag = (jsf & 32) != 0;
    bool has_indices = (jsf & 64) != 0;
    if (re_data == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "RegExp method called on incompatible receiver");
        return;
    }

    // A non-global, non-sticky match always starts at 0 and leaves lastIndex
    // alone, however large the value read above.
    int start_pos = 0;
    if (global_flag || sticky_flag) {
        long li_charunit = (long)li_d;
        uint str_charlen = s_hstr.unit_len();
        if (li_charunit < 0 || (ulong)li_charunit > (ulong)str_charlen) {
            TVal zero_tv; zero_tv.set_fastint(0);
            if (!regexp_set_last_index(ctx, rx, li_key, zero_tv)) return;
            if (boolean_result) { ctx.result_boolean(false); }
            else { ctx.result_null(); }
            return;
        }
        start_pos = (int)li_charunit;
    }

    int[2 * re_bindings::RE_MAX_CAPTURES] caps @noinit;
    int result = regexp_run(ctx, re_data, s_hstr, start_pos, &caps, caps.len);
    if (ctx.should_throw) return;
    if (result != re_bindings::RE_MATCH) {
        if (global_flag || sticky_flag) {
            TVal zero_tv; zero_tv.set_fastint(0);
            if (!regexp_set_last_index(ctx, rx, li_key, zero_tv)) return;
        }
        if (boolean_result) { ctx.result_boolean(false); }
        else { ctx.result_null(); }
        return;
    }

    if (global_flag || sticky_flag) {
        // ECMA-262 §21.2.5.2.2 step 16: lastIndex = e (end of match) as a
        // UTF-16 code unit index. For empty matches (e == matchStart) the
        // AdvanceStringIndex step is performed by the *caller* (@@match step
        // 8.g, @@replace step 11.d) so that custom exec overrides are also
        // covered. Do NOT advance here.
        TVal end_tv; end_tv.set_fastint((long)caps[1]);
        if (!regexp_set_last_index(ctx, rx, li_key, end_tv)) return;
    }

    if (boolean_result) {
        ctx.result_boolean(true);
        return;
    }

    HObject* arr = regexp_match_array(ctx.heap, re_data, s_hstr, &caps, has_indices);
    if (arr == null) {
        ctx.result_null();
        return;
    }
    ctx.result_object(arr);
    return;
}

// RegExp.prototype.flags, ECMA-262 §21.2.5.7
// Returns a string of flags in alphabetical order: "dgimsuy".
// ECMA-262 §22.2.3.4: walks the receiver for each individual flag via
// Get + ToBoolean, so user-overridden `this.global`, `this.sticky`, etc.
// are honored. Any Object is a valid receiver (only primitives throw).
fn void builtin_regexp_proto_get_flags(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object() || ctx.this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "RegExp.prototype.flags called on incompatible receiver");
        return;
    }
    HObject* rx = (HObject*)ctx.this_val.get_heapptr();
    char[8] buf;
    int pos = 0;
    // hasIndices
    HString* hi_key = ctx.heap.str(heap::BuiltinStr.HAS_INDICES);
    TVal? hi_opt = builtins_generic_get(rx, hi_key, ctx);
    if (ctx.should_throw) return;
    if (try hv = hi_opt) {
        if (builtin_to_boolean(&hv)) buf[pos++] = 'd';
    }
    // global
    HString* g_key = ctx.heap.str(heap::BuiltinStr.GLOBAL);
    TVal? g_opt = builtins_generic_get(rx, g_key, ctx);
    if (ctx.should_throw) return;
    if (try gv = g_opt) {
        if (builtin_to_boolean(&gv)) buf[pos++] = 'g';
    }
    // ignoreCase
    HString* i_key = ctx.heap.str(heap::BuiltinStr.IGNORE_CASE);
    TVal? i_opt = builtins_generic_get(rx, i_key, ctx);
    if (ctx.should_throw) return;
    if (try iv = i_opt) {
        if (builtin_to_boolean(&iv)) buf[pos++] = 'i';
    }
    // multiline
    HString* m_key = ctx.heap.str(heap::BuiltinStr.MULTILINE);
    TVal? m_opt = builtins_generic_get(rx, m_key, ctx);
    if (ctx.should_throw) return;
    if (try mv = m_opt) {
        if (builtin_to_boolean(&mv)) buf[pos++] = 'm';
    }
    // dotAll
    HString* s_key = ctx.heap.str(heap::BuiltinStr.DOT_ALL);
    TVal? s_opt = builtins_generic_get(rx, s_key, ctx);
    if (ctx.should_throw) return;
    if (try sv = s_opt) {
        if (builtin_to_boolean(&sv)) buf[pos++] = 's';
    }
    // unicode
    HString* u_key = ctx.heap.str(heap::BuiltinStr.UNICODE);
    TVal? u_opt = builtins_generic_get(rx, u_key, ctx);
    if (ctx.should_throw) return;
    if (try uv = u_opt) {
        if (builtin_to_boolean(&uv)) buf[pos++] = 'u';
    }
    // unicodeSets
    HString* v_key = ctx.heap.str(heap::BuiltinStr.UNICODE_SETS);
    TVal? v_opt = builtins_generic_get(rx, v_key, ctx);
    if (ctx.should_throw) return;
    if (try vv = v_opt) {
        if (builtin_to_boolean(&vv)) buf[pos++] = 'v';
    }
    // sticky
    HString* y_key = ctx.heap.str(heap::BuiltinStr.STICKY);
    TVal? y_opt = builtins_generic_get(rx, y_key, ctx);
    if (ctx.should_throw) return;
    if (try yv = y_opt) {
        if (builtin_to_boolean(&yv)) buf[pos++] = 'y';
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:pos]);
    ctx.result_string(result);
}

// EscapeRegExpPattern, ECMA-262 §21.2.3.2.4
// Appends `src` to `out` with `/` and line terminators (LF, CR, LS, PS)
// escaped, so it can be embedded in a RegExpLiteral.
fn void regexp_escape_pattern(UnitBuf* out, HString* src) {
    uint len = src.unit_len();
    // ECMA-262 §21.2.3.2.4 step 2: if srcLength = 0, return "(?:)".
    if (len == 0) {
        out.append_latin1("(?:)");
        return;
    }
    bool in_class = false;
    for (uint si = 0; si < len; si++) {
        uint c = src.unit_at(si);
        // A raw LineTerminator can never appear literally inside a
        // RegularExpressionLiteral, so it is escaped, and a backslash right
        // before one is dropped: the spec operates on the pattern's characters
        // with no notion of "already escaped".
        uint at = c == '\\' && si + 1 < len && regexp_is_line_terminator(src.unit_at(si + 1)) ? si + 1 : si;
        uint unit = src.unit_at(at);
        if (regexp_is_line_terminator(unit)) {
            regexp_append_line_terminator(out, unit);
            si = at;
        } else if (c == '\\' && si + 1 < len) {
            // An escape pair is copied verbatim: it keeps an existing `\/` and
            // stops an escaped `[` or `]` from being taken for a class delimiter.
            out.append_unit(c);
            out.append_unit(src.unit_at(si + 1));
            si++;
        } else if (c == '/' && !in_class) {
            out.append_latin1("\\/");
        } else {
            if (c == '[') in_class = true;
            if (c == ']') in_class = false;
            out.append_unit(c);
        }
    }
}

fn bool regexp_is_line_terminator(uint unit) @inline {
    return unit == '\n' || unit == '\r' || unit == 0x2028 || unit == 0x2029;
}

// Append the escape for the raw LineTerminator `unit`: backslash-n or
// backslash-r for LF/CR, a six-character backslash-u escape for LS/PS.
fn void regexp_append_line_terminator(UnitBuf* out, uint unit) {
    switch (unit) {
        case '\n': out.append_latin1("\\n");
        case '\r': out.append_latin1("\\r");
        default: out.append_latin1(unit == 0x2029 ? "\\u2029" : "\\u2028");
    }
}

// The escaped source of a RegExp pattern as a string; null with a RangeError
// pending when the result is too long.
fn HString* regexp_escaped_source(BuiltinContext* ctx, HString* src) {
    UnitBuf out;
    out.init(ctx.heap);
    defer out.free();
    regexp_escape_pattern(&out, src);
    return out.to_hstring(ctx);
}

// RegExp.prototype.source, ECMA-262 §21.2.5.10
fn void builtin_regexp_proto_get_source(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    // ECMA-262 §21.2.5.10 step 3: if SameValue(R, %RegExpPrototype%), return "(?:)".
    if (this_r.is_proto) {
        ctx.result_string(builtin_intern_string(ctx.heap, "(?:)"));
        return;
    }
    HObject* obj = this_r.obj;
    if ((*obj.extra_ptr()).prim.primitive_value.is_string() && (*obj.extra_ptr()).prim.primitive_value.get_heapptr() != null) {
        HString* phs = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        HString* escaped = regexp_escaped_source(ctx, phs);
        if (escaped != null) ctx.result_string(escaped);
    } else {
        ctx.result_string(builtin_intern_string(ctx.heap, "(?:)"));
    }
}

// RegExp.prototype.global, ECMA-262 §21.2.5.1
fn void builtin_regexp_proto_get_global(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result_undefined(); return; }
    ctx.result_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 1) != 0);
}

// RegExp.prototype.ignoreCase, ECMA-262 §21.2.5.3
fn void builtin_regexp_proto_get_ignoreCase(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result_undefined(); return; }
    ctx.result_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 2) != 0);
}

// RegExp.prototype.multiline, ECMA-262 §21.2.5.5
fn void builtin_regexp_proto_get_multiline(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result_undefined(); return; }
    ctx.result_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 4) != 0);
}

// RegExp.prototype.dotAll, ECMA-262 §21.2.5.2
fn void builtin_regexp_proto_get_dotAll(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result_undefined(); return; }
    ctx.result_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 8) != 0);
}

// RegExp.prototype.sticky, ECMA-262 §21.2.5.14
fn void builtin_regexp_proto_get_sticky(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result_undefined(); return; }
    ctx.result_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 32) != 0);
}

// RegExp.prototype.unicode, ECMA-262 §21.2.5.16
fn void builtin_regexp_proto_get_unicode(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result_undefined(); return; }
    ctx.result_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 16) != 0);
}

// RegExp.prototype.hasIndices, ECMA-262 §21.2.5.8
fn void builtin_regexp_proto_get_hasIndices(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result_undefined(); return; }
    ctx.result_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 64) != 0);
}

// RegExp.prototype.unicodeSets, ECMA-262 §21.2.5.17
fn void builtin_regexp_proto_get_unicodeSets(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result_undefined(); return; }
    ctx.result_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 128) != 0);
}

// ============================================================================
// RegExp constructor registration
// ============================================================================

// RegExp[@@species] getter, ECMA-262 §21.2.4.2
// Returns the this value (the constructor itself).
fn void builtin_regexp_species_getter(BuiltinContext* ctx) {
    ctx.copy_result(ctx.regs[ctx.base_reg - 1]);
}

// Append two lowercase hex digits for a byte value (0-0xFF) to `buf` at `*len`.
fn void re_escape_append_hex2(char* buf, usz* len, uint byte_val) @inline {
    char[16] hex_digits = "0123456789abcdef";
    buf[(*len)++] = hex_digits[(byte_val >> 4) & 0xF];
    buf[(*len)++] = hex_digits[byte_val & 0xF];
}

// Append `\xHH` (byte_val <= 0xFF) to `buf` at `*len`.
fn void re_escape_append_x(char* buf, usz* len, uint byte_val) @inline {
    buf[(*len)++] = '\\';
    buf[(*len)++] = 'x';
    re_escape_append_hex2(buf, len, byte_val);
}

// Append `\uHHHH` (a UTF-16 code unit) to `buf` at `*len`.
fn void re_escape_append_u(char* buf, usz* len, uint code_unit) @inline {
    buf[(*len)++] = '\\';
    buf[(*len)++] = 'u';
    re_escape_append_hex2(buf, len, (code_unit >> 8) & 0xFF);
    re_escape_append_hex2(buf, len, code_unit & 0xFF);
}

// EncodeForRegExpEscape ( c ), ECMA-262.
// Appends the escaped representation of code point `cp` to `buf` at `*len`.
// `buf` must have at least 12 bytes of headroom (worst case: astral
// codepoint needing two \uHHHH escapes).
fn void re_escape_encode_codepoint(char* buf, usz* len, uint cp) {
    // SyntaxCharacter or U+002F (SOLIDUS): backslash + the character itself.
    switch (cp) {
        case '^': case '$': case '\\': case '.': case '*': case '+':
        case '?': case '(': case ')': case '[': case ']': case '{':
        case '}': case '|': case '/':
            buf[(*len)++] = '\\';
            *len += hstring::encode_codepoint_cesu8(cp, buf[*len : 6]);
            return;
        default: break;
    }

    // ControlEscape table (ECMA-262 Table 63).
    switch (cp) {
        case 0x09: buf[(*len)++] = '\\'; buf[(*len)++] = 't'; return;
        case 0x0A: buf[(*len)++] = '\\'; buf[(*len)++] = 'n'; return;
        case 0x0B: buf[(*len)++] = '\\'; buf[(*len)++] = 'v'; return;
        case 0x0C: buf[(*len)++] = '\\'; buf[(*len)++] = 'f'; return;
        case 0x0D: buf[(*len)++] = '\\'; buf[(*len)++] = 'r'; return;
        default: break;
    }

    // otherPunctuators, WhiteSpace, LineTerminator, or surrogate code point.
    bool needs_escape = false;
    switch (cp) {
        case 0x2C: case 0x2D: case 0x3D: case 0x3C: case 0x3E: case 0x23:
        case 0x26: case 0x21: case 0x25: case 0x3A: case 0x3B: case 0x40:
        case 0x7E: case 0x27: case 0x60: case 0x22:
            needs_escape = true;
        default: break;
    }
    if (!needs_escape) {
        // WhiteSpace (ES §12.2, incl. <USP> = Unicode Zs category) and
        // LineTerminator (ES §12.3) code points.
        switch (cp) {
            case 0x09: case 0x0B: case 0x0C: case 0x20: case 0xA0: case 0xFEFF:
            case 0x1680: case 0x2000: case 0x2001: case 0x2002: case 0x2003:
            case 0x2004: case 0x2005: case 0x2006: case 0x2007: case 0x2008:
            case 0x2009: case 0x200A: case 0x202F: case 0x205F: case 0x3000:
            case 0x0A: case 0x0D: case 0x2028: case 0x2029:
                needs_escape = true;
            default: break;
        }
    }
    if (!needs_escape && hstring::is_surrogate(cp)) needs_escape = true;

    if (needs_escape) {
        if (cp <= 0xFF) {
            re_escape_append_x(buf, len, cp);
        } else if (cp >= hstring::ASTRAL_START) {
            uint high; uint low;
            hstring::codepoint_to_surrogates(cp, &high, &low);
            re_escape_append_u(buf, len, high);
            re_escape_append_u(buf, len, low);
        } else {
            re_escape_append_u(buf, len, cp);
        }
        return;
    }

    // Otherwise: the code point itself (UTF16EncodeCodePoint).
    *len += hstring::encode_codepoint_cesu8(cp, buf[*len : 6]);
}

// RegExp.escape ( string ), ECMA-262.
// Escapes `string` for literal use inside a regular expression Pattern.
fn void builtin_regexp_escape(BuiltinContext* ctx) {
    if (ctx.argc < 1 || !ctx.regs[ctx.base_reg].is_string() || ctx.regs[ctx.base_reg].get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "RegExp.escape called on non-string");
        return;
    }
    HString* s = (HString*)ctx.regs[ctx.base_reg].get_heapptr();
    usz cap = (usz)s.unit_len() * 6 + 16;
    char* buf = (char*)alloc::malloc_try(mem, (sz)cap) ?? null;
    if (buf == null) { ctx.result_undefined(); return; }
    usz len = 0;

    uint n = s.unit_len();
    uint offset = 0;
    bool first = true;
    while (offset < n) {
        uint cp = s.unit_at(offset);
        uint step = 1;
        // Combine a high surrogate immediately followed by a low surrogate
        // into its astral code point (StringToCodePoints semantics).
        if (hstring::is_high_surrogate(cp) && offset + 1 < n && hstring::is_low_surrogate(s.unit_at(offset + 1))) {
            cp = hstring::surrogates_to_codepoint(cp, s.unit_at(offset + 1));
            step = 2;
        }

        bool leading_digit_or_letter = first &&
            ((cp >= '0' && cp <= '9') ||
             (cp >= 'a' && cp <= 'z') ||
             (cp >= 'A' && cp <= 'Z'));
        if (leading_digit_or_letter) {
            re_escape_append_x(buf, &len, cp);
        } else {
            re_escape_encode_codepoint(buf, &len, cp);
        }
        first = false;
        offset += step;
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    mem::free(buf);
    if (result == null) { ctx.result_undefined(); return; }
    ctx.result_string(result);
}

// Register RegExp.prototype and the RegExp constructor globally.
fn bool register_regexp_constructor(EnvRecord* global_env, Heap* heap) {
    // Create RegExp.prototype (ObjClass.OBJECT per spec, toString gives [object Object])
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    heap.set_prototype(proto, heap.object_proto);
    heap.regexp_proto = proto;
    // Before any store cache can describe it; see regexp_guard_arm.
    proto.gc.watched = true;

    {
        const uint[*] METHODS = {
            Builtin.REGEXP_PROTO_TEST.ordinal,
            Builtin.REGEXP_PROTO_EXEC.ordinal,
            Builtin.REGEXP_PROTO_TOSTRING.ordinal,
            Builtin.REGEXP_PROTO_COMPILE.ordinal,
        };
        if (!register_builtin_members(proto, heap, METHODS[..])) return false;
    }

    // Add RegExp.prototype accessor getters (ECMA-262 §21.2.5)
    if (!register_get_accessor(proto, heap, "flags", Builtin.REGEXP_PROTO_GET_FLAGS.ordinal)) return false;
    if (!register_get_accessor(proto, heap, "source", Builtin.REGEXP_PROTO_GET_SOURCE.ordinal)) return false;
    if (!register_get_accessor(proto, heap, "global", Builtin.REGEXP_PROTO_GET_GLOBAL.ordinal)) return false;
    if (!register_get_accessor(proto, heap, "ignoreCase", Builtin.REGEXP_PROTO_GET_IGNORECASE.ordinal)) return false;
    if (!register_get_accessor(proto, heap, "multiline", Builtin.REGEXP_PROTO_GET_MULTILINE.ordinal)) return false;
    if (!register_get_accessor(proto, heap, "dotAll", Builtin.REGEXP_PROTO_GET_DOTALL.ordinal)) return false;
    if (!register_get_accessor(proto, heap, "sticky", Builtin.REGEXP_PROTO_GET_STICKY.ordinal)) return false;
    if (!register_get_accessor(proto, heap, "unicode", Builtin.REGEXP_PROTO_GET_UNICODE.ordinal)) return false;
    if (!register_get_accessor(proto, heap, "hasIndices", Builtin.REGEXP_PROTO_GET_HASINDICES.ordinal)) return false;
    if (!register_get_accessor(proto, heap, "unicodeSets", Builtin.REGEXP_PROTO_GET_UNICODESETS.ordinal)) return false;

    // Register RegExp.prototype[@@match] (ECMA-262 §21.2.5.6)
    {
        HString* match_sym = ensure_match_symbol(heap);
        if (match_sym != null) {
            TVal match_fn;
            match_fn.set_builtin(heap, Builtin.REGEXP_PROTO_SYMBOL_MATCH.ordinal);
            proto.put_prop(match_sym, match_fn, hobject::PROP_FLAGS_WC, heap);
        }
    }

    // Register RegExp.prototype[@@search] (ECMA-262 §21.2.5.9)
    {
        HString* search_sym = ensure_search_symbol(heap);
        if (search_sym != null) {
            TVal search_fn;
            search_fn.set_builtin(heap, Builtin.REGEXP_PROTO_SYMBOL_SEARCH.ordinal);
            proto.put_prop(search_sym, search_fn, hobject::PROP_FLAGS_WC, heap);
        }
    }

    // Register RegExp.prototype[@@replace] (ECMA-262 §21.2.5.8)
    {
        HString* replace_sym = ensure_replace_symbol(heap);
        if (replace_sym != null) {
            TVal replace_fn;
            replace_fn.set_builtin(heap, Builtin.REGEXP_PROTO_SYMBOL_REPLACE.ordinal);
            proto.put_prop(replace_sym, replace_fn, hobject::PROP_FLAGS_WC, heap);
        }
    }

    // Register RegExp.prototype[@@split] (ECMA-262 §21.2.5.11)
    {
        HString* split_sym = ensure_split_symbol(heap);
        if (split_sym != null) {
            TVal split_fn;
            split_fn.set_builtin(heap, Builtin.REGEXP_PROTO_SYMBOL_SPLIT.ordinal);
            proto.put_prop(split_sym, split_fn, hobject::PROP_FLAGS_WC, heap);
        }
    }

    // Register RegExp.prototype[@@matchAll] (ECMA-262 §21.2.5.8), stub.
    // Full implementation returns a generator; tests for the property
    // descriptors (length, name, prop-desc) need only that the function
    // exists at all.
    {
        HString* matchall_sym = ensure_matchall_symbol(heap);
        if (matchall_sym != null) {
            TVal matchall_fn;
            matchall_fn.set_builtin(heap, Builtin.REGEXP_PROTO_SYMBOL_MATCHALL.ordinal);
            proto.put_prop(matchall_sym, matchall_fn, hobject::PROP_FLAGS_WC, heap);
        }
    }

    // Register RegExp as a global constructor (proper function object)
    HObject*? regexp_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = regexp_raw) return false;
    HObject* regexp_obj = regexp_raw;
    (*regexp_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.REGEXP.ordinal;

    // Set .constructor on RegExp.prototype to the actual constructor object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(regexp_obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    // Set RegExp.prototype on the constructor
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    regexp_obj.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    // Set RegExp.length (ECMA-262 §15.10.5)
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv;
    len_tv.set_fastint(2);
    regexp_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC, heap);

    // Add @@species accessor (ECMA-262 §21.2.4.2): getter returns `this`.
    HString* species_sym = ensure_species_symbol(heap);
    if (species_sym != null) {
        HObject*? getter_fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try getter_fn = getter_fn_raw) {
            (*getter_fn.extra_ptr()).func.builtin_fn_index = (int)Builtin.REGEXP_SPECIES_GETTER.ordinal;
            getter_fn.flags.callable = true;
            heap.set_prototype(getter_fn, heap.function_proto);
            // Set .name = "get [Symbol.species]"
            HString* getter_name = builtin_intern_string(heap, "get [Symbol.species]");
            if (getter_name != null) {
                TVal name_tv; name_tv.set_string_borrowed(getter_name);
                getter_fn.put_prop((void*)heap.str(heap::BuiltinStr.NAME), name_tv, hobject::PROP_FLAGS_NWC, heap);
            }
            // Set .length = 0
            TVal zero_tv; zero_tv.set_fastint(0);
            getter_fn.put_prop(len_key, zero_tv, hobject::PROP_FLAGS_NWC, heap);

            TVal getter_tv; getter_tv.set_object(getter_fn);
            TVal undef; undef.set_undefined();
            hobject::PropFlags acc_flags;
            acc_flags.writable = false;
            acc_flags.enumerable = false;
            acc_flags.configurable = true;
            acc_flags.is_accessor = true;
            regexp_obj.put_prop(species_sym, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags, heap);
        }
    }

    // Add RegExp.escape (ECMA-262)
    if (!register_proto_method(regexp_obj, heap, "escape", Builtin.REGEXP_ESCAPE.ordinal)) return false;

    // Register RegExp constructor globally as an OBJECT
    HString* regexp_key = heap.str_intern("RegExp");
    if (regexp_key == null) return false;
    TVal regexp_val;
    regexp_val.set_object(regexp_obj);
    set_func_ctor_name(regexp_obj, heap, "RegExp");
    env::env_declare_nonenum(global_env, regexp_key, regexp_val);

    return true;
}

// Run `re` over the units of `s` from unit `start_offset`; every offset in and
// out is a unit offset.
fn int regexp_run(BuiltinContext* ctx, void* re, HString* s, int start_offset, int* caps, int cap_slots) {
    re_bindings::ReInterrupt interrupt = { &heap::regexp_interrupt, ctx.heap };
    int result = re_bindings::re_run_direct(re, s.data_ptr(), s.unit_len(), s.is_wide(), (uint)start_offset,
        caps, cap_slots, &interrupt);
    if (ctx.heap.uncatchable_throw) builtin_throw(ctx, ctx.heap.err_proto, "interrupted");
    return result;
}
