/// Duktape object (HObject) — the core ECMAScript object representation.
///
/// HObjects model all ECMAScript ordinary and exotic objects.  Each object
/// has:
///   - A HeapHeader-compatible prefix (flags, GC list pointers).
///   - A prototype chain link.
///   - A property table with both a hash part (for fast named-property
///     lookup) and a linear entry array.
///   - An optional dense array part for integer-indexed properties in the
///     range [0, array_size).  This avoids creating heavyweight PropEntry
///     records for the overwhelmingly common case of dense JS arrays.
///
/// Property lookup logic:
///   1. If the property key is an interned string that represents a valid
///      array index < array_size, check array_part first.
///   2. If a hash table exists (hash_size > 0), hash the key pointer,
///      probe the hash table for an index into the props array, then
///      compare keys.
///   3. Otherwise fall back to a linear scan of the props array.
///
/// The hash table stores uint indices into the props array.  A sentinel
/// value (HASH_UNUSED / HASH_DELETED) marks empty or tombstone slots.
module duktape::hobject;

import duktape::types;
import duktape::hstring;
import duktape::bytecode;
import duktape::env;
import duktape::re_bindings;
import duktape::heap;
import libc;

// Faults for optional returns
faultdef PROP_NOT_FOUND;
faultdef OBJ_ALLOC_FAULT;

// ============================================================================
// Constants
// ============================================================================

/// Cached pointer to the interned "length" string, set during heap init.
/// Used by put_prop to sync array_length on LENGTH writes.
void* builtin_length_key = null;

/// Initial number of property entry slots when first allocated.
const uint PROPS_INITIAL_CAPACITY = 8;

/// Initial dense array allocation size.
const uint ARRAY_INITIAL_SIZE = 16;

/// Growth factor numerator / denominator for property table (3/2 = 1.5×).
const uint PROPS_GROW_NUM = 3;
const uint PROPS_GROW_DEN = 2;

/// Minimum property count before a hash table is created.  Below this
/// threshold linear scan is fast enough.
const uint HASH_MIN_PROPS = 8;

/// Hash table load factor threshold (num / den).  When prop_count exceeds
/// hash_size * HASH_LOAD_NUM / HASH_LOAD_DEN, the table is rebuilt.
const uint HASH_LOAD_NUM = 7;
const uint HASH_LOAD_DEN = 10;

/// Sentinel value in the hash table: slot has never been used.
const uint HASH_UNUSED   = 0xFFFF_FFFF;

/// Sentinel value in the hash table: slot was deleted (tombstone).
const uint HASH_DELETED  = 0xFFFF_FFFE;

/// FNV-1a constants (used to hash pointer values for the property hash).
const uint FNV1A_OFFSET_BASIS = 0x811C_9DC5;
const uint FNV1A_PRIME        = 0x0100_0193;

// ============================================================================
// ObjClass — ECMAScript internal [[Class]]
// ============================================================================

/// Discriminator for the various ECMAScript object classes.
///
/// Encoded in 6 bits inside ObjFlags (up to 64 classes).
enum ObjClass : char {
    NONE,
    OBJECT,
    ARRAY,
    FUNCTION,
    ARGUMENTS,
    BOOLEAN,
    DATE,
    ERROR,
    JSON,
    MATH,
    NUMBER,
    REGEXP,
    STRING,
    GLOBAL,
    SYMBOL,
    /// Object environment record (ES spec).
    OBJENV,
    /// Declarative environment record (ES spec).
    DECENV,
    POINTER,
    THREAD,
    PROXY,
    ARRAYBUFFER,
    DATAVIEW,
    INT8ARRAY,
    UINT8ARRAY,
    UINT8CLAMPEDARRAY,
    INT16ARRAY,
    UINT16ARRAY,
    INT32ARRAY,
    UINT32ARRAY,
    FLOAT32ARRAY,
    FLOAT64ARRAY,
    MAP,
    SET,
    WEAKMAP,
    WEAKSET,
    PROMISE,
    GENERATOR,
    ARRAY_ITERATOR,
    STRING_ITERATOR,
    MAP_ITERATOR,
    SET_ITERATOR,
}

/// Discriminator for a callable object's invocation kind.
/// Stored in HObject.callable_kind.  Meaningful only when
/// flags.callable is true.
enum CallableKind : ushort {
    COMPILED_FN,        /// JS function — dispatch via comp_func
    BUILTIN_FN,         /// Native builtin — dispatch via builtin_fn_index
    BOUND_FN,           /// Bound function — dispatch via bound_call logic
    OTHER               /// Callable but none of the above (rare)
}

// ============================================================================
// ObjFlags — per-object bit-packed flags
// ============================================================================

/// Bit-packed flags word for HObject.
///
/// Bits 0–6 are reserved for HeapHeader-compatible type / GC bits so that
/// a raw cast from HObject* to HeapHeader* reads the correct htype and
/// mark bits.  Bits 7+ carry object-specific metadata.
bitstruct ObjFlags : uint {
    /// HeapHeader-compatible type discriminator (always HType.OBJECT).
    HType htype            : 0..1;
    /// GC reachable flag.
    bool  reachable        : 2;
    /// GC temporary root flag.
    bool  temproot         : 3;
    /// Finaliser present flag.
    bool  finalizable      : 4;
    /// Finaliser already ran.
    bool  finalized        : 5;
    /// Read-only flag.
    bool  readonly         : 6;

    // --- Object-specific flags (bits 7+) ---

    /// [[Extensible]] internal slot.
    bool extensible        : 7;
    /// Object can be used as a constructor (has [[Construct]]).
    bool constructable     : 8;
    /// Object is callable (has [[Call]]).
    bool callable          : 9;
    /// Bound function (created by Function.prototype.bind).
    bool is_bound          : 10;
    /// Object has an attached C/JS finalizer.
    bool has_finalizer     : 11;
    /// Exotic [[DefineOwnProperty]] for Array objects.
    bool exotic_array      : 12;
    /// Exotic behaviour for String wrapper objects.
    bool exotic_stringobj  : 13;
    /// Exotic behaviour for Arguments objects.
    bool exotic_arguments  : 14;
    /// Exotic behaviour for Proxy objects.
    bool exotic_proxyobj   : 15;
    /// Internal [[Class]] tag (6 bits → up to 64 classes).
    ObjClass obj_class     : 16..21;
}

