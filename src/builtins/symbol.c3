/// Symbol constructor, global registry, and well-known symbols.
module duktape::builtins;
import duktape::types;
import duktape::env;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;

// ============================================================================
// Symbol helpers
// ============================================================================

/// Symbol creation counter — incremented for each unique symbol to guarantee
/// uniqueness even with identical descriptions.
uint g_symbol_counter = 0;

/// Create a new Symbol HString with 0xFF prefix byte.
/// Symbols are NOT inserted into the string table (they are unique).
///
/// `has_desc` distinguishes `Symbol()` (no description, ES2019 §19.4.3.5
/// returns undefined) from `Symbol("")` (an explicit empty-string
/// description) — both would otherwise encode identically as a bare 0xFF
/// byte. When true, a 0x01 marker byte follows the 0xFF prefix, ahead of
/// the (possibly zero-length) description bytes; symbol_description/
/// symbol_has_description read it back. 0x01 can never collide with the
/// 0xFF second byte that marks hidden symbols.
fn HString* create_symbol_string(Heap* heap, char[] desc, bool has_desc = true) {
    // Build internal representation: 0xFF [0x01 marker if has_desc] + description
    // We add a counter suffix for uniqueness when description is empty
    uint counter = g_symbol_counter;
    g_symbol_counter++;

    char[256] buf;
    buf[0] = (char)0xFF;
    int pos = 1;
    if (has_desc) {
        buf[pos] = (char)0x01;
        pos++;
    }

    for (int i = 0; i < desc.len && pos < 255; i++) {
        buf[pos] = desc[i];
        pos++;
    }

    uint hash = heap.hash_seed ^ counter;  // Simple unique hash

    HString*? sym = hstring::hstring_alloc(heap, buf[:(uint)pos], hash);
    if (try s = sym) {
        // Don't intern in string table — symbols are unique
        return s;
    }
    return null;
}

/// Create a new hidden Symbol HString with 0xFF 0xFF prefix.
/// Hidden symbols back private class members: hstring_alloc's prefix
/// detection sets is_symbol + is_hidden automatically, and enumeration
/// paths filter them out. NOT inserted into the string table (unique).
fn HString* create_hidden_symbol(Heap* heap, char[] desc) {
    uint counter = g_symbol_counter;
    g_symbol_counter++;

    char[256] buf;
    buf[0] = (char)0xFF;
    buf[1] = (char)0xFF;
    int pos = 2;

    for (int i = 0; i < desc.len && pos < 255; i++) {
        buf[pos] = desc[i];
        pos++;
    }

    uint hash = heap.hash_seed ^ counter;  // Simple unique hash

    HString*? sym = hstring::hstring_alloc(heap, buf[:(uint)pos], hash);
    if (try s = sym) {
        // Don't intern in string table — hidden symbols are unique
        return s;
    }
    return null;
}

/// Check if a TVal is a Symbol (STRING tag with is_symbol flag)
fn bool is_symbol_val(TVal val) {
    if (!val.is_string()) return false;
    HString* s = (HString*)val.get_heapptr();
    return s != null && s.is_symbol();
}

/// True if the Symbol was created with an explicit description (even an
/// empty string), as opposed to `Symbol()` / `Symbol(undefined)` which has
/// no description at all. See create_symbol_string for the encoding.
fn bool symbol_has_description(HString* sym) {
    if (sym.blen <= 1) return false;
    char* ptr = sym.get_cstr();
    return (uint)(char)ptr[1] == 0x01;
}

/// Get the description bytes of a Symbol (everything after the 0xFF prefix
/// and, if present, the has-description marker byte).
fn char[] symbol_description(HString* sym) {
    if (sym.blen <= 1) return "";
    char* ptr = sym.get_cstr();
    if (symbol_has_description(sym)) {
        if (sym.blen <= 2) return "";
        return ptr[2:(sz)(sym.blen - 2)];
    }
    return ptr[1:(sz)(sym.blen - 1)];
}

// ============================================================================
// Symbol global registry (Symbol.for / Symbol.keyFor)
// ============================================================================

