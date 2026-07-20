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
import std::core::mem::mempool;
import std::io;

// Faults for optional returns
faultdef PROP_NOT_FOUND;
faultdef OBJ_ALLOC_FAULT;

/// Active heap pointer. Set during heap init, nulled during teardown.
/// Replaces the per-object heap_ptr field (8 bytes/object).
void* _active_heap;

/// Called by heap::init() — records the active heap for RC operations and shape transitions.
fn void hobject_set_active_heap(void* heap) {
    _active_heap = heap;
}

/// Called by heap::destroy() and heap::reset() before teardown — prevents
/// hobject_free from doing string RC during teardown.
fn void hobject_clear_active_heap() {
    _active_heap = null;
}

// ============================================================================
// Constants
// ============================================================================

/// Cached pointer to the interned "length" string, set during heap init.
/// Used by put_prop to sync array_length on LENGTH writes.
void* builtin_length_key = null;

/// Default is false. Pass `-D NOSHAPECACHE` to drop the 8-byte shape pointer cache.
const bool USE_SHAPE_CACHE = !$feature(NOSHAPECACHE);

/// Number of PropValue slots embedded inline in the object allocation.
/// Objects with 0-4 named properties (the common case) avoid a separate
/// prop_alloc malloc.  The inline storage lives at the end of the object
/// allocation (after HObjectBase + optional subtype fields).
const uint INLINE_PROPS = 4;

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
    REFLECT,
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
    BIGINT64ARRAY,
    BIGUINT64ARRAY,
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
    REGEXP_STRING_ITERATOR,
    /// Internal GC cell for boxed accessor pairs (getter + setter).
    GETTER_SETTER,
}

/// Discriminator for a callable object's invocation kind.
/// Inferred by HObject.callable_kind() from flags.is_bound,
/// builtin_fn_index, and comp_func.  Meaningful only when
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
    /// Set when pool allocation was exhausted and this object fell back to malloc.
    bool pool_fallback     : 22;
    /// Object is the Date.prototype — a DATE-class object that does NOT have
    /// a [[DateValue]] internal slot. Used by date_this_time_value to
    /// distinguish Date.prototype (must throw TypeError) from a Date instance
    /// with NaN time value (must return NaN).
    bool is_date_proto     : 23;
    /// True for async/await resume/reject builtin functions, whose var_env
    /// stores a GeneratorState* that must be kept alive by GC.
    bool is_async_state    : 24;
    /// True for ARRAY objects whose exotic "length" property is writable.
    /// The ARRAY exotic stores length in array_len_ptr (not the prop table),
    /// so when no named "length" property exists this flag is the source of
    /// truth for [[Writable]] of length (ES6 §9.4.2.1 / §10.4.2.1). Set
    /// false by Object.freeze and Object.defineProperty(arr,"length",{writable:false}).
    bool array_len_writable : 25;
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

/// Writable, enumerable, non-configurable data property.
/// Used for global `var`/FunctionDeclaration bindings (ES2015
/// §8.1.1.4.15 CreateGlobalVarBinding / §8.1.1.4.17
/// CreateGlobalFunctionBinding): the global object's own property for a
/// script-level var/function is non-configurable so it cannot be deleted,
/// but remains writable and enumerable.
const PropFlags PROP_FLAGS_WE = {
    .writable     = true,
    .enumerable   = true,
    .configurable = false,
    .is_accessor  = false
};

/// Convenience constant: non-configurable data property (writable, enumerable).
/// Used for ES2015 class constructor .prototype property (ES6 §14.5.14
/// step 25): writable=true, enumerable=false, configurable=false.
const PropFlags PROP_FLAGS_WENC = {
    .writable     = true,
    .enumerable   = false,
    .configurable = false,
    .is_accessor  = false
};

/// Convenience constant: accessor property (enumerable, configurable).
/// Used for getter/setter properties in object literals.
const PropFlags PROP_FLAGS_ACCESSOR = {
    .writable     = false,
    .enumerable   = true,
    .configurable = true,
    .is_accessor  = true
};

/// Class accessor property: non-enumerable, configurable.
/// Per ES2015 §14.5.14 step 9, class accessor descriptors are
/// {enumerable:false, configurable:true}.
const PropFlags PROP_FLAGS_CLASS_ACCESSOR = {
    .writable     = false,
    .enumerable   = false,
    .configurable = true,
    .is_accessor  = true
};

/// Class method property: writable, non-enumerable, configurable.
/// Per ES2015 §14.5.14 step 9, class method descriptors are
/// {writable:true, enumerable:false, configurable:true}.
const PropFlags PROP_FLAGS_CLASS_METHOD = {
    .writable     = true,
    .enumerable   = false,
    .configurable = true,
    .is_accessor  = false
};