// ============================================================================
// PropFlags — per-property attribute bits
// ============================================================================

/// ECMAScript property descriptor attribute flags.
///
/// Matches the spec's [[Writable]], [[Enumerable]], [[Configurable]]
/// attributes plus an accessor flag.
bitstruct PropFlags : char {
    /// Property value can be changed.
    bool writable     : 0;
    /// Property appears in for-in and Object.keys().
    bool enumerable   : 1;
    /// Property can be deleted and its attributes changed.
    bool configurable : 2;
    /// When true the property is an accessor (getter/setter pair) rather
    /// than a data property.
    bool is_accessor  : 3;
}

/// Convenience constant: default flags for a normal data property created
/// by assignment (writable, enumerable, configurable).
const PropFlags PROP_FLAGS_WEC = {
    .writable     = true,
    .enumerable   = true,
    .configurable = true,
    .is_accessor  = false
};

/// Convenience constant: non-enumerable data property (writable, configurable).
/// Used for built-in prototype methods per ES5 spec.
const PropFlags PROP_FLAGS_WC = {
    .writable     = true,
    .enumerable   = false,
    .configurable = true,
    .is_accessor  = false
};

/// Convenience constant: non-writable data property (enumerable, configurable).
/// Used for `const` bindings to prevent reassignment.
const PropFlags PROP_FLAGS_EC = {
    .writable     = false,
    .enumerable   = true,
    .configurable = true,
    .is_accessor  = false
};

/// Convenience constant: accessor property (enumerable, configurable).
/// Used for getter/setter properties in object literals and class bodies.
const PropFlags PROP_FLAGS_ACCESSOR = {
    .writable     = false,
    .enumerable   = true,
    .configurable = true,
    .is_accessor  = true
};

/// Convenience constant: non-writable, non-enumerable, configurable.
/// Used for .name and .length properties of built-in functions.
const PropFlags PROP_FLAGS_NWC = {
    .writable     = false,
    .enumerable   = false,
    .configurable = true,
    .is_accessor  = false
};

/// Non-writable, non-enumerable, non-configurable — String exotic .length (ES5 §15.5.5.1)
const PropFlags PROP_FLAGS_NNC = {
    .writable     = false,
    .enumerable   = false,
    .configurable = false,
    .is_accessor  = false
};

/// Writable, enumerable, non-configurable — String exotic indexed properties (ES5 §15.5.5.1)
const PropFlags PROP_FLAGS_NEC = {
    .writable     = true,
    .enumerable   = true,
    .configurable = false,
    .is_accessor  = false
};

/// Result of searching for an accessor property on the prototype chain.
struct AccessorResult {
    /// The getter or setter TVal (function), or undefined if not found.
    TVal accessor_fn;
    /// The object that owns the accessor (needed for `this` binding).
    HObject* this_obj;
    /// Whether an accessor was actually found.
    bool found;
}

// ============================================================================
// PropValue — per-object property value storage (QuickJS-style)
// ============================================================================

/// A property value slot in the object's prop_values array.
///
/// Property names and flags live in the Shape (shared across objects).
/// Objects only store values.  For accessor properties, both getter and
/// setter are stored; for data properties, only `value` is meaningful.
union PropData {
    /// Data property: single value.
    TVal      value;
    /// Accessor property: getter at index 0, setter at next TVal.
    /// Stored as getter; the setter follows at (&getter + 1) in memory.
    TVal      getter;
}
struct PropValue {
    PropData  data;
    /// For accessor properties, the setter lives here.
    /// For data properties, this is unused.
    TVal      setter;
    PropFlags flags;
}

// ============================================================================
// ShapeProperty — property descriptor inside a Shape
// ============================================================================

/// A single property descriptor stored in the Shape's property array.
/// Contains the property key and flags, but NO value (values are per-object).
struct ShapeProperty {
    /// Interned property key (HString*).  Pointer equality for comparison.
    void*     key;
    /// Property attribute flags.
    PropFlags flags;
}

// ============================================================================
// HObject — the core heap-allocated object
// ============================================================================

// ============================================================================
// HObject — Subtype structs for HObjectExtra union
// ============================================================================

/// Compiled function / native builtin extra fields.
struct HObjectFunction {
    CompiledFunction* comp_func;
    EnvRecord*        var_env;
    EnvRecord*        lex_env;
    int               builtin_fn_index;
    CallableKind      callable_kind;
}

/// Primitive wrapper (Boolean, Number, String objects).
struct HObjectPrimitive {
    TVal              primitive_value;
}

/// RegExp object: pattern + compiled bytecode.
struct HObjectRegExp {
    TVal              pattern_str;
    void*             regexp_data;
    int               flags;       // JS flag bits: 1=g, 2=i, 4=m
}

/// Generator: suspended execution state + captured env.
struct HObjectGenerator {
    void*             generator_data;
    CompiledFunction* comp_func;
    EnvRecord*        var_env;
    EnvRecord*        lex_env;
}

/// Tagged union of subtype-specific fields.
/// Discriminator is flags.obj_class (in the common header).
union HObjectExtra {
    HObjectFunction  func;
    HObjectPrimitive prim;
    HObjectRegExp    regexp;
    HObjectGenerator gen;
}