/// Look up a key in the global symbol registry.
/// Returns the registered symbol HString*, or null if not found.
fn HString* symbol_registry_get(Heap* heap, char[] key) {
    for (uint i = 0; i < heap.symbol_registry_count; i++) {
        HString* reg_key = heap.symbol_registry_keys[i];
        if (reg_key.blen == (uint)key.len) {
            char* reg_data = reg_key.get_cstr();
            bool match = true;
            for (int j = 0; j < key.len; j++) {
                if (reg_data[j] != key[j]) { match = false; break; }
            }
            if (match) return heap.symbol_registry_syms[i];
        }
    }
    return null;
}

/// Register a key→symbol pair in the global registry.
fn bool symbol_registry_put(Heap* heap, char[] key, HString* sym) {
    uint count = heap.symbol_registry_count;
    uint cap = heap.symbol_registry_cap;

    // Grow if needed
    if (count >= cap) {
        uint new_cap = (cap == 0) ? 8 : cap * 2;
        usz key_bytes = (usz)new_cap * void*::size;
        usz sym_bytes = (usz)new_cap * void*::size;

        HString** new_keys = (HString**)heap.alloc_func(heap.heap_udata, key_bytes);
        HString** new_syms = (HString**)heap.alloc_func(heap.heap_udata, sym_bytes);
        if (new_keys == null || new_syms == null) return false;

        // Copy existing entries
        for (uint i = 0; i < count; i++) {
            new_keys[i] = heap.symbol_registry_keys[i];
            new_syms[i] = heap.symbol_registry_syms[i];
        }
        // Free old arrays
        if (heap.symbol_registry_keys != null) {
            heap.free_func(heap.heap_udata, heap.symbol_registry_keys);
        }
        if (heap.symbol_registry_syms != null) {
            heap.free_func(heap.heap_udata, heap.symbol_registry_syms);
        }
        heap.symbol_registry_keys = new_keys;
        heap.symbol_registry_syms = new_syms;
        heap.symbol_registry_cap = new_cap;
    }

    // Allocate a key HString (interned)
    uint hash = heap.hash_string(key);
    HString* existing = heap.str_table_lookup(key, hash);
    HString* key_str;
    if (existing != null) {
        key_str = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, key, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key_str = new_key;
    }

    heap.symbol_registry_keys[count] = key_str;
    heap.symbol_registry_syms[count] = sym;
    heap.symbol_registry_count = count + 1;
    // Hold refs: registry owns a reference to both key and symbol strings.
    ((types::HeapHeader*)key_str).incref();
    ((types::HeapHeader*)sym).incref();
    return true;
}

/// Reverse lookup: find key for a symbol in the registry.
fn HString* symbol_registry_get_key(Heap* heap, HString* sym) {
    for (uint i = 0; i < heap.symbol_registry_count; i++) {
        if (heap.symbol_registry_syms[i] == sym) {
            return heap.symbol_registry_keys[i];
        }
    }
    return null;
}