/// Private accessor property: non-enumerable, non-configurable.
/// Per ES2022 §7.3.28 PrivateMethodOrAccessorAdd (via PrivateElement),
/// private accessors are not configurable — unlike public class accessors
/// (PROP_FLAGS_CLASS_ACCESSOR), which remain configurable.
const PropFlags PROP_FLAGS_PRIVATE_ACCESSOR = {
    .writable     = false,
    .enumerable   = false,
    .configurable = false,
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
// PropValue — per-object property value storage
// ============================================================================

/// Each property slot is a single TVal (8 bytes nanboxed).
/// For data properties the TVal holds the value directly.
/// For accessor properties the TVal stores a TAG_OBJECT pointer to a
/// GetterSetter HObject (ObjClass.GETTER_SETTER).
/// The Shape.PropFlags.is_accessor flag tells readers how to interpret
/// the slot.
alias PropValue = TVal;

// ---------------------------------------------------------------------------
// Boxed accessor pair helpers
// ---------------------------------------------------------------------------

/// Allocate a GetterSetter GC cell and return it as a TAG_OBJECT TVal.
/// The getter and setter are increffed by the caller's tval_copy_ref.
fn TVal hobject_create_accessors(heap::Heap* h, TVal getter, TVal setter) {
    HObject*? gs_obj = h.alloc_object(ObjClass.GETTER_SETTER);
    if (try gs = gs_obj) {
        (*gs.extra_ptr()).gs.getter = getter;
        (*gs.extra_ptr()).gs.setter = setter;
        // incref the getter and setter since the GS cell now holds references
        if (getter.is_heap_allocated() && getter.get_heapptr() != null) {
            ((types::HeapHeader*)getter.get_heapptr()).incref();
        }
        if (setter.is_heap_allocated() && setter.get_heapptr() != null) {
            ((types::HeapHeader*)setter.get_heapptr()).incref();
        }
        return types::make_object(gs);
    }
    return types::make_undefined();
}

/// Extract the getter from a boxed accessor slot.
fn TVal hobject_access_getter(TVal slot) {
    HObject* gs = (HObject*)slot.get_heapptr();
    return (*gs.extra_ptr()).gs.getter;
}

/// Extract the setter from a boxed accessor slot.
fn TVal hobject_access_setter(TVal slot) {
    HObject* gs = (HObject*)slot.get_heapptr();
    return (*gs.extra_ptr()).gs.setter;
}

/// Update the getter inside an existing GetterSetter cell (refcounted).
fn void hobject_set_access_getter(TVal slot, TVal new_getter, heap::Heap* h) {
    HObject* gs = (HObject*)slot.get_heapptr();
    h.decref_tval(&(*gs.extra_ptr()).gs.getter);
    (*gs.extra_ptr()).gs.getter = new_getter;
    if (new_getter.is_heap_allocated() && new_getter.get_heapptr() != null) {
        ((types::HeapHeader*)new_getter.get_heapptr()).incref();
    }
}

/// Update the setter inside an existing GetterSetter cell (refcounted).
fn void hobject_set_access_setter(TVal slot, TVal new_setter, heap::Heap* h) {
    HObject* gs = (HObject*)slot.get_heapptr();
    h.decref_tval(&(*gs.extra_ptr()).gs.setter);
    (*gs.extra_ptr()).gs.setter = new_setter;
    if (new_setter.is_heap_allocated() && new_setter.get_heapptr() != null) {
        ((types::HeapHeader*)new_setter.get_heapptr()).incref();
    }
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
    /// Arrow functions only (ES2015 §9.2.1 [[ThisMode]] = lexical): the
    /// enclosing activation's `this` at CLOSURE-creation time, captured once
    /// and reused for every future call regardless of how the arrow is later
    /// invoked (bare call, .call/.apply, builtin callback thisArg, or a call
    /// routed through vm_call_fn_impl's nested-Vm.run boundary). Undefined /
    /// unused for non-arrow functions. Placed after builtin_fn_index so
    /// HObjectProxy's builtin_fn_index (which overlays this struct) keeps
    /// the same offset.
    TVal              captured_this;
    /// Arrow functions only (ES2015 §9.2.1 [[NewTarget]] = lexical): the
    /// enclosing function's new.target at CLOSURE-creation time. Like
    /// captured_this it must survive the enclosing frame returning, so a
    /// runtime activation-chain walk cannot recover it. null when the
    /// enclosing invocation had no new.target (plain/method call) or for
    /// non-arrow functions.
    HObject*          captured_new_target;
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
    /// When false, `regexp_data` is a *borrowed* reference into a shared,
    /// refcounted compiled bytecode (e.g. a NEWREGEXP literal cache); this
    /// object still holds one ref (taken via re_ref) and drops it via re_free
    /// on finalize, exactly like an owner. The flag exists so future logic can
    /// distinguish shared from exclusively-owned bytecode; both call re_free,
    /// which only frees at refcount zero. Zero-initialized memory yields
    /// false, so every creation site must set this explicitly.
    bool              owns_data;
}

/// Generator: suspended execution state + captured env.
struct HObjectGenerator {
    void*             generator_data;
    CompiledFunction* comp_func;
    EnvRecord*        var_env;
    EnvRecord*        lex_env;
}

/// Promise: internal state, result, and pending reaction list.
/// Reactions are linked HObjects (allocated as ObjClass.OBJECT) so that
/// user code cannot reach or mutate the promise's state via the property
/// table — Promise state lives entirely in the HObjectExtra union slot
/// keyed by flags.obj_class == PROMISE.
struct HObjectPromise {
    uint      state;             // 0=pending, 1=fulfilled, 2=rejected
    TVal      result;            // resolved value or rejection reason
    HObject*  reactions_head;    // linked list of reaction records
    HObject*  reactions_tail;    // tail pointer (O(1) append)
}

/// Array/Map/Set iterator state.
/// Active when flags.obj_class is ARRAY_ITERATOR, MAP_ITERATOR, or SET_ITERATOR.
///
/// STRING_ITERATOR is a special case: it stores the iterated string in
/// extra.prim.primitive_value (bytes 0-7) for GC tracing, and the current
/// position in extra.iter.index (bytes 8-11).  The two fields occupy
/// non-overlapping byte ranges within the union, so the overlap is safe.
struct HObjectIterator {
    HObject*          target;   /// The iterated object (array, Map, or Set).
    uint              index;    /// Current iteration position.
    uint              kind;     /// 0=values, 1=keys, 2=entries.
}

/// RegExpStringIterator: lazy iteration over regexp matches.
/// Active when flags.obj_class is REGEXP_STRING_ITERATOR.
/// Stores the iterated string (for GC tracing) and the regexp.
struct HObjectRegExpStringIterator {
    TVal     string_val;   /// The string being iterated (for GC tracing).
    HObject* regexp;       /// The RegExp object.
    uint     flags;        /// Bit 0: global flag; bit 1: done flag.
}

/// Proxy exotic object: [[ProxyTarget]] + [[ProxyHandler]].
/// Active when obj_class == PROXY.  Both are null once the proxy is revoked.
/// builtin_fn_index overlays HObjectFunction.builtin_fn_index so that a
/// callable proxy dispatches through the ordinary BUILTIN_FN call path
/// (set to the proxy call/construct builtin at creation for callable targets).
struct HObjectProxy {
    HObject* target;
    HObject* handler;
    void*    _reserved;          // keeps builtin_fn_index at the same offset as HObjectFunction
    int      builtin_fn_index;
}

/// Boxed accessor pair (getter + setter) stored in a GC-managed HObject
/// with ObjClass.GETTER_SETTER.  Referenced from prop_values[] slots
/// when PropFlags.is_accessor is true.
struct HObjectGetterSetter {
    TVal getter;
    TVal setter;
}

/// ArrayBuffer backing store. Active when obj_class == ARRAYBUFFER.
/// Detach sentinel: byte_length == 0xFFFFFFFF (UINT32_MAX) marks a detached buffer.
/// A live zero-length buffer has data==null and byte_length==0.
struct HObjectArrayBuffer {
    char*    data;          // heap.alloc_func'd, zeroed; null when detached or zero-length
    uint     byte_length;   // byte length; set to 0xFFFFFFFF on detach
    HObject* views_head;    // intrusive list of views (via HObjectBufferView.next_view)
}

/// TypedArray or DataView. Active for INT8ARRAY..FLOAT64ARRAY and DATAVIEW.
struct HObjectBufferView {
    HObject* buffer;        // backing ARRAYBUFFER object (GC-traced)
    HObject* next_view;     // intrusive list link (buffer.extra.ab.views_head chain)
    uint     byte_offset;
    uint     byte_length;   // in BYTES
}

/// Tagged union of subtype-specific fields.
/// Discriminator is flags.obj_class (in the common header).
union HObjectExtra {
    HObjectFunction              func;
    HObjectPrimitive             prim;
    HObjectRegExp                regexp;
    HObjectGenerator             gen;
    HObjectPromise               promise;
    HObjectIterator              iter;
    HObjectRegExpStringIterator  regexp_iter;
    HObjectGetterSetter          gs;
    HObjectProxy                 proxy;
    HObjectArrayBuffer           ab;
    HObjectBufferView            view;
    uint                         array_length;  // For ARRAY objects: dense-element count.
}

/// The core ECMAScript object representation.
///
/// Memory layout uses inline struct subtyping: HObjectBase's fields are
/// flattened into HObject via `inline HObjectBase base`.  The first fields
/// (flags, GC pointers) are binary-compatible with HeapHeader for raw casts.
///
/// Subtype-specific fields (function, primitive wrapper, regexp, generator,
/// and iterator state) are stored in a union to save memory — only one
/// variant is active at a time, discriminated by flags.obj_class.
///
/// Property storage uses QuickJS-style shapes: property names and flags
/// live in the shared Shape, objects only store values.
/// Common prefix of all HObject variants.  Every object starts with these fields,
/// allowing the GC to walk linked lists and access shapes/properties at fixed offsets.
/// Plain objects (OBJECT, ERROR, ARGUMENTS) allocate only this prefix (72 bytes).
/// Other classes add trailing data after HObjectBase.
///
/// HObject includes this via `inline HObjectBase base`, which flattens
/// the fields into HObject's layout — no duplicate definitions needed.
/// The HeapHeader-compatible prefix is preserved at offset 0.
struct HObjectBase {
    ObjFlags      flags;
    uint          refcount;
    HeapHeader*   next;
    HeapHeader*   prev;
    HObject*      prototype;
    ushort        shape_id;
    Shape*        shape @if(USE_SHAPE_CACHE);
    ushort        prop_capacity;
    ushort        prop_count;
    uint          array_size;
    uint          array_used;
    void*         prop_alloc;
    PropHashInfo* prop_hash;
}

/// The core ECMAScript object representation.
///
/// Uses inline struct subtyping: the base prefix (flags, refcount, GC
/// pointers, shape, property storage) is inherited from HObjectBase via
/// C3's `inline` keyword.  This flattens HObjectBase's fields directly
/// into HObject so that `self.flags`, `self.prop_count`, etc. work
/// without qualification, while keeping HObjectBase::size correct for
/// trailing-data offset calculations.
///
/// Subtype-specific fields live in a union (HObjectExtra) discriminated
/// by flags.obj_class.
struct HObject {
    inline HObjectBase base;
    HObjectExtra      extra;       // offset 64 — includes array_length for ARRAY objects
}

// ============================================================================
// HObject — Per-class allocation sizes and trailing-data accessors
// ============================================================================

/// Pool size classes — derived from actual struct sizes plus inline prop space.
const usz INLINE_EXTRA = INLINE_PROPS * PropValue::size;
const usz OBJ_SIZE_PLAIN = HObjectBase::size + INLINE_EXTRA;                            // OBJECT, ERROR, ARGUMENTS
const usz OBJ_SIZE_ARRAY = HObjectBase::size + HObjectExtra::size + INLINE_EXTRA;       // ARRAY (array_length now in union)
const usz OBJ_SIZE_FUNC  = HObjectBase::size + HObjectExtra::size + INLINE_EXTRA;       // FUNCTION, REGEXP, etc.
const usz OBJ_SIZE_GS    = HObjectBase::size + HObjectGetterSetter::size;                // GETTER_SETTER (no inline props)

/// Allocation size for each object class.
/// Includes INLINE_PROPS slots at the tail for small objects (0-4 properties),
/// eliminating a separate prop_alloc malloc for the common case.
/// Plain objects: HObjectBase + inline props (136 bytes).
/// ARRAY: HObjectBase + HObjectExtra + inline props (array_length in union).
/// Others: HObjectBase + HObjectExtra + inline props (168 bytes).
fn usz alloc_size_for_class(ObjClass cls) @inline {
    switch (cls) {
        case ObjClass.OBJECT:
        case ObjClass.ERROR:
        case ObjClass.ARGUMENTS:
            return OBJ_SIZE_PLAIN;
        case ObjClass.PROXY:
            return OBJ_SIZE_FUNC;
        case ObjClass.ARRAY:
            return OBJ_SIZE_ARRAY;
        case ObjClass.GETTER_SETTER:
            return OBJ_SIZE_GS;
        default:
            return OBJ_SIZE_FUNC;
    }
}

/// Accessor for subtype-specific fields.  Returns a reference to the
/// HObjectExtra union at offset HObjectBase::size from the object.
/// Valid for FUNCTION, GENERATOR, REGEXP, BOOLEAN, NUMBER, STRING, DATE,
/// THREAD, and *_ITERATOR classes.
fn HObjectExtra* HObject.extra_ptr(&self) @inline {
    return (HObjectExtra*)((char*)self + HObjectBase::size);
}

/// Accessor for array_length.  Returns a pointer to extra.array_length
/// (first 4 bytes of the HObjectExtra union at offset HObjectBase::size).
/// Only valid for ARRAY objects (flags.exotic_array).
fn uint* HObject.array_len_ptr(&self) @inline {
    return &self.extra.array_length;
}

// ============================================================================
// Pool allocation helpers
// ============================================================================

/// Select the correct pool for a given object class.
/// Returns a pointer to the pool, or null if the class has no pool.
fn void* pool_for_class(void* heap_ptr, ObjClass cls) @inline {
    heap::Heap* h = (heap::Heap*)heap_ptr;
    switch (cls) {
        case ObjClass.OBJECT:
        case ObjClass.ERROR:
        case ObjClass.ARGUMENTS:
            return &h.obj_pool_plain;
        case ObjClass.ARRAY:
            return &h.obj_pool_array;
        case ObjClass.GETTER_SETTER:
            return &h.obj_pool_func;
        default:
            return &h.obj_pool_func;
    }
}

// ============================================================================
// HObject — Unified property allocation helpers
// ============================================================================

/// Compute total size of the property allocation block.
/// When prop_alloc is null, the inline storage has no array part.
fn usz HObject.prop_alloc_size(&self) {
    if (self.prop_alloc == null) {
        return (usz)self.prop_capacity * PropValue::size;
    }
    usz size = (usz)self.prop_capacity * PropValue::size;
    size += (usz)self.array_size * TVal::size;
    return size;
}

/// Returns pointer to the inline prop storage (at end of object allocation).
/// Only valid when prop_alloc == null.
fn PropValue* HObject.inline_props_ptr(&self) @inline {
    usz base_size = alloc_size_for_class(self.flags.obj_class) - INLINE_PROPS * PropValue::size;
    return (PropValue*)((char*)self + base_size);
}

/// Returns pointer to the property values array.
/// Uses inline storage when prop_alloc is null (small objects, 0-4 props),
/// otherwise returns the heap-allocated block.
fn PropValue* HObject.prop_values(&self) @inline {
    if (self.prop_alloc != null) return (PropValue*)self.prop_alloc;
    return self.inline_props_ptr();
}

/// Returns pointer to the dense array part (derived from prop_alloc).
/// Returns null when there is no array part (prop_alloc is null for
/// small objects, or array_size is 0).
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
// HObject — shape accessors
// ============================================================================

/// Get the Shape pointer for this object.
/// With NOSHAPECACHE: dereferences through heap->shapes[shape_id].
/// Without: returns the cached self.shape pointer.
fn Shape* HObject.get_shape(&self) @inline {
$if USE_SHAPE_CACHE:
    return self.shape;
$else
    heap::Heap* h = (heap::Heap*)_active_heap;
    if (h == null) return null;
    if (self.shape_id >= h.shape_count) return null;
    return h.shapes[self.shape_id];
$endif
}

/// Set the Shape pointer for this object.
/// With NOSHAPECACHE: writes to self.shape.
/// Without: no-op (shape is derived from shape_id).
fn void HObject.set_shape(&self, Shape* sh) @inline {
$if USE_SHAPE_CACHE:
    self.shape = sh;
$endif
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

/// Infer the callable kind from existing fields — no stored field needed.
fn CallableKind HObject.callable_kind(&self) @inline {
    if (self.flags.is_bound) return CallableKind.BOUND_FN;
    if ((*self.extra_ptr()).func.builtin_fn_index >= 0) return CallableKind.BUILTIN_FN;
    if ((*self.extra_ptr()).func.comp_func != null) return CallableKind.COMPILED_FN;
    return CallableKind.OTHER;
}

/// Seal the object: clear extensible, mark all own properties as
/// non-configurable.
///
/// Dense array elements are moved to the named property table because the
/// flat array part can't store non-default per-element flags (no PropFlags
/// per slot).  After sealing, the array part is abandoned (array_size = 0).
fn void HObject.seal(&self) {
    self.flags.extensible = false;

    // Abandon dense array part: move elements to named properties with
    // non-configurable flag.  The flat array part stores only TVals, not
    // per-element flags, so we need the property table for the flag change.
    if (self.array_part() != null && self.array_used > 0 && _active_heap != null) {
        heap::Heap* h = (heap::Heap*)_active_heap;
        char[12] digit_buf;
        for (uint i = 0; i < self.array_size; i++) {
            TVal v = self.array_part()[i];
            if (!v.is_undefined()) {
                int dlen = (int)(io::bprintf(&digit_buf, "%d", i) ?? digit_buf[:0]).len;
                if (dlen > 0) {
                    HString* key = h.str_intern(digit_buf[:(uint)dlen]);
                    if (key != null) {
                        // writable=true, enumerable=true, configurable=false
                        self.put_prop((void*)key, v, PROP_FLAGS_NEC);
                    }
                }
            }
        }
    }

    self.array_size = 0;
    self.array_used = 0;

    self.make_shape_private();
    for (uint i = 0; i < self.prop_count; i++) {
        PropFlags f = self.get_prop_flags(i);
        f.configurable = false;
        self.set_prop_flags(i, f);
    }
}

/// Freeze the object: seal + mark all data properties non-writable.
fn void HObject.freeze(&self) {
    self.seal();
    for (uint i = 0; i < self.prop_count; i++) {
        PropFlags f = self.get_prop_flags(i);
        if (!f.is_accessor) {
            f.writable = false;
            self.set_prop_flags(i, f);
        }
    }
    // ARRAY exotic: the "length" property lives in array_len_ptr, not the
    // property table, so the per-property loop above does not touch it.
    // ES5 §15.4.5.1 / §10.4.2.1 require the exotic "length" to become
    // non-writable on freeze so that Set(O, "length", _, true) throws.
    if (self.flags.exotic_array) {
        self.flags.array_len_writable = false;
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

/// Each entry in the per-object hash table for fast property lookup.
struct HashEntry {
    void* key;
    uint  index;
}

/// Per-object hash table metadata.  Allocated on the heap when
/// prop_count >= HASH_MIN_PROPS.  Stored as a single pointer in HObject
/// to save 8 bytes per object that never builds a hash table.
struct PropHashInfo {
    void* table;    /// Hash table entries buffer (HashEntry[])
    uint  mask;     /// (num_slots - 1)
    uint  count;    /// Cached prop_count when hash was built
}

/// Choose a hash mask for a given property count.
fn uint prop_hash_mask_for(uint prop_count) @inline {
    uint slots = 2;
    while (prop_count * 10 > slots * 7) {
        slots *= 2;
    }
    return slots - 1;
}

/// Allocate or grow the per-object hash table for property lookup.
fn void HObject.ensure_prop_hash(&self) {
    if (self.prop_count < HASH_MIN_PROPS) return;
    uint new_mask = prop_hash_mask_for(self.prop_count);
    // Skip if hash table is up-to-date and the right size
    if (self.prop_hash != null && self.prop_hash.count == self.prop_count && self.prop_hash.mask == new_mask) return;

    usz new_bytes = (usz)(new_mask + 1) * 16;
    void* new_table;
    if (_active_heap != null) {
        heap::Heap* h = (heap::Heap*)_active_heap;
        new_table = h.alloc_func(h.heap_udata, new_bytes);
    } else {
        new_table = alloc::malloc_try(mem, (sz)(new_bytes)) ?? null;
    }
    if (new_table == null) return;
    mem::clear(new_table, (sz)(new_bytes));

    HashEntry* entries = (HashEntry*)new_table;
    uint mask = new_mask;

    // Rebuild from the shape chain — the shape is the authoritative source
    // (during put_prop growth the new key is already in the shape, but not
    // yet in the old hash table).
    hobject::Shape* sh = self.get_shape();
    while (sh != null) {
        hobject::ShapeProperty* sp = sh.props();
        for (uint j = 0; j < sh.own_count; j++) {
            void* k = sp[j].key;
            if (k == null) continue;
            uint h = hash_key(k);
            uint slot = h & mask;
            while (entries[slot].key != null) slot = (slot + 1) & mask;
            entries[slot].key = k;
            entries[slot].index = sh.offset + j;
        }
        sh = sh.parent_shape;
    }

    if (self.prop_hash != null) {
        if (_active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            h.free_func(h.heap_udata, self.prop_hash.table);
        } else {
            mem::free(self.prop_hash.table);
        }
        self.prop_hash.mask = new_mask;
        self.prop_hash.count = self.prop_count;
        self.prop_hash.table = new_table;
    } else {
        PropHashInfo* phi;
        if (_active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            phi = (PropHashInfo*)h.alloc_func(h.heap_udata, PropHashInfo::size);
        } else {
            phi = (PropHashInfo*)alloc::malloc_try(mem, (sz)(PropHashInfo::size)) ?? null;
        }
        if (phi == null) {
            if (_active_heap != null) {
                heap::Heap* h = (heap::Heap*)_active_heap;
                h.free_func(h.heap_udata, new_table);
            } else {
                mem::free(new_table);
            }
            return;
        }
        phi.table = new_table;
        phi.mask = new_mask;
        phi.count = self.prop_count;
        self.prop_hash = phi;
    }
}

/// Get the property key at a given index by walking the shape chain.
/// Returns null if the index is out of range.
fn void* HObject.prop_key_at(&self, uint idx) @inline {
    hobject::Shape* sh = self.get_shape();
    while (sh != null) {
        if (idx >= sh.offset && idx < sh.offset + sh.own_count) {
            return sh.props()[idx - sh.offset].key;
        }
        sh = sh.parent_shape;
    }
    return null;
}

/// Get property flags at a given index by walking the shape chain.
/// Flags are authoritative in the ShapeProperty (kept in sync on writes).
fn PropFlags HObject.get_prop_flags(&self, uint idx) @inline {
    hobject::Shape* sh = self.get_shape();
    while (sh != null) {
        if (idx >= sh.offset && idx < sh.offset + sh.own_count) {
            return sh.props()[idx - sh.offset].flags;
        }
        sh = sh.parent_shape;
    }
    return {};
}

/// Make the current shape private to this object by flattening the shape chain
/// into a single standalone shape.  Does NOT register in the transition table,
/// so no other object will find this shape.
fn void HObject.make_shape_private(&self) {
    if (_active_heap == null || self.get_shape() == null) return;
    hobject::Shape* ns = shape_create(self.prop_count, 0, 0xFFFF_FFFF, null);
    if (ns == null) return;

    hobject::ShapeProperty* new_sp = ns.props();
    hobject::Shape* walk = self.get_shape();
    while (walk != null) {
        hobject::ShapeProperty* old_sp = walk.props();
        for (uint j = 0; j < walk.own_count; j++) {
            uint global_idx = walk.offset + j;
            new_sp[global_idx].key   = old_sp[j].key;
            new_sp[global_idx].flags = old_sp[j].flags;
        }
        walk = walk.parent_shape;
    }

    heap::Heap* h = (heap::Heap*)_active_heap;
    uint slot = h.alloc_shape_slot();
    if (slot != heap::SHAPE_NONE) {
        h.shapes[slot] = ns;
        self.shape_id = (ushort)slot;
        self.set_shape(ns);
    } else {
        // Keys were copied without incref; pass null so shape_free skips decref.
        shape_free(ns, null);
    }
}

/// Set flags for an existing property.  Makes the shape private first so that
/// changes don't leak to objects sharing the same shape.
/// Skips the expensive private-shape creation when flags already match.
fn void HObject.set_prop_flags(&self, uint idx, PropFlags new_flags) {
    // Fast path: flags already correct — no shape mutation needed.
    hobject::Shape* sh = self.get_shape();
    while (sh != null) {
        if (idx >= sh.offset && idx < sh.offset + sh.own_count) {
            if (sh.props()[idx - sh.offset].flags == new_flags) return;
            break;
        }
        sh = sh.parent_shape;
    }
    self.make_shape_private();
    sh = self.get_shape();
    while (sh != null) {
        if (idx >= sh.offset && idx < sh.offset + sh.own_count) {
            sh.props()[idx - sh.offset].flags = new_flags;
            return;
        }
        sh = sh.parent_shape;
    }
}

/// Find the index of the property with the given interned key.
/// Uses the per-object hash table if present, otherwise walks the shape chain.
fn int HObject.find_prop_idx(&self, void* key) {
    if (key == null || self.get_shape() == null || self.prop_count == 0) return -1;

    // Try hash table first
    if (self.prop_hash != null) {
        HashEntry* entries = (HashEntry*)self.prop_hash.table;
        uint mask = self.prop_hash.mask;
        uint h = hash_key(key);
        uint slot = h & mask;
        for (uint probes = 0; probes <= mask; probes++) {
            HashEntry* e = &entries[slot];
            if (e.key == null) return -1;
            if (e.key == key) return (int)e.index;
            slot = (slot + 1) & mask;
        }
        return -1;
    }

    // Walk shape chain for small objects
    hobject::Shape* sh = self.get_shape();
    while (sh != null) {
        hobject::ShapeProperty* sp = sh.props();
        for (uint i = 0; i < sh.own_count; i++) {
            if (sp[i].key == key) return (int)(sh.offset + i);
        }
        sh = sh.parent_shape;
    }
    return -1;
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
        // ARRAY / ARGUMENTS exotic: numeric-string keys ("0", "1", ...) are own
        // properties backed by the dense array part. Builtins like push() write
        // only via set_array_idx, so the property table alone cannot answer
        // string-index reads (mirrors the dense-part handling in delete_prop).
        TVal dense;
        if (self.dense_arridx_lookup(key, &dense)) {
            return dense;
        }
        return PROP_NOT_FOUND~;
    }
    return self.prop_values()[idx];
}

/// Look up an own property by key, returning a PropLookupResult that
/// distinguishes data properties from accessors. Unlike
/// get_prop_or_accessor_proto, this does NOT walk the prototype chain
/// and does NOT check proxy traps — used for private field access
/// (PrivateFieldGet) which must bypass proxy [[Get]].
fn PropLookupResult HObject.get_prop_or_accessor_own(&self, void* key, bool want_getter) {
    int idx = self.find_prop_idx(key);
    if (idx >= 0) {
        if (self.get_prop_flags((uint)idx).is_accessor) {
            TVal gs_slot = self.prop_values()[idx];
            TVal accessor_fn = want_getter ? hobject_access_getter(gs_slot) : hobject_access_setter(gs_slot);
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
            .data_val = self.prop_values()[idx],
            .owner = self
        };
    }
    // ARRAY / ARGUMENTS exotic: dense array part
    TVal dense;
    if (self.dense_arridx_lookup(key, &dense)) {
        return {
            .kind = PropLookupKind.PROP_DATA,
            .data_val = dense,
            .owner = null
        };
    }
    return { .kind = PropLookupKind.PROP_NOT_FOUND };
}

/// Look up an array-index string key ("0", "1", ...) in the dense array part
/// of an ARRAY / ARGUMENTS exotic object. Returns true and stores the value in
/// `out` when the slot exists and is not a hole (undefined = hole sentinel).
fn bool HObject.dense_arridx_lookup(&self, void* key, TVal* out) {
    if (key == null) return false;
    if (self.get_class() != hobject::ObjClass.ARRAY && self.get_class() != hobject::ObjClass.ARGUMENTS) return false;
    if (self.array_part() == null) return false;
    HString* hkey = (HString*)key;
    if (!hkey.is_arridx()) return false;
    uint ai = (uint)hkey.array_index();
    if (ai >= self.array_size) return false;
    TVal v = self.array_part()[ai];
    if (v.is_undefined()) return false;
    *out = v;
    return true;
}

/// Check whether the object has an own property with the given key.
fn bool HObject.has_prop(&self, void* key) {
    if (self.find_prop_idx(key) >= 0) return true;
    TVal dense;
    return self.dense_arridx_lookup(key, &dense);
}

/// Check whether a property is writable.
fn bool HObject.is_prop_writable(&self, void* key) {
    int idx = self.find_prop_idx(key);
    if (idx < 0) return true;
    return self.get_prop_flags((uint)idx).writable;
}

/// Decide whether an array-index write should grow the dense array part.
///
/// The dense part is a contiguous TVal backing, so growing it to a large
/// sparse index (e.g. `a[2**31] = x`) would allocate billions of empty slots
/// and exhaust memory. Sparse writes must instead go to the named-property
/// table. We route to the dense part only when the index stays reasonably
/// contiguous with the existing array: within a slack window past the current
/// dense size, or below a small absolute floor so fresh/small arrays still
/// grow densely. Beyond that, treat it as sparse.
const uint DENSE_GROW_FLOOR = 1024;        // always dense below this index
const uint DENSE_GROW_SLACK = 1u << 16;    // allow this much jump past array_size
fn bool dense_index_ok(uint cur_size, uint idx) {
    if (idx < DENSE_GROW_FLOOR) return true;
    // idx must not overshoot the current dense size by more than the slack.
    return idx <= cur_size + DENSE_GROW_SLACK;
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
        // Strings and BigInts are reference-counted leaves held by properties.
        if (_active_heap != null && (pv.is_string() || pv.is_bigint())) {
            ((heap::Heap*)_active_heap).decref_tval(pv);
        }
        *pv = val;
        if (_active_heap != null && (val.is_string() || val.is_bigint())) {
            void* ptr = val.get_heapptr();
            if (ptr != null) {
                ((types::HeapHeader*)ptr).incref();
            }
        }
        self.set_prop_flags((uint)idx, pflags);
        // Sync array_length shadow cache on LENGTH writes to ARRAY exotic
        if (self.flags.exotic_array && key == builtin_length_key) {
            if (val.is_fastint()) {
                *self.array_len_ptr() = (uint)val.get_fastint();
            } else if (val.is_number()) {
                *self.array_len_ptr() = (uint)val.get_number();
            }
        }
        // Sync numeric-string keys into the dense array part so that both
        // storage mechanisms (property table and dense array) stay consistent.
        // Array builtins like push() use set_array_idx() which only writes
        // to the dense part, while PUTPROP writes to the property table.
        // Without this sync, code that reads from one cannot see elements
        // stored via the other path.
        if (self.flags.exotic_array) {
            HString* ks = (HString*)key;
            if (ks.is_arridx()) {
                uint ks_idx = ks.array_index();
                if (ks_idx < self.array_size) {
                    self.set_array_idx(ks_idx, val);
                }
                if (ks_idx >= *self.array_len_ptr()) {
                    *self.array_len_ptr() = ks_idx + 1;
                }
            }
        }
        return true;
    }

    // --- New array-index element on an exotic array → dense part ---
    // A fresh integer-indexed write with the default data descriptor (WEC)
    // must grow the dense array part, not the named-property table.  The
    // named table is ushort-capped (65535 entries), so routing large indexed
    // writes there would silently truncate long arrays (e.g. `for (i…) a[i]=i`
    // past 2^16).  set_array_idx grows a separate uint-sized dense backing.
    if (self.flags.exotic_array && key != builtin_length_key) {
        HString* ks = (HString*)key;
        // Only route non-undefined values: the dense part uses `undefined` as
        // its hole sentinel, so it cannot distinguish an explicitly-stored
        // `undefined` element from an absent index.  Such writes fall through
        // to the named-property table, which records genuine presence.
        if (ks.is_arridx() && !val.is_undefined()
            && pflags.writable && pflags.enumerable && pflags.configurable
            && !pflags.is_accessor
            && dense_index_ok(self.array_size, ks.array_index())) {
            uint ks_idx = ks.array_index();
            if (self.set_array_idx(ks_idx, val)) {
                if (ks_idx >= *self.array_len_ptr()) {
                    *self.array_len_ptr() = ks_idx + 1;
                }
                return true;
            }
            // Dense growth failed (allocation/overflow) — fall through to the
            // named-property path as a best-effort fallback.
        }
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
    mem::clear(&self.prop_values()[new_idx], (sz)(PropValue::size));
    self.prop_values()[new_idx] = val;
    if (_active_heap != null && (val.is_string() || val.is_bigint())) {
        void* ptr = val.get_heapptr();
        if (ptr != null) {
            ((types::HeapHeader*)ptr).incref();
        }
    }
    self.prop_count++;

    // Sync array_length shadow cache on LENGTH writes to ARRAY exotic
    if (self.flags.exotic_array && key == builtin_length_key) {
        if (val.is_fastint()) {
            *self.array_len_ptr() = (uint)val.get_fastint();
        } else if (val.is_number()) {
            *self.array_len_ptr() = (uint)val.get_number();
        }
    }

    // Sync numeric-string keys into the dense array part (same rationale as
    // the update-existing path above).
    if (self.flags.exotic_array) {
        HString* ks = (HString*)key;
        if (ks.is_arridx()) {
            uint ks_idx = ks.array_index();
            if (ks_idx < self.array_size) {
                self.set_array_idx(ks_idx, val);
            }
            if (ks_idx >= *self.array_len_ptr()) {
                *self.array_len_ptr() = ks_idx + 1;
            }
        }
    }

    // --- Transition shape to include the new property ---
    // We already called find_prop_idx() above which confirmed the key is new,
    // so use transition_shape_new() which skips the O(N) chain walk.
    if (_active_heap != null) {
        heap::Heap* h = (heap::Heap*)_active_heap;
        ushort new_shape_id = h.transition_shape_new(self.shape_id, key);
        if (new_shape_id != self.shape_id) {
            self.shape_id = new_shape_id;
            self.set_shape(h.get_shape(new_shape_id));
        }
        // If the caller wants non-default flags, update the shape.
        // set_prop_flags handles making the shape private if shared.
        if (self.prop_count > 0) {
            PropFlags shape_f = self.get_prop_flags(new_idx);
            if (shape_f.writable != pflags.writable || shape_f.enumerable != pflags.enumerable ||
                shape_f.configurable != pflags.configurable || shape_f.is_accessor != pflags.is_accessor) {
                self.set_prop_flags(new_idx, pflags);
            }
        }
    }

    // Update the per-object hash table for the new property.
    // Direct insert avoids the malloc/free of a full rebuild on every put_prop.
    if (self.prop_count >= HASH_MIN_PROPS) {
        uint needed_mask = prop_hash_mask_for(self.prop_count);
        if (self.prop_hash == null) {
            // No hash table yet — build one from scratch
            self.ensure_prop_hash();
        } else if (self.prop_hash.mask != needed_mask) {
            // Hash table needs to grow — full rebuild
            self.ensure_prop_hash();
        } else {
            // Table is the right size — insert the new entry directly
            HashEntry* entries = (HashEntry*)self.prop_hash.table;
            uint mask = self.prop_hash.mask;
            uint h = hash_key(key);
            uint slot = h & mask;
            uint probes = 0;
            while (entries[slot].key != null && probes <= mask) {
                if (entries[slot].key == key) {
                    // Key already in table (shouldn't happen for new props, but be safe)
                    entries[slot].index = new_idx;
                    return true;
                }
                slot = (slot + 1) & mask;
                probes++;
            }
            if (entries[slot].key == null) {
                entries[slot].key = key;
                entries[slot].index = new_idx;
                self.prop_hash.count = self.prop_count;
            }
            // else: table is full (shouldn't happen with 70% load factor)
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
    // ARRAY / ARGUMENTS exotic: a numeric-string key may also be cached in
    // the dense array part (mirrors dense_arridx_lookup / get_prop). Clear
    // it so subsequent numeric-index reads don't see the stale value —
    // undefined is this codebase's hole sentinel for the dense part.
    if (key != null && (self.get_class() == hobject::ObjClass.ARRAY || self.get_class() == hobject::ObjClass.ARGUMENTS)) {
        HString* hkey = (HString*)key;
        if (hkey.is_arridx()) {
            uint ai = (uint)hkey.array_index();
            if (ai < self.array_size) {
                TVal undef; undef.set_undefined();
                self.set_array_idx(ai, undef);
            }
        }
    }

    int idx = self.find_prop_idx(key);
    if (idx < 0) {
        return false;
    }

    uint ui = (uint)idx;
    ushort new_count = (ushort)(self.prop_count - 1);

    // Compact prop_values: shift [ui+1..prop_count-1] → [ui..prop_count-2]
    for (uint i = ui; i < new_count; i++) {
        self.prop_values()[i] = self.prop_values()[i + 1];
    }
    mem::clear(&self.prop_values()[new_count], (sz)(PropValue::size));
    self.prop_count = new_count;

    // When all properties are removed, reuse the root shape (slot 0).
    // This avoids allocating a new private shape on every delete cycle,
    // which would exhaust the shape slot table (ushort limit = 65534).
    if (new_count == 0) {
        if (_active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            self.shape_id = 0;
            self.set_shape(h.shapes[0]);
        } else {
            self.set_shape(null);
        }
    } else {
        // Build a new private shape from the surviving properties.
        // We do NOT insert it into the transition table — it's object-specific.
        // Create a flat shape (own_count = all surviving props, offset = 0).
        Shape* ns = shape_create(new_count, 0, 0xFFFF_FFFF, null);
        if (ns != null) {
            // Collect surviving property names by walking the old shape chain.
            // The walk visits the newest shape first, so place each key at its
            // absolute index (minus one past the deleted slot) — appending in
            // walk order would reverse the key order relative to the values,
            // which were compacted in index order above.
            if (self.get_shape() != null) {
                ShapeProperty* new_sp = ns.props();
                Shape* walk = self.get_shape();
                while (walk != null) {
                    ShapeProperty* old_sp = walk.props();
                    for (uint j = 0; j < walk.own_count; j++) {
                        uint old_idx = walk.offset + j;
                        if (old_idx == ui) continue;
                        uint new_idx = old_idx < ui ? old_idx : old_idx - 1;
                        if (new_idx < new_count) {
                            new_sp[new_idx].key   = old_sp[j].key;
                            new_sp[new_idx].flags = old_sp[j].flags;
                        }
                    }
                    walk = walk.parent_shape;
                }
            }

            // Register with heap and attach to this object.
            if (_active_heap != null) {
                heap::Heap* h = (heap::Heap*)_active_heap;
                uint slot = h.alloc_shape_slot();
                if (slot != heap::SHAPE_NONE) {
                    h.shapes[slot] = ns;
                    self.shape_id = (ushort)slot;
                    self.set_shape(ns);
                } else {
                    // Keys were copied without incref; pass null so shape_free skips decref.
                    shape_free(ns, null);
                    self.set_shape(null);
                }
            } else {
                shape_free(ns, null);
                self.set_shape(null);
            }
        } else {
            self.set_shape(null);
        }
    }

    // Indexes after the deleted slot shifted down by one, so rebuild the
    // hash table from the new shape.
    if (self.prop_hash != null) {
        if (_active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            h.free_func(h.heap_udata, self.prop_hash.table);
            h.free_func(h.heap_udata, self.prop_hash);
        } else {
            mem::free(self.prop_hash.table);
            mem::free(self.prop_hash);
        }
        self.prop_hash = null;
        self.ensure_prop_hash();
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
/// Returns true on success, false when the index cannot be stored in the
/// dense part (overflow or grow failure) — callers should fall through to
/// the slow put_prop path in that case.
fn bool HObject.set_array_idx(&self, uint idx, TVal val) {
    // Grow if needed.
    if (idx >= self.array_size) {
        uint new_size = self.array_size;
        if (new_size == 0) {
            new_size = ARRAY_INITIAL_SIZE;
        }
        // Overflow-safe doubling: bail if we'd overflow uint on next multiply
        while (new_size <= idx) {
            if (new_size >= 0x80000000) { return false; }
            new_size *= 2;
        }
        self.grow_array(new_size);
        // If grow failed (array_size unchanged), bail out.
        if (idx >= self.array_size) {
            return false;
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

    if (_active_heap != null && (self.array_part()[idx].is_string() || self.array_part()[idx].is_bigint())) {
        ((heap::Heap*)_active_heap).decref_tval(&self.array_part()[idx]);
    }
    self.array_part()[idx] = val;
    if (_active_heap != null && (val.is_string() || val.is_bigint())) {
        void* ptr = val.get_heapptr();
        if (ptr != null) {
            ((types::HeapHeader*)ptr).incref();
        }
    }
    return true;
}

// ============================================================================
// HObject — growth / rehash
// ============================================================================

/// Grow the property value table when it is full.
/// When transitioning from inline storage (prop_alloc == null) to a
/// heap-allocated block, copies inline props and array data to the new block.
fn void HObject.grow_props(&self) {
    uint new_cap;
    if (self.prop_capacity <= INLINE_PROPS) {
        new_cap = PROPS_INITIAL_CAPACITY;
    } else {
        new_cap = self.prop_capacity * PROPS_GROW_NUM / PROPS_GROW_DEN;
        if (new_cap <= self.prop_capacity) {
            new_cap = self.prop_capacity + 4;
        }
    }
    // Cap at ushort max — objects with >65535 properties are pathological.
    if (new_cap > 65535) new_cap = 65535;

    usz new_prop_bytes = (usz)new_cap * PropValue::size;
    usz new_size = new_prop_bytes + (usz)self.array_size * TVal::size;

    void* new_raw;
    if (self.prop_alloc == null) {
        // Transition from inline to heap: allocate and copy inline data.
        if (_active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            new_raw = h.alloc_func(h.heap_udata, new_size);
        } else {
            new_raw = alloc::malloc_try(mem, (sz)(new_size)) ?? null;
        }
        if (new_raw == null) return;
        PropValue* inline_src = self.inline_props_ptr();
        mem::copy(new_raw, inline_src, (sz)((usz)self.prop_count * PropValue::size));
    } else {
        usz old_size = self.prop_alloc_size();
        usz old_prop_bytes = (usz)self.prop_capacity * PropValue::size;
        new_size = old_size - old_prop_bytes + new_prop_bytes;
        if (_active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            new_raw = h.realloc_func(h.heap_udata, self.prop_alloc, new_size);
        } else {
            new_raw = alloc::realloc_try(mem, self.prop_alloc, (sz)(new_size)) ?? null;
        }
    }
    if (new_raw == null) return;

    self.prop_alloc = new_raw;
    ushort old_prop_capacity = self.prop_capacity;
    self.prop_capacity = (ushort)new_cap;

    // prop_alloc may have moved — invalidate ICs that cached prop_value pointers.
    // (shape_id is unchanged, so the gen bump is what invalidates them.)
    if (_active_heap != null) {
        ((heap::Heap*)_active_heap).bump_shape_gen(self.shape_id);
    }

    // Move the dense array part to its new position before updating pointers.
    // When prop_capacity grows, the array data shifts right by the capacity
    // difference — realloc preserves old bytes in place, so we must move them.
    if (self.array_size > 0 && self.array_part() != null) {
        usz old_arr_off = (usz)old_prop_capacity * PropValue::size;
        usz new_arr_off = (usz)new_cap * PropValue::size;
        if (old_arr_off != new_arr_off) {
            mem::move((char*)self.prop_alloc + new_arr_off, (char*)self.prop_alloc + old_arr_off, (sz)((usz)self.array_size * TVal::size));
        }
    }

    if (new_cap > old_prop_capacity) {
        usz added_bytes = (usz)(new_cap - old_prop_capacity) * PropValue::size;
        void* start = (void*)((char*)self.prop_values() + (usz)old_prop_capacity * PropValue::size);
        mem::clear(start, (sz)(added_bytes));
    }
}

/// Grow the dense array part to at least `new_size` TVal slots.
///
/// New slots are initialised to undefined.
/// When prop_alloc is null (inline props), allocates a new heap block
/// and copies inline prop values to it.
fn void HObject.grow_array(&self, uint new_size) {
    if (new_size <= self.array_size) return;

    usz new_bytes = (usz)self.prop_capacity * PropValue::size + (usz)new_size * TVal::size;

    void* new_raw;
    if (self.prop_alloc == null) {
        // Transition from inline to heap: allocate and copy inline props.
        if (_active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            new_raw = h.alloc_func(h.heap_udata, new_bytes);
        } else {
            new_raw = alloc::malloc_try(mem, (sz)(new_bytes)) ?? null;
        }
        if (new_raw == null) return;
        PropValue* inline_src = self.inline_props_ptr();
        mem::copy(new_raw, inline_src, (sz)((usz)self.prop_count * PropValue::size));
    } else {
        if (_active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            new_raw = h.realloc_func(h.heap_udata, self.prop_alloc, new_bytes);
        } else {
            new_raw = alloc::realloc_try(mem, self.prop_alloc, (sz)(new_bytes)) ?? null;
        }
    }
    if (new_raw == null) return;

    self.prop_alloc = new_raw;
    usz old_array_size = self.array_size;
    self.array_size = new_size;

    usz added = (usz)(new_size - old_array_size);
    for (usz i = 0; i < added; i++) {
        self.array_part()[old_array_size + i].set_undefined();
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
/// The heap pointer is accessed via the module-level `_active_heap` instead
/// of a per-object field, saving 8 bytes per object.
///
/// Attempts pool allocation first (O(1) bump or freelist pop). Falls back
/// to malloc when the pool is exhausted; the pool_fallback flag is set so
/// hobject_free routes the free correctly.
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
    usz alloc_sz = alloc_size_for_class(cls);

    // Try pool allocation first
    void* raw = null;
    bool from_pool = false;
    void* pool = pool_for_class(heap_ptr, cls);
    if (pool != null) {
        raw = ((mem::mempool::FixedBlockPool*)pool).alloc();
        from_pool = true;
    }

    // Fall back to malloc when pool is exhausted or unavailable
    if (raw == null) {
        raw = ((heap::Heap*)heap_ptr).alloc(alloc_sz) ?? null;
        from_pool = false;
    }

    if (raw == null) {
        return OBJ_ALLOC_FAULT~;
    }

    // FixedBlockPool.alloc() zero-initializes via freelist path (mem::clear).
    // Bump-allocator path returns non-zeroed memory, so memset is still needed.
    mem::clear(raw, (sz)(alloc_sz));

    HObject* obj = (HObject*)raw;

    obj.prop_alloc = null;
    obj.prop_capacity = INLINE_PROPS;
    obj.prop_count = 0;

    obj.flags.htype        = HType.OBJECT;
    obj.flags.extensible   = true;
    obj.flags.obj_class    = cls;
    obj.flags.pool_fallback = !from_pool;
    obj.refcount           = 1;

    if (cls == ObjClass.FUNCTION) {
        obj.flags.callable      = true;
        obj.flags.constructable = true;
        (*obj.extra_ptr()).func.builtin_fn_index = -1;
    } else if (cls == ObjClass.ARRAY) {
        obj.flags.exotic_array = true;
        obj.flags.array_len_writable = true;
        obj.array_len_ptr()[0] = 0;
    } else if (cls == ObjClass.ARGUMENTS) {
        obj.flags.exotic_arguments = true;
    } else if (cls == ObjClass.PROXY) {
        obj.flags.exotic_proxyobj = true;
        (*obj.extra_ptr()).proxy.builtin_fn_index = -1;
    } else if (cls == ObjClass.GETTER_SETTER) {
        obj.prop_capacity = 0;  // no inline props for GS cells
    }

    obj.shape_id = 0;
    obj.set_shape(((heap::Heap*)heap_ptr).get_shape(0));  // root shape
    return obj;
}

/// Free an HObject and all of its owned sub-allocations (property table,
/// hash table, array part).
///
/// The caller must have already unlinked the object from the heap's GC list
/// and string table references.
///
/// Pool-allocated objects (flags.pool_fallback == false) are returned to
/// their FixedBlockPool for reuse.  Malloc-allocated objects are freed
/// via the heap's allocator (mem::free fallback when heap is inactive).
fn void hobject_free(HObject* obj, void* heap_ptr) {
    if (obj == null) { return; }

    if (obj.flags.obj_class == ObjClass.REGEXP && (*obj.extra_ptr()).regexp.regexp_data != null) {
        re_bindings::re_free((*obj.extra_ptr()).regexp.regexp_data);
        (*obj.extra_ptr()).regexp.regexp_data = null;
    }

    // Decref string held in Promise's resolved value / rejection reason.
    // Reactions are HObjects and managed by the GC mark-sweep cycle, so we
    // do not free them here.
    if (obj.flags.obj_class == ObjClass.PROMISE && _active_heap != null) {
        heap::Heap* h = (heap::Heap*)_active_heap;
        h.decref_tval(&(*obj.extra_ptr()).promise.result);
        (*obj.extra_ptr()).promise.reactions_head = null;
        (*obj.extra_ptr()).promise.reactions_tail = null;
    }

    // Free the ArrayBuffer's backing store (unless already detached).
    if (obj.flags.obj_class == ObjClass.ARRAYBUFFER && _active_heap != null) {
        heap::Heap* h = (heap::Heap*)_active_heap;
        if ((*obj.extra_ptr()).ab.data != null) {
            h.free_func(h.heap_udata, (*obj.extra_ptr()).ab.data);
            (*obj.extra_ptr()).ab.data = null;
        }
    }

    // Free the per-object property hash table.
    if (obj.prop_hash != null) {
        if (_active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            h.free_func(h.heap_udata, obj.prop_hash.table);
            h.free_func(h.heap_udata, obj.prop_hash);
        } else {
            mem::free(obj.prop_hash.table);
            mem::free(obj.prop_hash);
        }
    }

    // Decref getter/setter inside GetterSetter cells.
    if (obj.flags.obj_class == ObjClass.GETTER_SETTER && _active_heap != null) {
        heap::Heap* h = (heap::Heap*)_active_heap;
        h.decref_tval(&(*obj.extra_ptr()).gs.getter);
        h.decref_tval(&(*obj.extra_ptr()).gs.setter);
    }

    // Decref an arrow function's captured lexical `this`.
    if (obj.flags.obj_class == ObjClass.FUNCTION && _active_heap != null) {
        heap::Heap* h = (heap::Heap*)_active_heap;
        h.decref_tval(&(*obj.extra_ptr()).func.captured_this);
    }

    // Decref string and BigInt values held in property slots and array
    // elements.  Only these RC leaves are freed here — objects still use M&S
    // and can form cycles; decref-freeing objects from within another object's
    // teardown would corrupt the heap_allocated list and cause use-after-free
    // on generator/closure env chains.  BigInt boxes are leaves, so freeing
    // them here is safe.
    if (obj.prop_alloc != null && _active_heap != null) {
        heap::Heap* h = (heap::Heap*)_active_heap;
        PropValue* pvs = obj.prop_values();
        for (uint i = 0; i < obj.prop_count; i++) {
            if (pvs[i].is_string() || pvs[i].is_bigint()) {
                h.decref_tval(&pvs[i]);
            }
        }
        TVal* arr = obj.array_part();
        if (arr != null) {
            for (uint i = 0; i < obj.array_size; i++) {
                if (arr[i].is_string() || arr[i].is_bigint()) {
                    h.decref_tval(&arr[i]);
                }
            }
        }
    }

    // Free the unified property allocation block (prop_values + array_part).
    // Shape is shared and managed by the heap — do NOT free it here.
    if (obj.prop_alloc != null) {
        if (_active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            h.free_func(h.heap_udata, obj.prop_alloc);
        } else {
            mem::free(obj.prop_alloc);
        }
        obj.prop_alloc = null;
    }

    // Route the HObject header to pool or malloc depending on allocation source.
    if (obj.flags.pool_fallback) {
        if (_active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            h.free_func(h.heap_udata, obj);
        } else {
            mem::free(obj);
        }
    } else {
        void* pool = pool_for_class(heap_ptr, obj.flags.obj_class);
        if (pool != null) {
            ((mem::mempool::FixedBlockPool*)pool).dealloc(obj);
        } else {
            if (_active_heap != null) {
                heap::Heap* h = (heap::Heap*)_active_heap;
                h.free_func(h.heap_udata, obj);
            } else {
                mem::free(obj);
            }
        }
    }
}

// ============================================================================
// Enumeration helpers
// ============================================================================

/// Returns the number of own enumerable properties.
fn uint HObject.enumerable_count(&self) {
    uint count = 0;
    for (uint i = 0; i < self.prop_count; i++) {
        if (self.get_prop_flags(i).enumerable) {
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
        // Proxy exotic anywhere on the chain: route the whole [[Get]] through
        // the trap machinery (receiver = the original object).
        if (cur.flags.exotic_proxyobj && _active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            if (h.proxy_get_fn != null && h.vm_ptr != null) {
                TVal recv = types::make_object(self);
                TVal out;
                if (h.proxy_get_fn(h.vm_ptr, h, cur, key, recv, &out)) {
                    return out;
                }
            }
            return PROP_NOT_FOUND~;  // trap threw: error pending in heap
        }
        int idx = cur.find_prop_idx(key);
        if (idx >= 0) {
            return cur.prop_values()[idx];
        }
        // ARRAY / ARGUMENTS exotic: string-index keys may live only in the
        // dense array part (see get_prop).
        TVal dense;
        if (cur.dense_arridx_lookup(key, &dense)) {
            return dense;
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
            if (cur.get_prop_flags((uint)idx).is_accessor) {
                TVal gs_slot = cur.prop_values()[idx];
                TVal accessor_fn = want_getter ? hobject_access_getter(gs_slot) : hobject_access_setter(gs_slot);
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

/// ES5 §8.12.3 [[Get]] / ES2020 §10.1.8.1 OrdinaryGet.
/// Walks the prototype chain, invoking accessor getters and returning the
/// raw value or property-missing. Used by builtins that need full Get
/// semantics (e.g. Map/Set constructors looking up `set` / `add`).
fn PropLookupResult HObject.get_with_accessors(&self, void* key) {
    return self.get_prop_or_accessor_proto(key, true);
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
    /// Number of properties THIS shape contributes (not cumulative).
    uint      own_count;
    /// Offset into the object's prop_values where this shape's props start.
    uint      offset;
    /// Parent shape pointer for chain walking (null for root).
    Shape*    parent_shape;
}

// ============================================================================
// Shape — memory layout helpers
// ============================================================================

/// Get pointer to the ShapeProperty array (immediately after the header).
fn ShapeProperty* Shape.props(&self) {
    return (ShapeProperty*)((char*)self + Shape::size);
}

/// Return the total byte size of a shape allocation (no hash table).
fn usz shape_alloc_size(uint own_count) {
    return Shape::size + (usz)own_count * ShapeProperty::size;
}

/// Create a new shape with `own_count` own properties.
/// The shape stores only its OWN properties (delta from parent chain).
/// `offset` is the index in the object's prop_values where these start.
/// `parent_id` is the index of the parent shape (SHAPE_NONE for root).
/// `parent_shape` is the parent shape pointer (null for root).
fn Shape* shape_create(uint own_count, uint offset, uint parent_id, Shape* parent_shape) {
    usz bytes = shape_alloc_size(own_count);
    void* raw;
    if (_active_heap != null) {
        heap::Heap* h = (heap::Heap*)_active_heap;
        raw = h.alloc_func(h.heap_udata, bytes);
    } else {
        raw = alloc::malloc_try(mem, (sz)(bytes)) ?? null;
    }
    if (raw == null) return null;
    mem::clear(raw, (sz)(bytes));

    Shape* sh = (Shape*)raw;
    sh.generation   = 0;
    sh.parent       = parent_id;
    sh.own_count    = own_count;
    sh.offset       = offset;
    sh.parent_shape = parent_shape;

    return sh;
}

/// Create a new shape that extends `parent` by adding one property.
/// Only stores the NEW property (delta).  Returns null on allocation failure.
fn Shape* shape_extend(Shape* parent, uint parent_id, void* new_key, PropFlags flags) {
    uint offset = parent.offset + parent.own_count;
    Shape* ns = shape_create(1, offset, parent_id, parent);
    if (ns == null) return null;

    // Set the single new property
    ns.props()[0].key   = new_key;
    ns.props()[0].flags = flags;

    // Incref the key: this new shape holds a ref to the key.
    if (new_key != null) {
        ((types::HeapHeader*)new_key).incref();
    }

    return ns;
}

/// Free a shape allocation.
/// If heap_ptr is non-null, decrefs all property keys held by this shape.
/// Pass null at teardown to skip decref (when the string table is already being freed).
fn void shape_free(Shape* sh, void* heap_ptr) {
    if (sh == null) return;
    if (heap_ptr != null) {
        ShapeProperty* sp = sh.props();
        heap::Heap* h = (heap::Heap*)heap_ptr;
        for (uint i = 0; i < sh.own_count; i++) {
            if (sp[i].key != null) {
                h.decref((HeapHeader*)sp[i].key);
            }
        }
    }
    if (_active_heap != null) {
        heap::Heap* h = (heap::Heap*)_active_heap;
        h.free_func(h.heap_udata, sh);
    } else {
        mem::free(sh);
    }
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
    ushort shape_id;
    /// Property index within the owner's prop_values[].
    ushort prop_idx;
    /// Cached property flags (avoid shape walk on IC hit).
    PropFlags prop_flags;
    /// Prototype pointer where the property was found (null = own property).
    void*  proto;
    /// The interned key (HString*) this entry was populated for.
    /// Pointer equality is sufficient (interned strings).
    void*  key;
    /// Cached pointer to the resolved PropValue for direct access.
    /// Invalidated when prop_alloc is reallocated (prop_alloc comparison).
    TVal* prop_value_ptr;
    /// Snapshot of the owner's prop_alloc pointer at population time.
    /// IC hit requires this == owner.prop_alloc (single pointer comparison
    /// replaces the old generation-dereference chain).
    void*  cached_prop_alloc;
}

/// Global megamorphic property cache entry.
/// Shared across all call sites — keyed by (shape_id, key_ptr).
/// Avoids repeated prototype chain walks for polymorphic access patterns.
struct MegamorphicEntry {
    void*   key;           // interned key pointer (null = empty slot)
    ushort  shape_id;      // object shape ID at lookup time
    ushort  prop_idx;      // property index in owner.prop_values[]
    void*   proto;         // owning object (null = own property)
    TVal*   prop_value_ptr; // direct pointer to value slot
    void*   cached_prop_alloc; // owner.prop_values() snapshot for invalidation
}

/// Hash function for megamorphic cache lookup.
fn uint mega_hash(ushort shape_id, void* key) @inline {
    return ((uint)(uptr)key ^ ((uint)shape_id * 2654435761u)) & (heap::MEGA_CACHE_SIZE - 1);
}

/// Probe the megamorphic cache. Returns pointer to entry if hit, null if miss.
fn MegamorphicEntry* mega_cache_lookup(heap::Heap* h, HObject* hobj, void* key) @inline {
    if (h.mega_cache == null) return null;
    uint slot = mega_hash(hobj.shape_id, key);
    MegamorphicEntry* e = h.mega_cache + slot;
    if (e.key == key && e.shape_id == hobj.shape_id) {
        HObject* owner = e.proto == null ? hobj : (HObject*)e.proto;
        if (e.cached_prop_alloc == (void*)owner.prop_values()) {
            return e;
        }
    }
    return null;
}

/// Populate the megamorphic cache after a successful property lookup.
/// Only caches OWN property lookups (owner == hobj). Inherited lookups are not
/// cached because the cache has no way to detect modifications to intermediate
/// objects in the prototype chain (see the comment in vm.c3 GETPROP).
fn void mega_cache_store(heap::Heap* h, HObject* hobj, void* key, HObject* owner, int prop_idx) @inline {
    if (h.mega_cache == null) return;
    if (owner != hobj) return;  // don't cache inherited lookups
    uint slot = mega_hash(hobj.shape_id, key);
    MegamorphicEntry* e = h.mega_cache + slot;
    e.key = key;
    e.shape_id = hobj.shape_id;
    e.prop_idx = (ushort)prop_idx;
    e.proto = null;  // own property
    e.prop_value_ptr = &owner.prop_values()[prop_idx];
    e.cached_prop_alloc = (void*)owner.prop_values();
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
    ushort  shape_id;
    /// Generation of the shape at population time.
    uint    generation;
    /// Property index within bindings.props[].
    ushort  prop_idx;
    /// The interned key (HString*) this entry was populated for.
    void*   key;
    /// act.lex_env at population time; a hit requires the same chain head
    /// so entries never serve a different activation's environment.
    void*   search_head;
}

/// Single-pass prototype chain search: finds either an accessor or data property.
/// Returns the kind found. For accessors, sets `acc_out`; for data, sets `data_out`.
/// If `owner_out` is non-null, sets it to the object owning the found property.
fn PropLookupResult HObject.get_prop_or_accessor_proto(&self, void* key, bool want_getter) {
    HObject* cur = self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        // Proxy exotic on the chain: for getter searches, run the full [[Get]]
        // through the trap machinery and report the result as a data property
        // (owner = null so inline caches are not populated).  Setter searches
        // fall through to PROP_NOT_FOUND; [[Set]]-with-proxy-on-chain is
        // handled by the PUTPROP proxy chain check.
        if (cur.flags.exotic_proxyobj && want_getter && _active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            if (h.proxy_get_fn != null && h.vm_ptr != null) {
                TVal recv = types::make_object(self);
                TVal out;
                if (h.proxy_get_fn(h.vm_ptr, h, cur, key, recv, &out)) {
                    return { .kind = PropLookupKind.PROP_DATA, .data_val = out, .owner = null };
                }
            }
            return { .kind = PropLookupKind.PROP_NOT_FOUND };
        }
        if (cur.flags.exotic_proxyobj && !want_getter) {
            return { .kind = PropLookupKind.PROP_NOT_FOUND };
        }
        int idx = cur.find_prop_idx(key);
        if (idx >= 0) {
            if (cur.get_prop_flags((uint)idx).is_accessor) {
                TVal gs_slot = cur.prop_values()[idx];
            TVal accessor_fn = want_getter ? hobject_access_getter(gs_slot) : hobject_access_setter(gs_slot);
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
                .data_val = cur.prop_values()[idx],
                .owner = cur
            };
        }
        // ARRAY / ARGUMENTS exotic: string-index keys may live only in the
        // dense array part (see get_prop). Report without an owner so the
        // caller's inline cache is not populated (dense slots have no stable
        // prop_values pointer).
        TVal dense;
        if (cur.dense_arridx_lookup(key, &dense)) {
            return {
                .kind = PropLookupKind.PROP_DATA,
                .data_val = dense,
                .owner = null
            };
        }
        // ARRAY exotic: "length" lives in array_len_ptr, not props table.
        if (cur.get_class() == ObjClass.ARRAY && _active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            if (key == (void*)h.strs[heap::BuiltinStr.LENGTH]) {
                return {
                    .kind = PropLookupKind.PROP_DATA,
                    .data_val = types::make_fastint((long)*cur.array_len_ptr()),
                    .owner = null
                };
            }
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
        // Proxy exotic on the chain: route through the [[Has]] trap.
        if (cur.flags.exotic_proxyobj && _active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            if (h.proxy_has_fn != null && h.vm_ptr != null) {
                bool has;
                if (h.proxy_has_fn(h.vm_ptr, h, cur, key, &has)) {
                    return has;
                }
            }
            return false;
        }
        if (cur.find_prop_idx(key) >= 0) {
            return true;
        }
        // ARRAY exotic: "length" lives in array_len_ptr.
        if (cur.get_class() == ObjClass.ARRAY && _active_heap != null) {
            heap::Heap* h = (heap::Heap*)_active_heap;
            if (key == (void*)h.strs[heap::BuiltinStr.LENGTH]) {
                return true;
            }
        }
        // ARRAY / ARGUMENTS exotic: string-index keys may live only in the
        // dense array part (see get_prop).
        TVal dense;
        if (cur.dense_arridx_lookup(key, &dense)) {
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
    if (idx >= 0) {
        if (!self.get_prop_flags((uint)idx).configurable) {
            return false;  // Non-configurable → [[Delete]] returns false.
        }
        // delete_prop() clears the dense array slot (if any) as part of the
        // named-table removal.
        return self.delete_prop(key);
    }
    // ARRAY / ARGUMENTS exotic: numeric indices stored in the dense part are
    // own properties. Clear the dense slot so subsequent hasOwnProperty /
    // length / gopd reflect the deletion per spec [[Delete]].
    if (key != null && (self.get_class() == hobject::ObjClass.ARRAY || self.get_class() == hobject::ObjClass.ARGUMENTS)) {
        HString* hkey = (HString*)key;
        if (hkey.is_arridx()) {
            uint ai = (uint)hkey.array_index();
            if (ai < self.array_size) {
                TVal old = self.array_part()[ai];
                if (!old.is_undefined()) {
                    TVal undef; undef.set_undefined();
                    self.set_array_idx(ai, undef);
                }
            }
        } else if (self.get_class() == hobject::ObjClass.ARRAY) {
            // Special case: ARRAY "length" is a non-configurable own property
            // (spec §22.1.3). [[Delete]] returns false for it. We treat it as
            // non-configurable here so `delete Array.prototype.length` etc.
            // correctly fails.
            if (hkey.equals("length")) {
                return false;
            }
        }
    }
    return true;  // Not found (or cleared from dense) → [[Delete]] returns true.
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