/// The core ECMAScript object representation.
///
/// Memory layout is chosen so that the first three fields (flags,
/// next, prev) are binary-compatible with HeapHeader, allowing a raw cast
/// for the GC's linked-list walk.
///
/// Subtype-specific fields (function, primitive wrapper, regexp, generator)
/// are stored in a union to save memory — only one variant is active at a
/// time, discriminated by flags.obj_class.
///
/// Property storage uses QuickJS-style shapes: property names and flags
/// live in the shared Shape, objects only store values.
struct HObject {
    // --- Inline HeapHeader ------------------------------------------------
    ObjFlags      flags;
    uint          refcount;
    HeapHeader*   next;
    HeapHeader*   prev;

    // --- Prototype --------------------------------------------------------
    HObject*      prototype;

    // --- Shape (shared property layout) ------------------------------------
    /// Shape ID for inline cache support (index into Heap.shapes[]).
    uint          shape_id;
    /// Pointer to the shared Shape describing this object's property layout.
    /// Property names, flags, and the hash table live here.
    Shape*        shape;
    /// Back-pointer to the heap for shape transitions.
    void*         heap_ptr;

    // --- Per-object property values ----------------------------------------
    /// Allocated capacity of prop_values (>= shape->prop_count).
    uint          prop_capacity;
    /// Number of properties currently in use (synced with shape->prop_count).
    uint          prop_count;

    // --- Dense array part ------------------------------------------------
    uint          array_size;
    uint          array_used;

    // --- Unified property allocation block --------------------------------
    /// Single allocation that holds prop_values and array_part contiguously.
    void*         prop_alloc;

    // --- Subtype-specific fields (overlapping union) -----------------------
    /// Only one variant is active, determined by flags.obj_class.
    HObjectExtra  extra;

    // --- Iterator state (for ARRAY_ITERATOR / STRING_ITERATOR objects) -------
    HObject*      iterator_target;
    uint          iterator_index;
    uint          iterator_kind;

    // --- Array length shadow cache -----------------------------------------
    /// Cached array length for fast reads. Synced by put_prop and SETALEN.
    uint          array_length;
}

// ============================================================================
// HObject — Unified property allocation helpers
// ============================================================================

/// Compute total size of the property allocation block.
fn usz HObject.prop_alloc_size(&self) {
    usz size = (usz)self.prop_capacity * PropValue::size;
    size += (usz)self.array_size * TVal::size;
    return size;
}

/// Returns pointer to the property values array (derived from prop_alloc).
fn PropValue* HObject.prop_values(&self) @inline {
    if (self.prop_alloc == null) return null;
    return (PropValue*)self.prop_alloc;
}

/// Returns pointer to the dense array part (derived from prop_alloc).
/// Returns null when there is no array part.
fn TVal* HObject.array_part(&self) @inline {
    if (self.prop_alloc == null || self.array_size == 0) return null;
    return (TVal*)((char*)self.prop_alloc + (usz)self.prop_capacity * PropValue::size);
}

// ============================================================================
// HObject — HeapHeader-compatible helpers
// ============================================================================

/// Returns a HeapHeader pointer to this object (binary-compatible cast).
fn HeapHeader* HObject.as_header(&self) @inline {
    return (HeapHeader*)self;
}

// ============================================================================
// HObject — flag accessors
// ============================================================================

/// Returns the object's [[Class]].
fn ObjClass HObject.get_class(&self)    { return self.flags.obj_class; }

/// Returns true when the object is [[Extensible]].
fn bool HObject.is_extensible(&self)    { return self.flags.extensible; }

/// Returns true when the object is callable.
fn bool HObject.is_callable(&self)      @inline { return self.flags.callable; }

/// Returns true when the object can be used as a constructor.
fn bool HObject.is_constructable(&self) @inline { return self.flags.constructable; }

/// Returns true when the object is a bound function.
fn bool HObject.is_bound(&self)         @inline { return self.flags.is_bound; }

/// Seal the object: clear extensible, mark all own properties as
/// non-configurable.
fn void HObject.seal(&self) {
    self.flags.extensible = false;
    ShapeProperty* sp = self.shape != null ? self.shape.props() : null;
    for (uint i = 0; i < self.prop_count; i++) {
        self.prop_values()[i].flags.configurable = false;
        if (sp != null) sp[i].flags.configurable = false;
    }
}

/// Freeze the object: seal + mark all data properties non-writable.
fn void HObject.freeze(&self) {
    self.seal();
    ShapeProperty* sp = self.shape != null ? self.shape.props() : null;
    for (uint i = 0; i < self.prop_count; i++) {
        if (!self.prop_values()[i].flags.is_accessor) {
            self.prop_values()[i].flags.writable = false;
            if (sp != null) sp[i].flags.writable = false;
        }
    }
}

// ============================================================================
// Internal: pointer hashing
// ============================================================================

/// Hash a pointer value to produce an index into the hash table.
///
/// We use a simple integer hash (xor-shift mix) of the pointer bits.  Since
/// property keys are interned HStrings, pointer identity == string equality,
/// so hashing the pointer is correct.
fn uint hash_key(void* key) @inline {
    uint h = (uint)((usz)key);
    // Murmur3-style finalizer mix
    h ^= h >> 16;
    h *= 0x85EB_CA6B;
    h ^= h >> 13;
    h *= 0xC2B2_AE35;
    h ^= h >> 16;
    return h;
}

// ============================================================================
// HObject — property index lookup
// ============================================================================

/// Find the index of the property with the given interned key.
///
/// Delegates to the shared Shape's hash table for O(1) lookup.
/// Returns the index (≥ 0) on success, or -1 if the key is not found.
fn int HObject.find_prop_idx(&self, void* key) {
    if (key == null || self.shape == null) {
        return -1;
    }
    return self.shape.find_prop_idx(key);
}