/// Ensure the well-known @@toStringTag symbol exists.
/// Returns the symbol HString* (usable as a property key).
/// Well-known symbols are NOT in the global symbol registry per ES2020 §19.4 —
/// only symbols created by Symbol.for live there. Heap-level cache keeps it
/// unique across the engine.
fn HString* ensure_tostringtag_symbol(Heap* heap) {
    if (heap.tostringtag_symbol != null) return heap.tostringtag_symbol;
    char[] desc = "Symbol.toStringTag";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.tostringtag_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@iterator symbol exists.
/// Returns the symbol HString* (usable as a property key).
/// Well-known symbols are NOT added to the global symbol registry per ES2020
/// §19.4 (the registry only contains symbols created by Symbol.for); the
/// heap-level cache (heap.iterator_symbol) is sufficient to keep them unique.
fn HString* ensure_iterator_symbol(Heap* heap) {
    // Fast path: already cached on the heap
    if (heap.iterator_symbol != null) return heap.iterator_symbol;
    char[] desc = "Symbol.iterator";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.iterator_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@toPrimitive symbol exists.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_toprimitive_symbol(Heap* heap) {
    if (heap.toprimitive_symbol != null) return heap.toprimitive_symbol;
    char[] desc = "Symbol.toPrimitive";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.toprimitive_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@isConcatSpreadable symbol exists.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_concatspreadable_symbol(Heap* heap) {
    if (heap.concatspreadable_symbol != null) return heap.concatspreadable_symbol;
    char[] desc = "Symbol.isConcatSpreadable";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.concatspreadable_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@hasInstance symbol exists.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_hasinstance_symbol(Heap* heap) {
    if (heap.hasinstance_symbol != null) return heap.hasinstance_symbol;
    char[] desc = "Symbol.hasInstance";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.hasinstance_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@match symbol exists.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_match_symbol(Heap* heap) {
    if (heap.match_symbol != null) return heap.match_symbol;
    char[] desc = "Symbol.match";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.match_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@search symbol exists.
fn HString* ensure_search_symbol(Heap* heap) {
    if (heap.search_symbol != null) return heap.search_symbol;
    char[] desc = "Symbol.search";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.search_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@replace symbol exists.
fn HString* ensure_replace_symbol(Heap* heap) {
    if (heap.replace_symbol != null) return heap.replace_symbol;
    char[] desc = "Symbol.replace";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.replace_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@split symbol exists.
fn HString* ensure_split_symbol(Heap* heap) {
    if (heap.split_symbol != null) return heap.split_symbol;
    char[] desc = "Symbol.split";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.split_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@species symbol exists.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_species_symbol(Heap* heap) {
    if (heap.species_symbol != null) return heap.species_symbol;
    char[] desc = "Symbol.species";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.species_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@unscopables symbol exists.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_unscopables_symbol(Heap* heap) {
    if (heap.unscopables_symbol != null) return heap.unscopables_symbol;
    char[] desc = "Symbol.unscopables";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.unscopables_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@matchAll symbol exists.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_matchall_symbol(Heap* heap) {
    if (heap.matchall_symbol != null) return heap.matchall_symbol;
    char[] desc = "Symbol.matchAll";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.matchall_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@asyncIterator symbol exists.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_asynciterator_symbol(Heap* heap) {
    if (heap.asynciterator_symbol != null) return heap.asynciterator_symbol;
    char[] desc = "Symbol.asyncIterator";
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    heap.asynciterator_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

// ============================================================================
// Symbol constructor (ES6 §19.4.1)
// ============================================================================
fn void builtin_symbol(BuiltinContext* ctx) {
    // Symbol is not constructable with new
    if (ctx.is_constructor) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Symbol is not a constructor");
        return;
    }

    // Get description from first argument (ToString if present). Per ES2019
    // §19.4.1.1, `description` is undefined — and the Symbol has NO
    // description — both when omitted and when explicitly passed `undefined`.
    // ToString(symbol) must throw TypeError (desc-to-string-symbol.js), so use
    // the VM-aware variant which honors that and also routes object→ToPrimitive
    // through the VM so toString/valueOf can throw or return primitives.
    char[] desc = "";
    bool has_desc = false;
    if (ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal arg = ctx.regs[ctx.base_reg];
        HString* desc_str = builtin_to_string_vm(ctx, &arg);
        if (ctx.should_throw) return;  // ToString threw (e.g. Symbol arg)
        if (desc_str != null) {
            desc = desc_str.get_data();
        }
        has_desc = true;
    }

    HString* sym = create_symbol_string(ctx.heap, desc, has_desc);
    if (sym == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(sym);
}

// ============================================================================
// Symbol.for(key) — ES6 §19.4.2.1
// ============================================================================
fn void builtin_symbol_for(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }

    // ToString(key) — must throw TypeError for Symbol and propagate errors
    // from toString/valueOf (for/to-string-err.js, for/description.js).
    TVal key_val = ctx.regs[ctx.base_reg];
    HString* key_str = builtin_to_string_vm(ctx, &key_val);
    if (ctx.should_throw) return;
    if (key_str == null) {
        ctx.result.set_undefined();
        return;
    }

    char[] key_bytes = key_str.get_data();

    // Check registry
    HString* existing = symbol_registry_get(ctx.heap, key_bytes);
    if (existing != null) {
        ctx.result.set_string(existing);
        return;
    }

    // Create new global symbol
    HString* sym = create_symbol_string(ctx.heap, key_bytes);
    if (sym == null) {
        ctx.result.set_undefined();
        return;
    }

    symbol_registry_put(ctx.heap, key_bytes, sym);

    ctx.result.set_string(sym);
}

// ============================================================================
// Symbol.keyFor(sym) — ES6 §19.4.2.5
// ============================================================================
fn void builtin_symbol_keyfor(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }

    TVal sym_val = ctx.regs[ctx.base_reg];
    if (!is_symbol_val(sym_val)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Symbol.keyFor requires a symbol argument");
        return;
    }

    HString* sym = (HString*)sym_val.get_heapptr();
    HString* key = symbol_registry_get_key(ctx.heap, sym);
    if (key != null) {
        ctx.result.set_string(key);
    } else {
        ctx.result.set_undefined();
    }
}

/// Symbol.prototype.description getter — ES2019 §19.4.3.5
/// Returns the description string of the Symbol, or undefined.
fn void builtin_symbol_proto_description_get(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HString* sym = null;

    if (this_val.is_string()) {
        HString* s = (HString*)this_val.get_heapptr();
        if (s != null && s.is_symbol()) {
            sym = s;
        }
    } else if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.SYMBOL) {
            TVal prim = (*obj.extra_ptr()).prim.primitive_value;
            if (prim.is_string()) {
                HString* s = (HString*)prim.get_heapptr();
                if (s != null && s.is_symbol()) {
                    sym = s;
                }
            }
        }
    }

    if (sym == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Symbol.prototype.description requires that 'this' be a Symbol");
        return;
    }

    if (!symbol_has_description(sym)) {
        ctx.result.set_undefined();
        return;
    }
    char[] desc = symbol_description(sym);
    HString* result = ctx.heap.str_intern(desc);
    if (result == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(result);
}

// ============================================================================
// Symbol.prototype.toString() — ES6 §19.4.3.2
// ============================================================================
fn void builtin_symbol_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    // this value must be a Symbol (primitive or wrapper)
    HString* sym = null;
    if (this_val.is_string()) {
        HString* s = (HString*)this_val.get_heapptr();
        if (s != null && s.is_symbol()) {
            sym = s;
        }
    } else if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.SYMBOL) {
            // Extract [[SymbolData]] from primitive_value
            TVal prim = (*obj.extra_ptr()).prim.primitive_value;
            if (prim.is_string()) {
                HString* s = (HString*)prim.get_heapptr();
                if (s != null && s.is_symbol()) {
                    sym = s;
                }
            }
        }
    }

    if (sym == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Symbol.prototype.toString called on non-Symbol");
        return;
    }

    // Build "Symbol(description)" string
    char[] desc = symbol_description(sym);
    char[512] result_buf;
    result_buf[0] = 'S';
    result_buf[1] = 'y';
    result_buf[2] = 'm';
    result_buf[3] = 'b';
    result_buf[4] = 'o';
    result_buf[5] = 'l';
    result_buf[6] = '(';
    int pos = 7;
    for (int i = 0; i < desc.len && pos < 510; i++) {
        result_buf[pos] = desc[i];
        pos++;
    }
    result_buf[pos] = ')';
    pos++;
    result_buf[pos] = 0;

    HString* result = builtin_intern_string(ctx.heap, result_buf[:(uint)pos]);
    ctx.result.set_string(result);
}

// ============================================================================
// Symbol.prototype.data.valueOf() — ES6 §19.4.3.3
// ============================================================================
fn void builtin_symbol_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    if (this_val.is_string()) {
        HString* s = (HString*)this_val.get_heapptr();
        if (s != null && s.is_symbol()) {
            *ctx.result = this_val;
            return;
        }
    } else if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.SYMBOL) {
            // Return the [[SymbolData]] value from primitive_value
            TVal prim = (*obj.extra_ptr()).prim.primitive_value;
            if (prim.is_string()) {
                HString* s = (HString*)prim.get_heapptr();
                if (s != null && s.is_symbol()) {
                    *ctx.result = prim;
                    return;
                }
            }
        }
    }

    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Symbol.prototype.valueOf called on non-Symbol");
}

/// True if Symbol.prototype[Symbol.toPrimitive] is still the original
/// built-in method (not redefined/removed). Lets to_primitive_value's
/// Symbol-wrapper fast path (which unwraps directly, matching what this
/// method always does regardless of hint) confirm it's actually safe to
/// skip the call rather than assuming so unconditionally.
fn bool symbol_proto_toprimitive_is_original(Heap* heap) {
    if (heap.symbol_proto == null || heap.toprimitive_symbol == null) return false;
    TVal? val = heap.symbol_proto.get_prop_proto(heap.toprimitive_symbol);
    if (catch val) return false;
    TVal v = val;
    if (!v.is_object() || v.get_heapptr() == null) return false;
    HObject* fn_obj = (HObject*)v.get_heapptr();
    if (!fn_obj.is_callable()) return false;
    return (*fn_obj.extra_ptr()).func.builtin_fn_index == (int)Builtin.SYMBOL_PROTO_TOPRIMITIVE.ordinal;
}

// ============================================================================
// Symbol.prototype[Symbol.toPrimitive](hint) — ES6 §19.4.3.5
// ============================================================================
fn void builtin_symbol_proto_toprimitive(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    // 1. Let s be the this value.
    // 2. If Type(s) is Symbol, return s.
    // 3. If Type(s) is Object and s has a [[SymbolData]] internal slot,
    //    let s be s.[[SymbolData]].
    // 4. Throw a TypeError exception.
    if (this_val.is_string()) {
        HString* s = (HString*)this_val.get_heapptr();
        if (s != null && s.is_symbol()) {
            *ctx.result = this_val;
            return;
        }
    } else if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.SYMBOL) {
            TVal prim = (*obj.extra_ptr()).prim.primitive_value;
            if (prim.is_string()) {
                HString* s = (HString*)prim.get_heapptr();
                if (s != null && s.is_symbol()) {
                    *ctx.result = prim;
                    return;
                }
            }
        }
    }

    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Symbol.prototype[Symbol.toPrimitive] called on non-Symbol");
}

// ============================================================================
// Symbol constructor registration
// ============================================================================

fn bool register_symbol_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Symbol.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.SYMBOL);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.symbol_proto = proto;

    // Register prototype methods
    if (!register_string_proto_method(proto, heap, "toString", Builtin.SYMBOL_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.SYMBOL_PROTO_VALUEOF.ordinal)) return false;

    // Register Symbol.prototype[Symbol.toPrimitive] — ES6 §19.4.3.5
    // This is a function that returns the this value (the symbol itself).
    // Installed as a real function object (not a lightfunc) so it carries the
    // spec-mandated own `.name` = "[Symbol.toPrimitive]" and `.length` = 1
    // (§19.4.3.5: the property is {[[Writable]]:false,[[Enumerable]]:false,
    // [[Configurable]]:true}).
    {
        HString* toprim_key = ensure_toprimitive_symbol(heap);
        if (toprim_key != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.SYMBOL_PROTO_TOPRIMITIVE.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;

            HString* tp_name = builtin_intern_string(heap, "[Symbol.toPrimitive]");
            if (tp_name != null) {
                TVal name_tv;
                name_tv.set_string(tp_name);
                HString* name_key = builtin_intern_string(heap, "name");
                fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
            }
            HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            if (length_key != null) {
                TVal len_tv;
                len_tv.set_fastint(1);
                fn_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC);
            }

            TVal toprim_fn;
            toprim_fn.set_object(fn_obj);
            // §19.4.3.5: {[[Writable]]:false,[[Enumerable]]:false,[[Configurable]]:true}
            proto.put_prop(toprim_key, toprim_fn, hobject::PROP_FLAGS_NWC);
        }
    }

    // Set @@toStringTag on prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Symbol"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Register Symbol.prototype.description as a getter accessor (ES2019 §19.4.3.5)
    // Getter function returns the description string or undefined.
    {
        HString* desc_key = builtin_intern_string(heap, "description");
        if (desc_key != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.SYMBOL_PROTO_DESCRIPTION_GET.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;

            // Set .name = "get description"
            char[] fn_name = "get description";
            HString* name_str = builtin_intern_string(heap, fn_name);
            if (name_str != null) {
                TVal name_tv;
                name_tv.set_string(name_str);
                HString* name_key = builtin_intern_string(heap, "name");
                fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
            }
            // Set .length = 0
            HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            if (length_key != null) {
                TVal len_tv;
                len_tv.set_fastint(0);
                fn_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC);
            }

            TVal getter_tv;
            getter_tv.set_object(fn_obj);
            TVal undef;
            undef.set_undefined();
            hobject::PropFlags acc_flags;
            acc_flags.writable = false;
            acc_flags.enumerable = false;
            acc_flags.configurable = true;
            acc_flags.is_accessor = true;
            proto.put_prop(desc_key, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags);
        }
    }

    // Create Symbol function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.SYMBOL.ordinal;

    // Wire prototype.constructor → ctor
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Wire ctor.prototype → proto (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Symbol.length = 0
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    // Register Symbol.for as a property of the Symbol function
    HString* for_key = builtin_intern_string(heap, "for");
    TVal for_tv;
    for_tv.set_lightfunc((void*)(usz)Builtin.SYMBOL_FOR.ordinal);
    ctor.put_prop(for_key, for_tv, hobject::PROP_FLAGS_WC);

    // Register Symbol.keyFor as a property of the Symbol function
    HString* keyfor_key = builtin_intern_string(heap, "keyFor");
    TVal keyfor_tv;
    keyfor_tv.set_lightfunc((void*)(usz)Builtin.SYMBOL_KEYFOR.ordinal);
    ctor.put_prop(keyfor_key, keyfor_tv, hobject::PROP_FLAGS_WC);

    // Register Symbol.toStringTag as a well-known symbol property
    // Per ES6 §19.4.2.14: non-writable, non-enumerable, non-configurable
    HString* tostrtag_sym = ensure_tostringtag_symbol(heap);
    if (tostrtag_sym != null) {
        HString* tostrtag_key = builtin_intern_string(heap, "toStringTag");
        TVal tostrtag_val;
        tostrtag_val.set_string(tostrtag_sym);
        ctor.put_prop(tostrtag_key, tostrtag_val, hobject::PROP_FLAGS_NNC);
    }

    // Register Symbol.iterator as a well-known symbol property (non-writable, non-enumerable, non-configurable per ES6 §19.4.2.12)
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym != null) {
        HString* iter_key = builtin_intern_string(heap, "iterator");
        if (iter_key != null) {
            TVal iter_val;
            iter_val.set_string(iter_sym);
            ctor.put_prop(iter_key, iter_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register Symbol.toPrimitive as a well-known symbol property (non-writable, non-enumerable, non-configurable per ES6 §19.4.2.6)
    HString* toprim_sym = ensure_toprimitive_symbol(heap);
    if (toprim_sym != null) {
        HString* toprim_key = builtin_intern_string(heap, "toPrimitive");
        if (toprim_key != null) {
            TVal toprim_val;
            toprim_val.set_string(toprim_sym);
            ctor.put_prop(toprim_key, toprim_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register Symbol.isConcatSpreadable as a well-known symbol property
    // Per ES6 §19.4.2.3: non-writable, non-enumerable, non-configurable
    HString* concat_sym = ensure_concatspreadable_symbol(heap);
    if (concat_sym != null) {
        HString* concat_key = builtin_intern_string(heap, "isConcatSpreadable");
        if (concat_key != null) {
            TVal concat_val;
            concat_val.set_string(concat_sym);
            ctor.put_prop(concat_key, concat_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register Symbol.hasInstance as a well-known symbol property
    // Per ES6 §19.4.2.2: non-writable, non-enumerable, non-configurable
    HString* hasinst_sym = ensure_hasinstance_symbol(heap);
    if (hasinst_sym != null) {
        HString* hasinst_key = builtin_intern_string(heap, "hasInstance");
        if (hasinst_key != null) {
            TVal hasinst_val;
            hasinst_val.set_string(hasinst_sym);
            ctor.put_prop(hasinst_key, hasinst_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register Symbol.match as a well-known symbol property
    // Per ES6 §19.4.2.5: non-writable, non-enumerable, non-configurable
    HString* match_sym = ensure_match_symbol(heap);
    if (match_sym != null) {
        HString* match_key = builtin_intern_string(heap, "match");
        if (match_key != null) {
            TVal match_val;
            match_val.set_string(match_sym);
            ctor.put_prop(match_key, match_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register Symbol.search as a well-known symbol property
    // Per ES6 §19.4.2.8: non-writable, non-enumerable, non-configurable
    HString* search_sym = ensure_search_symbol(heap);
    if (search_sym != null) {
        HString* search_key = builtin_intern_string(heap, "search");
        if (search_key != null) {
            TVal search_val;
            search_val.set_string(search_sym);
            ctor.put_prop(search_key, search_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register Symbol.replace as a well-known symbol property
    // Per ES6 §19.4.2.7: non-writable, non-enumerable, non-configurable
    HString* replace_sym = ensure_replace_symbol(heap);
    if (replace_sym != null) {
        HString* replace_key = builtin_intern_string(heap, "replace");
        if (replace_key != null) {
            TVal replace_val;
            replace_val.set_string(replace_sym);
            ctor.put_prop(replace_key, replace_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register Symbol.split as a well-known symbol property
    // Per ES6 §19.4.2.11: non-writable, non-enumerable, non-configurable
    HString* split_sym = ensure_split_symbol(heap);
    if (split_sym != null) {
        HString* split_key = builtin_intern_string(heap, "split");
        if (split_key != null) {
            TVal split_val;
            split_val.set_string(split_sym);
            ctor.put_prop(split_key, split_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register Symbol.species as a well-known symbol property
    // Per ES6 §19.4.2.10: non-writable, non-enumerable, non-configurable
    HString* species_sym = ensure_species_symbol(heap);
    if (species_sym != null) {
        HString* species_key = builtin_intern_string(heap, "species");
        if (species_key != null) {
            TVal species_val;
            species_val.set_string(species_sym);
            ctor.put_prop(species_key, species_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register Symbol.unscopables as a well-known symbol property
    // Per ES6 §19.4.2.13: non-writable, non-enumerable, non-configurable
    HString* unscop_sym = ensure_unscopables_symbol(heap);
    if (unscop_sym != null) {
        HString* unscop_key = builtin_intern_string(heap, "unscopables");
        if (unscop_key != null) {
            TVal unscop_val;
            unscop_val.set_string(unscop_sym);
            ctor.put_prop(unscop_key, unscop_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register Symbol.matchAll as a well-known symbol property
    // Per ES2020 §19.4.2.9: non-writable, non-enumerable, non-configurable
    HString* matchall_sym = ensure_matchall_symbol(heap);
    if (matchall_sym != null) {
        HString* matchall_key = builtin_intern_string(heap, "matchAll");
        if (matchall_key != null) {
            TVal matchall_val;
            matchall_val.set_string(matchall_sym);
            ctor.put_prop(matchall_key, matchall_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register Symbol.asyncIterator as a well-known symbol property
    // Per ES2018 §19.4.2.4: non-writable, non-enumerable, non-configurable
    HString* asynciter_sym = ensure_asynciterator_symbol(heap);
    if (asynciter_sym != null) {
        HString* asynciter_key = builtin_intern_string(heap, "asyncIterator");
        if (asynciter_key != null) {
            TVal asynciter_val;
            asynciter_val.set_string(asynciter_sym);
            ctor.put_prop(asynciter_key, asynciter_val, hobject::PROP_FLAGS_NNC);
        }
    }

    // Register "Symbol" in global environment
    uint hash = heap.hash_string("Symbol");
    HString* existing = heap.str_table_lookup("Symbol", hash);
    HString* sym_key;
    if (existing != null) {
        sym_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Symbol", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        sym_key = new_key;
    }
    TVal sym_val;
    sym_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, "Symbol");
    env::env_declare_nonenum(global_env, sym_key, sym_val);

    return true;
}