/// Find the PropValue for the given interned key.
///
/// Returns a pointer to the value slot, or `null` if not found.
fn PropValue*? HObject.find_prop(&self, void* key) {
    int idx = self.find_prop_idx(key);
    if (idx < 0) {
        return PROP_NOT_FOUND~;
    }
    return &self.prop_values()[idx];
}

// ============================================================================
// HObject — property get / has / put / delete
// ============================================================================

/// Look up a named property by its interned string key.
fn TVal? HObject.get_prop(&self, void* key) {
    int idx = self.find_prop_idx(key);
    if (idx < 0) {
        return PROP_NOT_FOUND~;
    }
    return self.prop_values()[idx].data.value;
}

/// Check whether the object has an own property with the given key.
fn bool HObject.has_prop(&self, void* key) {
    return self.find_prop_idx(key) >= 0;
}

/// Check whether a property is writable.
fn bool HObject.is_prop_writable(&self, void* key) {
    int idx = self.find_prop_idx(key);
    if (idx < 0) return true;
    return self.prop_values()[idx].flags.writable;
}

/// Set (create or update) a named property.
///
/// If the property already exists its value and flags are updated.
/// If it does not exist a new entry is appended (growing the table if
/// necessary).  The caller is responsible for updating the shape
/// (via Heap.transition_shape) when a new property is added.
/// Returns `true` on success, `false` on allocation failure.
fn bool HObject.put_prop(&self, void* key, TVal val, PropFlags pflags) {
    // --- Update existing property ---
    int idx = self.find_prop_idx(key);
    if (idx >= 0) {
        PropValue* pv = &self.prop_values()[idx];
        if (self.heap_ptr != null && pv.data.value.is_string()) {
            ((heap::Heap*)self.heap_ptr).decref_tval(&pv.data.value);
        }
        pv.data.value = val;
        if (self.heap_ptr != null && val.is_string()) {
            void* ptr = val.get_heapptr();
            if (ptr != null) {
                ((types::HeapHeader*)ptr).incref();
            }
        }
        pv.flags = pflags;
        // Sync array_length shadow cache on LENGTH writes to ARRAY exotic
        if (self.flags.exotic_array && key == builtin_length_key) {
            if (val.is_fastint()) {
                self.array_length = (uint)val.get_fastint();
            } else if (val.is_number()) {
                self.array_length = (uint)val.get_number();
            }
        }
        return true;
    }

    // --- Grow if necessary ---
    if (self.prop_count >= self.prop_capacity) {
        self.grow_props();
        if (self.prop_count >= self.prop_capacity) {
            return false;
        }
    }

    // --- Append new value at the next slot ---
    uint new_idx = self.prop_count;
    libc::memset(&self.prop_values()[new_idx], 0, PropValue::size);
    self.prop_values()[new_idx].data.value = val;
    self.prop_values()[new_idx].flags = pflags;
    if (self.heap_ptr != null && val.is_string()) {
        void* ptr = val.get_heapptr();
        if (ptr != null) {
            ((types::HeapHeader*)ptr).incref();
        }
    }
    self.prop_count++;

    // Sync array_length shadow cache on LENGTH writes to ARRAY exotic
    if (self.flags.exotic_array && key == builtin_length_key) {
        if (val.is_fastint()) {
            self.array_length = (uint)val.get_fastint();
        } else if (val.is_number()) {
            self.array_length = (uint)val.get_number();
        }
    }

    // --- Transition shape to include the new property ---
    if (self.heap_ptr != null) {
        heap::Heap* h = (heap::Heap*)self.heap_ptr;
        uint new_shape_id = h.transition_shape(self.shape_id, key);
        if (new_shape_id != self.shape_id) {
            self.shape_id = new_shape_id;
            self.shape = h.get_shape(new_shape_id);
        }
    }

    return true;
}

/// Delete an own property by interned key.
///
/// Compacts prop_values by shifting remaining entries down, decrements
/// prop_count, and rebuilds this object's shape from scratch (private,
/// not shared) so the hash table reflects the new layout.
fn bool HObject.delete_prop(&self, void* key) {
    int idx = self.find_prop_idx(key);
    if (idx < 0) {
        return false;
    }

    uint ui = (uint)idx;
    uint new_count = self.prop_count - 1;

    // Compact prop_values: shift [ui+1..prop_count-1] → [ui..prop_count-2]
    for (uint i = ui; i < new_count; i++) {
        self.prop_values()[i] = self.prop_values()[i + 1];
    }
    libc::memset(&self.prop_values()[new_count], 0, PropValue::size);
    self.prop_count = new_count;

    // Build a new private shape from the surviving properties.
    // We do NOT insert it into the transition table — it's object-specific.
    Shape* ns = shape_create(new_count, 0xFFFF_FFFF);
    if (ns != null) {
        // Copy surviving property names from old shape.
        if (self.shape != null) {
            ShapeProperty* old_sp = self.shape.props();
            ShapeProperty* new_sp = ns.props();
            uint ni = 0;
            for (uint i = 0; i < self.shape.prop_count; i++) {
                if (i != ui) {
                    new_sp[ni].key   = old_sp[i].key;
                    new_sp[ni].flags = old_sp[i].flags;
                    ni++;
                }
            }
        }
        // Rebuild hash table.
        uint* ht = ns.hash_table();
        uint mask = ns.hash_mask;
        ShapeProperty* sp = ns.props();
        for (uint i = 0; i < new_count; i++) {
            uint h = hash_key(sp[i].key);
            uint slot = h & mask;
            while (ht[slot] != 0) slot = (slot + 1) & mask;
            ht[slot] = i + 1;
        }

        // Register with heap and attach to this object.
        if (self.heap_ptr != null) {
            heap::Heap* h = (heap::Heap*)self.heap_ptr;
            uint new_id = h.alloc_shape_slot();
            if (new_id != heap::SHAPE_NONE) {
                h.shapes[new_id] = ns;
                self.shape_id = new_id;
                self.shape = ns;
            } else {
                shape_free(ns, self.heap_ptr);
                self.shape = null;
            }
        } else {
            shape_free(ns, null);
            self.shape = null;
        }
    } else {
        self.shape = null;
    }

    return true;
}

// ============================================================================
// HObject — dense array part
// ============================================================================

/// Get a value from the dense array part by integer index.
///
/// Returns the TVal at `idx`, or `null` (Optional failure) when the index
/// is out of range or the slot holds undefined (hole).
fn TVal? HObject.get_array_idx(&self, uint idx) {
    if (self.array_part() == null || idx >= self.array_size) {
        return PROP_NOT_FOUND~;
    }
    TVal v = self.array_part()[idx];
    // Treat undefined as "not present" (array hole).
    if (v.is_undefined()) {
        return PROP_NOT_FOUND~;
    }
    return v;
}

/// Set a value in the dense array part.  Grows the array if necessary.
fn void HObject.set_array_idx(&self, uint idx, TVal val) {
    // Grow if needed.
    if (idx >= self.array_size) {
        uint new_size = self.array_size;
        if (new_size == 0) {
            new_size = ARRAY_INITIAL_SIZE;
        }
        // Overflow-safe doubling: bail if we'd overflow uint on next multiply
        while (new_size <= idx) {
            if (new_size >= 0x80000000) { return; }
            new_size *= 2;
        }
        self.grow_array(new_size);
        // If grow failed (array_size unchanged), bail out.
        if (idx >= self.array_size) {
            return;
        }
    }

    // Track used count.
    TVal old_val = self.array_part()[idx];
    if (old_val.is_undefined() && !val.is_undefined()) {
        self.array_used++;
    } else if (!old_val.is_undefined() && val.is_undefined()) {
        if (self.array_used > 0) {
            self.array_used--;
        }
    }

    if (self.heap_ptr != null && self.array_part()[idx].is_string()) {
        ((heap::Heap*)self.heap_ptr).decref_tval(&self.array_part()[idx]);
    }
    self.array_part()[idx] = val;
    if (self.heap_ptr != null && val.is_string()) {
        void* ptr = val.get_heapptr();
        if (ptr != null) {
            ((types::HeapHeader*)ptr).incref();
        }
    }
}

// ============================================================================
// HObject — growth / rehash
// ============================================================================

/// Grow the property value table when it is full.
fn void HObject.grow_props(&self) {
    uint new_cap;
    if (self.prop_capacity == 0) {
        new_cap = PROPS_INITIAL_CAPACITY;
    } else {
        new_cap = self.prop_capacity * PROPS_GROW_NUM / PROPS_GROW_DEN;
        if (new_cap <= self.prop_capacity) {
            new_cap = self.prop_capacity + 4;
        }
    }

    usz old_size = self.prop_alloc_size();
    usz old_prop_bytes = (usz)self.prop_capacity * PropValue::size;
    usz new_size = old_size - old_prop_bytes + (usz)new_cap * PropValue::size;

    void* new_raw;
    if (self.prop_alloc == null) {
        new_raw = libc::malloc(new_size);
    } else {
        new_raw = libc::realloc(self.prop_alloc, new_size);
    }
    if (new_raw == null) return;

    self.prop_alloc = new_raw;
    uint old_prop_capacity = self.prop_capacity;
    self.prop_capacity = new_cap;

    // prop_alloc may have moved — invalidate ICs that cached prop_value pointers.
    // (shape_id is unchanged, so the gen bump is what invalidates them.)
    if (self.heap_ptr != null) {
        ((heap::Heap*)self.heap_ptr).bump_shape_gen(self.shape_id);
    }

    // Move the dense array part to its new position before updating pointers.
    // When prop_capacity grows, the array data shifts right by the capacity
    // difference — realloc preserves old bytes in place, so we must move them.
    if (self.array_size > 0 && self.array_part() != null) {
        usz old_arr_off = (usz)old_prop_capacity * PropValue::size;
        usz new_arr_off = (usz)new_cap * PropValue::size;
        if (old_arr_off != new_arr_off) {
            libc::memmove((char*)self.prop_alloc + new_arr_off,
                          (char*)self.prop_alloc + old_arr_off,
                          (usz)self.array_size * TVal::size);
        }
    }

    if (new_cap > old_prop_capacity) {
        usz added_bytes = (usz)(new_cap - old_prop_capacity) * PropValue::size;
        void* start = (void*)((char*)self.prop_values() + (usz)old_prop_capacity * PropValue::size);
        libc::memset(start, 0, added_bytes);
    }
}

/// Grow the dense array part to at least `new_size` TVal slots.
///
/// New slots are initialised to undefined.
fn void HObject.grow_array(&self, uint new_size) {
    if (new_size <= self.array_size) return;

    usz old_prop_bytes = (usz)self.prop_capacity * PropValue::size;
    usz old_array_size = self.array_size;

    usz new_bytes = old_prop_bytes + (usz)new_size * TVal::size;

    void* new_raw;
    if (self.prop_alloc == null) {
        new_raw = libc::malloc(new_bytes);
    } else {
        new_raw = libc::realloc(self.prop_alloc, new_bytes);
    }
    if (new_raw == null) return;

    self.prop_alloc = new_raw;
    self.array_size = new_size;

    usz added = (usz)(new_size - old_array_size);
    ulong undef_bits = (ulong)(types::TAG_UNDEFINED) << 48;
    for (usz i = 0; i < added; i++) {
        self.array_part()[old_array_size + i].bits = undef_bits;
    }
}

// rebuild_hash removed — hash table now lives in the shared Shape.

// ============================================================================
// Allocation / deallocation
// ============================================================================

/// Allocate and initialise a new HObject of the given class.
///
/// `heap_ptr` is an opaque pointer to the Heap; the object is **not**
/// automatically inserted into the heap's GC list — the caller must do so.
///
/// The object starts with:
///   - flags.htype          = HType.OBJECT
///   - flags.extensible     = true
///   - flags.obj_class      = cls
///   - (padding)            = 0
///   - Empty property table and no array part
///
/// Returns `null` on allocation failure.
fn HObject*? hobject_alloc(void* heap_ptr, ObjClass cls) {
    void* raw = ((heap::Heap*)heap_ptr).alloc(HObject::size) ?? null;
    if (raw == null) {
        return OBJ_ALLOC_FAULT~;
    }

    libc::memset(raw, 0, HObject::size);

    HObject* obj = (HObject*)raw;

    obj.prop_alloc = null;
    obj.prop_capacity = 0;
    obj.prop_count = 0;

    obj.flags.htype      = HType.OBJECT;
    obj.flags.extensible = true;
    obj.flags.obj_class  = cls;
    obj.refcount         = 1;

    if (cls == ObjClass.FUNCTION) {
        obj.flags.callable      = true;
        obj.flags.constructable = true;
    } else if (cls == ObjClass.ARRAY) {
        obj.flags.exotic_array = true;
        obj.array_length = 0;
    } else if (cls == ObjClass.ARGUMENTS) {
        obj.flags.exotic_arguments = true;
    } else if (cls == ObjClass.PROXY) {
        obj.flags.exotic_proxyobj = true;
    }

    obj.extra.func.builtin_fn_index = -1;
    obj.extra.func.callable_kind = CallableKind.OTHER;
    obj.shape_id = 0;
    obj.shape = ((heap::Heap*)heap_ptr).get_shape(0);  // root shape
    obj.heap_ptr = heap_ptr;
    return obj;
}

/// Free an HObject and all of its owned sub-allocations (property table,
/// hash table, array part).
///
/// The caller must have already unlinked the object from the heap's GC list
/// and string table references.
fn void hobject_free(HObject* obj) {
    if (obj == null) { return; }

    if (obj.flags.obj_class == ObjClass.REGEXP && obj.extra.regexp.regexp_data != null) {
        re_bindings::re_free(obj.extra.regexp.regexp_data);
        obj.extra.regexp.regexp_data = null;
    }

    // Decref string values held in property slots and array elements.
    // Only strings are RC-freed here — objects still use M&S and can form cycles;
    // decref-freeing objects from within another object's teardown would corrupt the
    // heap_allocated list and cause use-after-free on generator/closure env chains.
    if (obj.prop_alloc != null && obj.heap_ptr != null) {
        heap::Heap* h = (heap::Heap*)obj.heap_ptr;
        PropValue* pvs = obj.prop_values();
        for (uint i = 0; i < obj.prop_count; i++) {
            if (pvs[i].data.value.is_string()) {
                h.decref_tval(&pvs[i].data.value);
            }
            if (pvs[i].flags.is_accessor && pvs[i].setter.is_string()) {
                h.decref_tval(&pvs[i].setter);
            }
        }
        TVal* arr = obj.array_part();
        if (arr != null) {
            for (uint i = 0; i < obj.array_size; i++) {
                if (arr[i].is_string()) {
                    h.decref_tval(&arr[i]);
                }
            }
        }
    }

    // Free the unified property allocation block (prop_values + array_part).
    // Shape is shared and managed by the heap — do NOT free it here.
    if (obj.prop_alloc != null) {
        libc::free(obj.prop_alloc);
        obj.prop_alloc = null;
    }

    libc::free(obj);
}

// ============================================================================
// Enumeration helpers
// ============================================================================

/// Returns the number of own enumerable properties.
fn uint HObject.enumerable_count(&self) {
    uint count = 0;
    for (uint i = 0; i < self.prop_count; i++) {
        if (self.prop_values()[i].flags.enumerable) {
            count++;
        }
    }
    return count;
}

/// Returns the property entry at the given raw index, or `null` if `idx`
/// is out of range.  Intended for iteration over own properties.
fn PropValue*? HObject.get_prop_at(&self, uint idx) {
    if (idx >= self.prop_count) {
        return PROP_NOT_FOUND~;
    }
    return &self.prop_values()[idx];
}

// ============================================================================
// Prototype-chain helpers
// ============================================================================

/// Walk the prototype chain looking for a named property.
///
/// Returns the TVal of the first own property with the matching key found
/// along the chain, or `null` (Optional failure) if no object in the chain
/// has the property.  The depth limit prevents infinite loops from circular
/// prototype chains.
fn TVal? HObject.get_prop_proto(&self, void* key) {
    HObject* cur = self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        int idx = cur.find_prop_idx(key);
        if (idx >= 0) {
            return cur.prop_values()[idx].data.value;
        }
        cur = cur.prototype;
        depth++;
    }

    return PROP_NOT_FOUND~;
}

/// Search the prototype chain for an accessor property (getter or setter).
///
/// Returns an AccessorResult with the accessor function and its owning object
/// (for `this` binding), or `.found = false` if no accessor exists.
/// If a data property is found before any accessor, the search stops (no accessor).
fn AccessorResult HObject.find_accessor_proto(&self, void* key, bool want_getter) {
    HObject* cur = self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        int idx = cur.find_prop_idx(key);
        if (idx >= 0) {
            if (cur.prop_values()[idx].flags.is_accessor) {
                TVal accessor_fn = want_getter ? cur.prop_values()[idx].data.getter : cur.prop_values()[idx].setter;
                if (accessor_fn.is_object() && accessor_fn.get_heapptr() != null) {
                    return { .accessor_fn = accessor_fn, .this_obj = self, .found = true };
                }
                return { .accessor_fn = accessor_fn, .this_obj = self, .found = true };
            }
            return { .found = false };
        }
        cur = cur.prototype;
        depth++;
    }

    return { .found = false };
}

/// Maximum prototype chain depth before we assume a cycle / infinite loop.
const uint MAX_PROTO_DEPTH = 256;

/// Result of a combined accessor + data property lookup.
enum PropLookupKind {
    PROP_ACCESSOR,
    PROP_DATA,
    PROP_NOT_FOUND
}

/// Combined result of a prototype-chain lookup.
/// Check `kind` first: if PROP_ACCESSOR, read `acc`;
/// if PROP_DATA, read `data_val` (and optionally `owner`);
/// if PROP_NOT_FOUND, neither is valid.
struct PropLookupResult {
    PropLookupKind kind;
    TVal data_val;
    HObject* owner;
    AccessorResult acc;
}

// ============================================================================
// Shape (Hidden Class) — tracks object property layout for inline caches
// ============================================================================

/// A Shape describes the named-property structure of an object: which
/// properties exist, at what indices, and with what flags.  Shapes form a
/// transition tree: adding a property to an object transitions its shape
/// from parent → child.  Multiple objects that gain the same properties in
/// the same order share the same shape, enabling inline caches to predict
/// property offsets.
///
/// QuickJS-style layout: the Shape is a single allocation containing
/// [hash_table | Shape header | ShapeProperty[]].  Property names and
/// flags live here (shared); values live per-object in PropValue[].
struct Shape {
    /// Generation counter — bumped on delete/seal/freeze to invalidate ICs.
    uint      generation;
    /// Parent shape index (0xFFFF_FFFF for root).
    uint      parent;
    /// Number of properties in this shape.
    uint      prop_count;
    /// Hash table mask (hash_table has hash_mask+1 slots, all uint32).
    /// 0 means 1 slot (hash_mask=0 → 2 slots).  Stored as mask for fast &.
    uint      hash_mask;
}

// ============================================================================
// Shape — memory layout helpers
// ============================================================================

/// Compute the byte offset of the hash table from the shape base.
/// Hash table is always the first thing in the allocation.
fn usz shape_hash_offset() @inline {
    return 0;
}

/// Compute the byte offset of the Shape header from the shape base.
fn usz shape_header_offset(Shape* sh) @inline {
    return ((usz)sh.hash_mask + 1) * uint::size;
}

/// Get pointer to the hash table (uint32 array) for this shape.
fn uint* Shape.hash_table(&self) {
    return (uint*)((char*)self - (sz)shape_header_offset(self));
}

/// Get pointer to the ShapeProperty array (immediately after the header).
fn ShapeProperty* Shape.props(&self) {
    return (ShapeProperty*)((char*)self + Shape::size);
}

/// Look up a property key in the shape's hash table.
/// Returns the property index (≥ 0) on success, or -1 if not found.
fn int Shape.find_prop_idx(&self, void* key) {
    if (key == null || self.prop_count == 0) return -1;
    uint* ht = self.hash_table();
    uint mask = self.hash_mask;
    uint h = hash_key(key);
    uint slot = h & mask;
    ShapeProperty* sp = self.props();
    for (uint probes = 0; probes <= mask; probes++) {
        uint entry = ht[slot];
        if (entry == 0) return -1;
        uint idx = entry - 1;
        if (idx < self.prop_count && sp[idx].key == key) {
            return (int)idx;
        }
        slot = (slot + 1) & mask;
    }
    return -1;
}

/// Return the total byte size of a shape allocation.
fn usz shape_alloc_size(uint prop_count, uint hash_mask) {
    return ((usz)hash_mask + 1) * uint::size     // hash table
         + Shape::size                            // header
         + (usz)prop_count * ShapeProperty::size; // properties
}

/// Choose a hash mask for a given property count.
/// Hash table has (mask+1) slots; we want load factor < 70%.
fn uint shape_hash_mask_for(uint prop_count) {
    // Minimum 2 slots (mask=0), grow so that prop_count / (mask+1) < 0.7
    uint slots = 2;
    while (prop_count * 10 > slots * 7) {
        slots *= 2;
    }
    return slots - 1;
}

/// Create a new empty shape for the given parent.
/// Returns a heap-allocated Shape block, or null on failure.
fn Shape* shape_create(uint prop_count, uint parent) {
    uint hm = shape_hash_mask_for(prop_count > 0 ? prop_count : 1);
    usz bytes = shape_alloc_size(prop_count, hm);
    void* raw = libc::malloc(bytes);
    if (raw == null) return null;
    libc::memset(raw, 0, bytes);

    Shape* sh = (Shape*)((char*)raw + (usz)(hm + 1) * uint::size);
    sh.generation = 0;
    sh.parent     = parent;
    sh.prop_count = prop_count;
    sh.hash_mask  = hm;

    // Fill hash table with 0 (empty sentinel).
    uint* ht = (uint*)raw;
    libc::memset(ht, 0, ((usz)hm + 1) * uint::size);

    return sh;
}

/// Create a new shape that extends `parent` by adding one property.
/// Copies all existing properties from parent and appends the new one.
/// Returns null on allocation failure.
fn Shape* shape_extend(Shape* parent, uint parent_id, void* new_key) {
    uint old_count = parent.prop_count;
    uint new_count = old_count + 1;
    Shape* ns = shape_create(new_count, parent_id);
    if (ns == null) return null;

    // Copy old properties
    ShapeProperty* old_sp = parent.props();
    ShapeProperty* new_sp = ns.props();
    for (uint i = 0; i < old_count; i++) {
        new_sp[i].key   = old_sp[i].key;
        new_sp[i].flags = old_sp[i].flags;
    }

    // Add new property at the end
    new_sp[old_count].key   = new_key;
    new_sp[old_count].flags = PROP_FLAGS_WEC;

    // Rehash all properties into new hash table
    uint* ht = ns.hash_table();
    uint mask = ns.hash_mask;
    for (uint i = 0; i < new_count; i++) {
        uint h = hash_key(new_sp[i].key);
        uint slot = h & mask;
        while (ht[slot] != 0) slot = (slot + 1) & mask;
        ht[slot] = i + 1;  // 1-indexed (0 = empty)
    }

    // Incref all keys: this new shape holds independent refs to all keys.
    for (uint i = 0; i < old_count; i++) {
        if (new_sp[i].key != null) {
            ((types::HeapHeader*)new_sp[i].key).incref();
        }
    }
    if (new_key != null) {
        ((types::HeapHeader*)new_key).incref();
    }

    return ns;
}

/// Free a shape allocation.  Computes the base pointer from the Shape pointer.
/// If heap_ptr is non-null, decrefs all property keys held by this shape.
/// Pass null at teardown to skip decref (when the string table is already being freed).
fn void shape_free(Shape* sh, void* heap_ptr) {
    if (sh == null) return;
    if (heap_ptr != null) {
        ShapeProperty* sp = sh.props();
        heap::Heap* h = (heap::Heap*)heap_ptr;
        for (uint i = 0; i < sh.prop_count; i++) {
            if (sp[i].key != null) {
                h.decref((HeapHeader*)sp[i].key);
            }
        }
    }
    void* base = (char*)sh - (sz)shape_header_offset(sh);
    libc::free(base);
}

// ============================================================================
// ICEntry — per-site inline cache entry (monomorphic)
// ============================================================================

/// A single inline cache entry, one per GETPROP/PUTPROP instruction site.
/// Stores the result of the last property lookup so that subsequent
/// accesses with the same object shape can skip the full prototype-chain
/// walk.
struct ICEntry {
    /// Shape ID of the object when this entry was populated.
    uint   shape_id;
    /// Property index within the owner's prop_values[].
    uint   prop_idx;
    /// Prototype pointer where the property was found (null = own property).
    void*  proto;
    /// The interned key (HString*) this entry was populated for.
    /// Pointer equality is sufficient (interned strings).
    void*  key;
    /// Cached pointer to the resolved PropValue for direct access.
    /// Invalidated when prop_alloc is reallocated (prop_alloc comparison).
    PropValue* prop_value_ptr;
    /// Snapshot of the owner's prop_alloc pointer at population time.
    /// IC hit requires this == owner.prop_alloc (single pointer comparison
    /// replaces the old generation-dereference chain).
    void*  cached_prop_alloc;
}

/// Per GETVAR/TYPEOFIDENT site inline cache. Stores the resolved
/// environment record and property index to skip the scope-chain walk
/// on subsequent accesses.
struct VarICEntry {
    /// The EnvRecord* that owns the binding (null = not populated).
    void*   env;
    /// The HObject* bindings object of the env (for shape check).
    void*   bindings;
    /// Shape ID of the bindings object when this entry was populated.
    uint    shape_id;
    /// Generation of the shape at population time.
    uint    generation;
    /// Property index within bindings.props[].
    ushort  prop_idx;
    /// The interned key (HString*) this entry was populated for.
    void*   key;
}

/// Single-pass prototype chain search: finds either an accessor or data property.
/// Returns the kind found. For accessors, sets `acc_out`; for data, sets `data_out`.
/// If `owner_out` is non-null, sets it to the object owning the found property.
fn PropLookupResult HObject.get_prop_or_accessor_proto(&self, void* key, bool want_getter) {
    HObject* cur = self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        int idx = cur.find_prop_idx(key);
        if (idx >= 0) {
            if (cur.prop_values()[idx].flags.is_accessor) {
                TVal accessor_fn = want_getter ? cur.prop_values()[idx].data.getter : cur.prop_values()[idx].setter;
                return {
                    .kind = PropLookupKind.PROP_ACCESSOR,
                    .acc = {
                        .accessor_fn = accessor_fn,
                        .this_obj = self,
                        .found = true
                    }
                };
            }
            return {
                .kind = PropLookupKind.PROP_DATA,
                .data_val = cur.prop_values()[idx].data.value,
                .owner = cur
            };
        }
        cur = cur.prototype;
        depth++;
    }

    return { .kind = PropLookupKind.PROP_NOT_FOUND };
}

/// Check whether the property exists anywhere on the prototype chain.
fn bool HObject.has_prop_proto(&self, void* key) {
    HObject* cur = self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        if (cur.find_prop_idx(key) >= 0) {
            return true;
        }
        cur = cur.prototype;
        depth++;
    }

    return false;
}

/// Returns true if `probe` appears anywhere in the prototype chain of `self`.
fn bool HObject.is_prototype_of(&self, HObject* probe) {
    HObject* cur = self;
    uint depth = 0;
    while (cur != null && depth < MAX_PROTO_DEPTH) {
        if (cur == probe) return true;
        cur = cur.prototype;
        depth++;
    }
    return false;
}

/// ES5 [[Delete]]: remove an own property.
///
/// Returns true if the property was successfully removed or not found.
/// Returns false only if the property exists and is non-configurable.
/// The caller is responsible for throwing in strict mode when false.
fn bool HObject.es_delete_prop(&self, void* key) {
    int idx = self.find_prop_idx(key);
    if (idx < 0) {
        return true;  // Not found → [[Delete]] returns true.
    }
    if (!self.prop_values()[idx].flags.configurable) {
        return false;  // Non-configurable → [[Delete]] returns false.
    }
    return self.delete_prop(key);
}

// ============================================================================
// Utility: next power of two
// ============================================================================

/// Returns the smallest power of two ≥ `v`.  If `v` is 0 returns 1.
fn uint next_power_of_two(uint v) @inline {
    if (v == 0) { return 1; }
    uint n = v - 1;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    return n + 1;
}
