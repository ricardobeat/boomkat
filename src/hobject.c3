// HObject, the representation behind every ECMAScript object. Each carries a
// HeapHeader-compatible prefix of flags and GC list pointers, a prototype
// link, and a property table: a linear entry array plus a hash part for fast
// named lookup.
//
// Integer-indexed properties below `array_size` can live in a dense array
// part instead, so a dense JS array needs no PropEntry per element.
//
// Lookup takes the first of these that applies:
//   1. The key is an interned string naming an array index below `array_size`:
//      the array part answers it.
//   2. A hash table exists: hashing the key pointer gives an index into the
//      props array, then keys are compared.
//   3. Otherwise the props array is scanned linearly.
module boomkat::hobject;

import boomkat::types;
import boomkat::hstring;
import boomkat::hbigint;
import boomkat::bytecode;
import boomkat::env;
import boomkat::re_bindings;
import boomkat::heap;
import std::core::mem::mempool;
import std::io;

// Faults for optional returns
faultdef PROP_NOT_FOUND;
faultdef OBJ_ALLOC_FAULT;

// Read fields out of an opaque EnvRecord* for heap.c3, which marks saved scope
// chains during GC but cannot import env.c3 (env.c3 imports heap.c3).
fn HObject* env_record_bindings(void* env_ptr) {
    if (env_ptr == null) return null;
    return ((env::EnvRecord*)env_ptr).bindings;
}

// Read the `parent` link from an opaque EnvRecord*, so heap.c3 can mark a whole
// scope chain. EnvRecords are pool allocated and never collected, but each
// one's `bindings` HObject is an ordinary heap node: marking only the
// innermost link would leave enclosing scopes' bindings unmarked.
fn void* env_record_parent(void* env_ptr) {
    if (env_ptr == null) return null;
    return (void*)((env::EnvRecord*)env_ptr).parent;
}

// ============================================================================
// Constants
// ============================================================================

// PropValue slots carried inside the object allocation, after HObjectBase and
// any subtype fields. An object with no more than this many named properties,
// which is the common case, needs no separate prop_alloc.
const uint INLINE_PROPS = 4;

// Initial number of property entry slots when first allocated.
const uint PROPS_INITIAL_CAPACITY = 8;

// Initial dense array allocation size.
const uint ARRAY_INITIAL_SIZE = 16;

// Property table growth factor, as numerator over denominator, so 1.5x.
const uint PROPS_GROW_NUM = 3;
const uint PROPS_GROW_DEN = 2;

// Property count at which a hash table is worth building. Below it, the linear
// scan is faster.
const uint HASH_MIN_PROPS = 8;
// Entries a collection must hold before it builds a CollHashInfo. Below this
// the linear scan over array_part is faster than hashing, and most Maps and
// Sets in real code never reach it.
const uint COLL_HASH_MIN_ENTRIES = 8;
// Marks a probe slot whose entry was deleted. Probing must continue past it
// rather than stop, or a key inserted after the deletion becomes unreachable.
const uint COLL_SLOT_DELETED = 0xFFFFFFFF;

// Load factor as numerator over denominator. The table is rebuilt once
// prop_count passes hash_size * HASH_LOAD_NUM / HASH_LOAD_DEN.
const uint HASH_LOAD_NUM = 7;
const uint HASH_LOAD_DEN = 10;

// Sentinel value in the hash table: slot has never been used.
const uint HASH_UNUSED   = 0xFFFF_FFFF;

// Marks a flat shape owned by exactly one object and kept out of the
// transition table. Only such a shape may be reclaimed via free_shape_slot.
const uint PRIVATE_SHAPE_PARENT = 0xFFFF_FFFF;

// Sentinel value in the hash table: slot was deleted (tombstone).
const uint HASH_DELETED  = 0xFFFF_FFFE;

// ============================================================================
// ObjClass, the ECMAScript internal [[Class]]
// ============================================================================

// Which ECMAScript object class this is. ObjFlags stores it in 6 bits, so
// there is room for 64.
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
    // Object environment record (ES spec).
    OBJENV,
    // Declarative environment record (ES spec).
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
    FLOAT16ARRAY,
    FLOAT32ARRAY,
    FLOAT64ARRAY,
    BIGINT64ARRAY,
    BIGUINT64ARRAY,
    MAP,
    SET,
    WEAKMAP,
    WEAKSET,
    WEAKREF,
    FINALIZATION_REGISTRY,
    PROMISE,
    GENERATOR,
    ARRAY_ITERATOR,
    STRING_ITERATOR,
    MAP_ITERATOR,
    SET_ITERATOR,
    REGEXP_STRING_ITERATOR,
    // Iterator Helper (ES2025 §27.1.2), the lazy result of map, filter, take,
    // drop, or flatMap. Backed by HObjectIteratorHelper rather than a generator.
    ITERATOR_HELPER,
    // %WrapForValidIteratorPrototype% instance (ES2025 §27.1.3.2.2.1), created
    // by Iterator.from() to adapt a plain iterator and next pair.
    WRAP_FOR_VALID_ITERATOR,
    // Internal GC cell for boxed accessor pairs (getter + setter).
    GETTER_SETTER,
    // Temporal proposal (Stage 4, shipped in V8/Safari/JSC). One shared
    // HObjectTemporal variant backs every Temporal class; obj_class
    // discriminates which internal slots are live. Adding 9-11 entries
    // here consumes roughly a quarter of the remaining 6-bit ObjClass
    // namespace (39 currently used of 64). Phases 1a/1b/1c/1d/2 of the
    // Temporal plan add them incrementally; subsequent phases reuse the
    // existing classes for new types.
    TEMPORAL_CALENDAR,        // Temporal.Calendar (the shared ISO singleton)
    TEMPORAL_PLAIN_DATE,      // Temporal.PlainDate
    TEMPORAL_DURATION,        // Temporal.Duration
}

// How a callable object is invoked. HObject.callable_kind() infers it from
// flags.is_bound, builtin_fn_index, and comp_func. Only meaningful when
// flags.callable is set.
enum CallableKind : ushort {
    COMPILED_FN,        /// JS function, dispatched through comp_func
    BUILTIN_FN,         /// Native builtin, dispatched through builtin_fn_index
    BOUND_FN,           /// Bound function, dispatched through the bound-call path
    OTHER               /// Callable, but none of the above
}

// ============================================================================
// ObjFlags, the per-object bit-packed flags
// ============================================================================

// Bit-packed flags word for HObject.
//
// Bits 0 to 6 mirror HeapHeader's type and GC bits, so a raw cast from HObject*
// to HeapHeader* reads the right htype and mark bits. Bits 7 and up carry
// object-specific metadata.
bitstruct ObjFlags : uint {
    // HeapHeader-compatible type discriminator (always HType.OBJECT).
    HType htype            : 0..1;
    // GC reachable flag.
    bool  reachable        : 2;
    // GC temporary root flag.
    bool  temproot         : 3;
    // Finaliser present flag.
    bool  finalizable      : 4;
    // Finaliser already ran.
    bool  finalized        : 5;
    // Read-only flag.
    bool  readonly         : 6;

    // --- Object-specific flags (bits 7+) ---

    // [[Extensible]] internal slot.
    bool extensible        : 7;
    // Object can be used as a constructor (has [[Construct]]).
    bool constructable     : 8;
    // Object is callable (has [[Call]]).
    bool callable          : 9;
    // Bound function (created by Function.prototype.bind).
    bool is_bound          : 10;
    // Object has an attached C/JS finalizer.
    bool has_finalizer     : 11;
    // Exotic [[DefineOwnProperty]] for Array objects.
    bool exotic_array      : 12;
    // Exotic behaviour for String wrapper objects.
    bool exotic_stringobj  : 13;
    // Exotic behaviour for Arguments objects.
    bool exotic_arguments  : 14;
    // Exotic behaviour for Proxy objects.
    bool exotic_proxyobj   : 15;
    // Internal [[Class]] tag, 6 bits, so up to 64 classes.
    ObjClass obj_class     : 16..21;
    // Set when pool allocation was exhausted and this object fell back to malloc.
    bool pool_fallback     : 22;
    // Marks Date.prototype, a DATE-class object without a [[DateValue]] slot.
    // date_this_time_value uses it to throw a TypeError there, while a Date
    // instance holding a NaN time value returns NaN.
    bool is_date_proto     : 23;
    // True for async/await resume/reject builtin functions, whose var_env
    // stores a GeneratorState* that must be kept alive by GC.
    bool is_async_state    : 24;
    // True for ARRAY objects whose exotic "length" property is writable.
    // The ARRAY exotic stores length in array_len_ptr (not the prop table),
    // so when no named "length" property exists this flag is the source of
    // truth for [[Writable]] of length (ES6 §9.4.2.1 / §10.4.2.1). Set
    // false by Object.freeze and Object.defineProperty(arr,"length",{writable:false}).
    bool array_len_writable : 25;
    // [[IsRawJSON]], set on objects that JSON.rawJSON returns.
    // JSON.isRawJSON tests it; JSON.stringify embeds the "rawJSON" property
    // verbatim when serialising such an object.
    bool is_raw_json        : 26;
    // Set when any property other than a default WEC data property is
    // installed, meaning any accessor, read-only, non-enumerable, or
    // non-configurable one. It is never cleared, so it is conservative.
    //
    // While it is false, every own property is a default data property and
    // get_prop_flags() returns PROP_FLAGS_WEC in O(1) rather than walking the
    // shape chain. That matters for dictionary-mode objects built by loops like
    // `for (i) obj[i]=v`, whose shape chain gains a node per property: probing
    // flags would be O(depth), making bulk reads O(N^2).
    bool has_nondefault_flags : 27;
    // Module Namespace Exotic Object (ECMA-262 §10.4.6). Exports are stored as
    // live-binding accessors but must present as data descriptors
    // {writable:true, enumerable:true, configurable:false}; the builtins that
    // interpose on this flag handle that. Plain [[Get]] still runs through the
    // accessors, which throw a ReferenceError on TDZ.
    bool exotic_module_ns : 28;
    // Set when an array-index key (e.g. "2") is installed in the named
    // property table, meaning that index may no longer live only in the dense
    // part. Never cleared, like has_nondefault_flags. Array push/pop fast
    // paths use it (on the receiver and while walking its prototype chain) to
    // skip an O(prop_count) scan of named keys.
    bool has_indexed_named_prop : 29;
}

// Sets the temproot flag on this object.
fn void HObject.set_temproot(&self) @inline {
    ((types::HeapHeader*)self).set_temproot();
}

// ============================================================================
// PropFlags, the per-property attribute bits
// ============================================================================

// Property descriptor attributes: the spec's [[Writable]], [[Enumerable]], and
// [[Configurable]], plus a flag for accessors.
bitstruct PropFlags : char {
    // Property value can be changed.
    bool writable     : 0;
    // Property appears in for-in and Object.keys().
    bool enumerable   : 1;
    // Property can be deleted and its attributes changed.
    bool configurable : 2;
    // When true the property is an accessor (getter/setter pair) rather
    // than a data property.
    bool is_accessor  : 3;
}

// The flags a plain assignment creates: writable, enumerable, configurable.
const PropFlags PROP_FLAGS_WEC = {
    .writable     = true,
    .enumerable   = true,
    .configurable = true,
    .is_accessor  = false
};

// non-enumerable data property (writable, configurable).
// Used for built-in prototype methods per ES5 spec.
const PropFlags PROP_FLAGS_WC = {
    .writable     = true,
    .enumerable   = false,
    .configurable = true,
    .is_accessor  = false
};

// non-writable data property (enumerable, configurable).
// Used for `const` bindings to prevent reassignment.
const PropFlags PROP_FLAGS_EC = {
    .writable     = false,
    .enumerable   = true,
    .configurable = true,
    .is_accessor  = false
};

// Writable, enumerable, non-configurable data property.
// Used for global `var`/FunctionDeclaration bindings (ES2015
// §8.1.1.4.15 CreateGlobalVarBinding / §8.1.1.4.17
// CreateGlobalFunctionBinding): the global object's own property for a
// script-level var/function is non-configurable so it cannot be deleted,
// but remains writable and enumerable.
const PropFlags PROP_FLAGS_WE = {
    .writable     = true,
    .enumerable   = true,
    .configurable = false,
    .is_accessor  = false
};

// non-configurable data property (writable, enumerable).
// Used for ES2015 class constructor .prototype property (ES6 §14.5.14
// step 25): writable=true, enumerable=false, configurable=false.
const PropFlags PROP_FLAGS_WENC = {
    .writable     = true,
    .enumerable   = false,
    .configurable = false,
    .is_accessor  = false
};

// accessor property (enumerable, configurable).
// Used for getter/setter properties in object literals.
const PropFlags PROP_FLAGS_ACCESSOR = {
    .writable     = false,
    .enumerable   = true,
    .configurable = true,
    .is_accessor  = true
};

// Class accessor property: non-enumerable, configurable.
// Per ES2015 §14.5.14 step 9, class accessor descriptors are
// {enumerable:false, configurable:true}.
const PropFlags PROP_FLAGS_CLASS_ACCESSOR = {
    .writable     = false,
    .enumerable   = false,
    .configurable = true,
    .is_accessor  = true
};

// Class method property: writable, non-enumerable, configurable.
// Per ES2015 §14.5.14 step 9, class method descriptors are
// {writable:true, enumerable:false, configurable:true}.
const PropFlags PROP_FLAGS_CLASS_METHOD = {
    .writable     = true,
    .enumerable   = false,
    .configurable = true,
    .is_accessor  = false
};

// Private accessor property. ES2022 §7.3.28 PrivateMethodOrAccessorAdd, via
// PrivateElement, makes these non-configurable, where the public class
// accessors of PROP_FLAGS_CLASS_ACCESSOR stay configurable.
const PropFlags PROP_FLAGS_PRIVATE_ACCESSOR = {
    .writable     = false,
    .enumerable   = false,
    .configurable = false,
    .is_accessor  = true
};

// non-writable, non-enumerable, configurable.
// Used for .name and .length properties of built-in functions.
const PropFlags PROP_FLAGS_NWC = {
    .writable     = false,
    .enumerable   = false,
    .configurable = true,
    .is_accessor  = false
};

// The String exotic .length property (ES5 §15.5.5.1).
const PropFlags PROP_FLAGS_NNC = {
    .writable     = false,
    .enumerable   = false,
    .configurable = false,
    .is_accessor  = false
};

// String exotic indexed properties (ES5 §15.5.5.1).
const PropFlags PROP_FLAGS_NEC = {
    .writable     = true,
    .enumerable   = true,
    .configurable = false,
    .is_accessor  = false
};

// Result of searching for an accessor property on the prototype chain.
struct AccessorResult {
    // The getter or setter TVal (function), or undefined if not found.
    TVal accessor_fn;
    // The object that owns the accessor (needed for `this` binding).
    HObject* this_obj;
    // Whether an accessor was actually found.
    bool found;
}

// ============================================================================
// PropValue, the per-object property value storage
// ============================================================================

// One TVal per property slot, 8 bytes when NaN-boxed. A data property holds its
// value directly; an accessor property holds a pointer to a GETTER_SETTER
// object. Shape.PropFlags.is_accessor says which a reader is looking at.
alias PropValue = TVal;

// ---------------------------------------------------------------------------
// Boxed accessor pair helpers
// ---------------------------------------------------------------------------

// Allocate a GETTER_SETTER cell and return it as an object TVal.
fn TVal hobject_create_accessors(heap::Heap* h, TVal getter, TVal setter) {
    HObject*? gs_obj = h.alloc_object(ObjClass.GETTER_SETTER);
    if (try gs = gs_obj) {
        (*gs.extra_ptr()).gs.getter = getter;
        (*gs.extra_ptr()).gs.setter = setter;
        // The cell now holds references to both.
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

// Extract the getter from a boxed accessor slot.
fn TVal hobject_access_getter(TVal slot) {
    HObject* gs = (HObject*)slot.get_heapptr();
    return (*gs.extra_ptr()).gs.getter;
}

// Extract the setter from a boxed accessor slot.
fn TVal hobject_access_setter(TVal slot) {
    HObject* gs = (HObject*)slot.get_heapptr();
    return (*gs.extra_ptr()).gs.setter;
}

// Update the getter inside an existing GetterSetter cell (refcounted).
fn void hobject_set_access_getter(TVal slot, TVal new_getter, heap::Heap* h) {
    HObject* gs = (HObject*)slot.get_heapptr();
    h.decref_tval(&(*gs.extra_ptr()).gs.getter);
    (*gs.extra_ptr()).gs.getter = new_getter;
    if (new_getter.is_heap_allocated() && new_getter.get_heapptr() != null) {
        ((types::HeapHeader*)new_getter.get_heapptr()).incref();
    }
}

// Update the setter inside an existing GetterSetter cell (refcounted).
fn void hobject_set_access_setter(TVal slot, TVal new_setter, heap::Heap* h) {
    HObject* gs = (HObject*)slot.get_heapptr();
    h.decref_tval(&(*gs.extra_ptr()).gs.setter);
    (*gs.extra_ptr()).gs.setter = new_setter;
    if (new_setter.is_heap_allocated() && new_setter.get_heapptr() != null) {
        ((types::HeapHeader*)new_setter.get_heapptr()).incref();
    }
}

// ============================================================================
// ShapeProperty, a property descriptor inside a Shape
// ============================================================================

// One entry in a Shape's property array: the key and its flags. Values are
// per-object and live in the object's own slots.
struct ShapeProperty {
    // Interned property key (HString*), compared by pointer.
    void*     key;
    // Property attribute flags.
    PropFlags flags;
}

// ============================================================================
// HObject: the subtype structs of the HObjectExtra union
// ============================================================================

// Compiled function / native builtin extra fields.
struct HObjectFunction {
    CompiledFunction* comp_func;
    EnvRecord*        var_env;
    EnvRecord*        lex_env;
    int               builtin_fn_index;
    // Arrow functions only ([[ThisMode]] lexical, ES2015 §9.2.1): the
    // enclosing activation's `this` from closure creation, reused however the
    // arrow is later invoked. Unused on non-arrows. It sits after
    // builtin_fn_index so HObjectProxy, which overlays this struct, keeps that
    // field at the same offset.
    TVal              captured_this;
    // Arrow functions only: the enclosing function's new.target from
    // closure-creation time, which outlives the enclosing frame. Null on
    // non-arrows and when the enclosing invocation had no new.target.
    HObject*          captured_new_target;
    // Bound function internals: [[BoundTargetFunction]], [[BoundThis]], and
    // [[BoundArguments]] (ES2015+ §10.4.1). Live only when flags.is_bound.
    //
    // Plain fields rather than a union variant because bound functions are
    // ObjClass.FUNCTION and generic dispatch reads builtin_fn_index through
    // this struct without checking is_bound first; not property-table entries
    // because getOwnPropertyNames and Reflect.ownKeys would expose them.
    // bound_target is a full TVal because the target can be a lightfunc;
    // bound_args is null when nothing beyond `this` was bound, otherwise a
    // real JS Array so spreading and .length work unchanged.
    TVal              bound_target;
    TVal              bound_this;
    HObject*          bound_args;
}

// Primitive wrapper (Boolean, Number, String objects).
struct HObjectPrimitive {
    TVal              primitive_value;
}

// Error object ([[ErrorData]], ObjClass.ERROR), holding the stack string
// captured at construction. Exposed only through the accessor pair on
// Error.prototype, never as an own property, so it stays out of the property
// table where getOwnPropertyNames and for-in cannot see it.
struct HObjectError {
    TVal              captured_stack;
}

// RegExp object: pattern + compiled bytecode.
struct HObjectRegExp {
    TVal              pattern_str;
    // Compiled bytecode, refcounted by libregexp. Every RegExp object holds one
    // reference, either re_compile's initial one or a fresh re_ref when the
    // bytecode is shared with a NEWREGEXP literal cache, and drops it through
    // re_free on finalize. Shared and exclusive bytecode are released the same
    // way, since re_free only frees at refcount zero.
    void*             regexp_data;
    int               flags;       // JS flag bits: 1=g, 2=i, 4=m
}

// Generator: suspended execution state + captured env.
struct HObjectGenerator {
    void*             generator_data;
    CompiledFunction* comp_func;
    EnvRecord*        var_env;
    EnvRecord*        lex_env;
}

// [[PromiseState]] values, held in HObjectPromise.state. They live here rather
// than in builtins because heap.c3 reads the field too, when deciding whether
// a tracked rejection is still a rejection at the end of the microtask drain,
// and heap.c3 sits below builtins in the import order.
const uint PROMISE_PENDING   = 0;
const uint PROMISE_FULFILLED = 1;
const uint PROMISE_REJECTED  = 2;

// Promise state, result, and pending reaction list. The reactions are linked
// HObjects allocated as ObjClass.OBJECT, and all promise state lives in this
// union slot rather than the property table, where user code could reach it.
struct HObjectPromise {
    uint      state;             // one of PROMISE_PENDING/FULFILLED/REJECTED
    TVal      result;            // resolved value or rejection reason
    HObject*  reactions_head;    // linked list of reaction records
    HObject*  reactions_tail;    // tail pointer (O(1) append)
    // [[PromiseIsHandled]] (ES2015+ §27.2.6). Set the moment any reaction is
    // attached, including the handler-less pass-through ones that `await` and
    // promise adoption install, and never cleared: once something is watching
    // a promise, its rejection is somebody's to report.
    //
    // A rejection with this still false at the end of the microtask drain is
    // an unhandled rejection; see Heap.track_rejection.
    bool      is_handled;
    // True while this promise sits in Heap.unhandled_rejections, so a promise
    // rejected, un-tracked, and rejected again cannot be listed twice.
    bool      in_reject_list;
}

// Array/Map/Set iterator state.
// Active when flags.obj_class is ARRAY_ITERATOR, MAP_ITERATOR, or SET_ITERATOR.
//
// STRING_ITERATOR shares this union slot: it keeps the iterated string in
// extra.prim.primitive_value at bytes 0 to 7 for GC tracing, and its position
// in extra.iter.index at bytes 8 to 11. Those byte ranges do not overlap.
struct HObjectIterator {
    HObject*          target;   /// The iterated object (array, Map, or Set).
    uint              index;    /// Current iteration position.
    uint              kind;     /// 0=values, 1=keys, 2=entries.
}

// RegExpStringIterator: lazy iteration over regexp matches.
// Active when flags.obj_class is REGEXP_STRING_ITERATOR.
// Stores the iterated string (for GC tracing) and the regexp.
struct HObjectRegExpStringIterator {
    TVal     string_val;   /// The string being iterated (for GC tracing).
    HObject* regexp;       /// The RegExp object.
    uint     flags;        /// Bit 0: global flag; bit 1: done flag.
}

// %WrapForValidIteratorPrototype% instance: adapts a plain object exposing
// `next`/`return` to the Iterator protocol. Active when obj_class is
// WRAP_FOR_VALID_ITERATOR. Mirrors the spec's Iterator Record: [[Iterator]]
// and [[NextMethod]] (cached once, per GetIteratorDirect semantics).
struct HObjectWrapForValidIterator {
    HObject* iterated;      /// [[Iterated]].[[Iterator]], the wrapped object.
    TVal     next_method;   /// [[Iterated]].[[NextMethod]], the cached `next`.
}

// Iterator Helper (ES2025 §27.1.2), shared by the map, filter, take, drop, and
// flatMap results. Active when obj_class is ITERATOR_HELPER.
//
// The spec models these as generators, but here `next()` and `return()` are a
// state machine driven straight off the underlying iterator's `next()`. Every
// kind but flatMap needs no state beyond the fields below, and flatMap threads
// its inner iterator through `inner_iter` and `inner_next`.
struct HObjectIteratorHelper {
    HObject* underlying;     /// The wrapped Iterator Record's [[Iterator]].
    TVal     next_method;    /// The wrapped Iterator Record's [[NextMethod]].
    TVal     callback;       /// mapper / predicate (unused by take/drop).
    double   remaining;      /// take/drop: remaining count (+Infinity allowed).
    double   counter;        /// map/filter/flatMap: 0-based step counter.
    uint     kind;            /// IterHelperKind ordinal.
    uint     state;           /// IterHelperState ordinal.
    // flatMap only: the current inner iterator (Iterator Record), or null
    // when not currently flattening one.
    HObject* inner_iter;
    TVal     inner_next;
}

// Proxy exotic object holding [[ProxyTarget]] and [[ProxyHandler]], both null
// once revoked. Active when obj_class is PROXY.
//
// builtin_fn_index overlays HObjectFunction.builtin_fn_index, so a callable
// proxy dispatches through the ordinary BUILTIN_FN path. A callable target sets
// it to the proxy call and construct builtin at creation.
struct HObjectProxy {
    HObject* target;
    HObject* handler;
    void*    _reserved;          // keeps builtin_fn_index at the same offset as HObjectFunction
    int      builtin_fn_index;
}

// A getter and setter pair, boxed in a GETTER_SETTER object. A prop_values[]
// slot points here when PropFlags.is_accessor is set.
struct HObjectGetterSetter {
    TVal getter;
    TVal setter;
}

// ArrayBuffer backing store, active when obj_class is ARRAYBUFFER.
//
// A byte_length of 0xFFFFFFFF marks a detached buffer, which is distinct from a
// live zero-length one, where data is null and byte_length is 0.
//
// A resizable buffer (ES2024) sets `resizable` and caps growth at
// `max_byte_length`. Fixed buffers leave both unset, so the fixed-buffer fast
// path never reads the cap.
struct HObjectArrayBuffer {
    char*    data;          // heap.alloc_func'd, zeroed; null when detached or zero-length
    uint     byte_length;   // byte length; set to 0xFFFFFFFF on detach
    HObject* views_head;    // intrusive list of views (via HObjectBufferView.next_view)
    uint     max_byte_length; // cap for resizable buffers; unused (0) when !resizable
    bool     resizable;     // true iff constructed with {maxByteLength}
    bool     is_shared;     // true iff this is a SharedArrayBuffer (never detachable)
}

// TypedArray or DataView, active for INT8ARRAY through FLOAT64ARRAY and DATAVIEW.
//
// `length_tracking` (ES2024) is set when the view was created over a resizable
// buffer with no explicit length. Such a view follows the buffer, recomputing
// its effective byte_length on every access, so the stored `byte_length` no
// longer speaks for it. See view_effective_byte_length and
// view_is_out_of_bounds in typedarray.c3.
struct HObjectBufferView {
    HObject* buffer;        // backing ARRAYBUFFER object (GC-traced)
    HObject* next_view;     // intrusive list link (buffer.extra.ab.views_head chain)
    uint     byte_offset;
    uint     byte_length;   // in BYTES (authoritative only when !length_tracking)
    bool     length_tracking; // auto-track backing resizable buffer length
}

// The subtype fields, discriminated by flags.obj_class in the common header.
union HObjectExtra {
    HObjectFunction              func;
    HObjectPrimitive             prim;
    HObjectError                 err;
    HObjectRegExp                regexp;
    HObjectGenerator             gen;
    HObjectPromise               promise;
    HObjectIterator              iter;
    HObjectRegExpStringIterator  regexp_iter;
    HObjectWrapForValidIterator  wrap_iter;
    HObjectIteratorHelper        iter_helper;
    HObjectGetterSetter          gs;
    HObjectProxy                 proxy;
    HObjectArrayBuffer           ab;
    HObjectBufferView            view;
    HObjectTemporal              temporal;
    uint                         array_length;  // For ARRAY objects: dense-element count.
}

// Temporal objects (Temporal.PlainDate, .PlainTime, .Instant, etc.). One
// shared variant for every Temporal class; `obj_class` discriminates which
// fields are live.
//
// Layout uses plain ints (no packing): PlainTime has six fields, each fits
// an int trivially, and ns is 0..999. Year is stored as int, which covers
// ±2 M years without overflow — well past the spec's range. Duration is the
// widest user: ten integer fields (years..nanoseconds), each int32.
//
// big_ns is null for non-Instant types; calendar/timezone are null when
// not in use for the given obj_class. PlainTime, PlainDate, PlainDateTime,
// PlainYearMonth, PlainMonthDay, Duration, Instant, ZonedDateTime, Calendar,
// and TimeZone all share this variant.
//
// HObjectExtra is sized by its largest member and alloc_size_for_class
// charges that to every FUNCTION/REGEXP/PROMISE/DATE object. This variant
// must never become the max, or every such object grows engine-wide.
//
// Baseline (nanbox, default build, macOS arm64, 2026-08-24):
//   HObjectFunction::size         = 72  (current max)
//   HObjectIteratorHelper::size   = 64
//   HObjectPromise::size          = 40
//   HObjectBufferView::size       = 32
//   HObjectTemporal::size         = 64  (8 B under the max, costs zero
//                                        engine-wide when added)
//   INLINE_EXTRA                  = 32
//   OBJ_SIZE_FUNC                 = 184
struct HObjectTemporal {
    HBigInt*        big_ns;
    int             int_a;
    int             int_b;
    int             int_c;
    int             int_d;
    int             int_e;
    int             int_f;
    int             int_g;
    int             int_h;
    int             int_i;
    int             int_j;
    HObject*        calendar;
    HObject*        timezone;
}

$assert HObjectTemporal::size <= HObjectFunction::size;

// The prefix every HObject variant starts with, which lets the GC walk the
// heap lists and reach shapes and properties at fixed offsets. Its first
// fields are binary-compatible with HeapHeader, so a raw cast at offset 0
// works.
//
// Metadata for an object's per-object property hash table, allocated once
// prop_count reaches HASH_MIN_PROPS for an object whose shape chain has no
// second user. HObject holds only a pointer to it, so an object that never
// builds a table costs 8 bytes rather than the whole struct.
struct PropHashInfo {
    void* table;    /// HashEntry[] buffer
    uint  mask;     /// one less than the slot count
    uint  count;    /// prop_count as of the last rebuild
}

// Map/Set lookup index over array_part, so lookups need not scan it.
//
// Map, Set, WeakMap and WeakSet keep their entries in array_part -- keys and
// values interleaved for the Maps, values alone for the Sets -- so scanning it
// per operation is quadratic over a large collection. This index answers each
// lookup with one probe.
//
// `slots` holds 1-based array_part indices, 0 empty, DELETED_SLOT a tombstone
// probing must step over. Storing indices keeps array_part the single source
// of truth for iteration order, tombstone semantics and GC tracing, and costs
// one uint per slot rather than a second copy of every key.
//
// Built lazily once a collection exceeds COLL_HASH_MIN_ENTRIES.
struct CollHashInfo {
    uint* slots;   /// 1-based indices into array_part; 0 = empty
    uint  mask;    /// one less than the slot count, which is a power of two
    uint  used;    /// occupied slots, tombstones included, for the load factor
    uint  built;   /// array_used as of the last rebuild
}

// HObject flattens these fields into its own layout with
// `inline HObjectBase base`. Classes that need subtype fields add an
// HObjectExtra after this prefix; see alloc_size_for_class.
struct HObjectBase {
    ObjFlags      flags;
    uint          refcount;
    HeapHeader*   next;
    HeapHeader*   prev;
    HObject*      prototype;
    uint          shape_id;
    uint          prop_capacity;
    uint          prop_count;
    uint          array_size;
    uint          array_used;
    void*         prop_alloc;
    PropHashInfo* prop_hash;
    // Lookup index for MAP/SET/WEAKMAP/WEAKSET, null until the collection is
    // large enough to want one. Never used by other classes -- prop_hash is
    // the index over named properties, and a Map can have both.
    CollHashInfo* coll_hash;
}

// The core ECMAScript object representation.
//
// C3's `inline` keyword flattens HObjectBase's fields into HObject, so
// `self.flags` and `self.prop_count` need no qualification while
// HObjectBase::size stays correct for locating the trailing data.
//
// Subtype fields live in the HObjectExtra union, discriminated by
// flags.obj_class.
struct HObject {
    inline HObjectBase base;
    HObjectExtra      extra;       // at HObjectBase::size; holds array_length for ARRAY
}

// ============================================================================
// HObject: per-class allocation sizes and trailing-data accessors
// ============================================================================

// Pool size classes, derived from the struct sizes plus the inline prop space.
const usz INLINE_EXTRA = INLINE_PROPS * PropValue::size;
const usz OBJ_SIZE_PLAIN = HObjectBase::size + INLINE_EXTRA;                            // OBJECT, ERROR, ARGUMENTS
const usz OBJ_SIZE_ARRAY = HObjectBase::size + HObjectExtra::size + INLINE_EXTRA;       // ARRAY, whose array_length is in the union
const usz OBJ_SIZE_FUNC  = HObjectBase::size + HObjectExtra::size + INLINE_EXTRA;       // FUNCTION, REGEXP, etc.
const usz OBJ_SIZE_GS    = HObjectBase::size + HObjectGetterSetter::size;               // GETTER_SETTER, which has no inline props

// Allocation size for an object class. Every class but GETTER_SETTER carries
// INLINE_PROPS slots at the tail, so an object with few named properties needs
// no separate prop_alloc.
fn usz alloc_size_for_class(ObjClass cls) @inline {
    switch (cls) {
        case ObjClass.OBJECT:
        case ObjClass.ARGUMENTS:
            return OBJ_SIZE_PLAIN;
        // ERROR keeps captured_stack in the union, so it needs the trailing
        // extra-data space that plain OBJECT and ARGUMENTS do not.
        case ObjClass.ERROR:
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

// The HObjectExtra union, which sits at HObjectBase::size from the object.
// Only classes allocated with extra-data space have one; see
// alloc_size_for_class.
fn HObjectExtra* HObject.extra_ptr(&self) @inline {
    return (HObjectExtra*)((char*)self + HObjectBase::size);
}

// extra.array_length, the first 4 bytes of the union. ARRAY objects only,
// meaning those with flags.exotic_array.
fn uint* HObject.array_len_ptr(&self) @inline {
    return &self.extra.array_length;
}

// ============================================================================
// Pool allocation helpers
// ============================================================================

// The pool an object class allocates from.
fn void* pool_for_class(void* heap_ptr, ObjClass cls) @inline {
    heap::Heap* h = (heap::Heap*)heap_ptr;
    switch (cls) {
        case ObjClass.OBJECT:
        case ObjClass.ARGUMENTS:
            return &h.obj_pool_plain;
        case ObjClass.ARRAY:
            return &h.obj_pool_array;
        case ObjClass.ERROR:
        case ObjClass.GETTER_SETTER:
            return &h.obj_pool_func;
        default:
            return &h.obj_pool_func;
    }
}

// ============================================================================
// HObject: property allocation helpers
// ============================================================================

// Total size of the property allocation block. Inline storage, used when
// prop_alloc is null, has no array part.
fn usz HObject.prop_alloc_size(&self) {
    if (self.prop_alloc == null) {
        return (usz)self.prop_capacity * PropValue::size;
    }
    usz size = (usz)self.prop_capacity * PropValue::size;
    size += (usz)self.array_size * TVal::size;
    return size;
}

// The inline prop storage at the end of the object allocation, valid only
// while prop_alloc is null.
fn PropValue* HObject.inline_props_ptr(&self) @inline {
    usz base_size = alloc_size_for_class(self.flags.obj_class) - INLINE_PROPS * PropValue::size;
    return (PropValue*)((char*)self + base_size);
}

// The property values array: inline storage while prop_alloc is null, and the
// heap-allocated block once it is not.
fn PropValue* HObject.prop_values(&self) @inline {
    if (self.prop_alloc != null) return (PropValue*)self.prop_alloc;
    return self.inline_props_ptr();
}

// The dense array part, which follows the property values inside prop_alloc.
// Null when there is none, meaning prop_alloc is null or array_size is 0.
fn TVal* HObject.array_part(&self) @inline {
    if (self.prop_alloc == null || self.array_size == 0) return null;
    return (TVal*)((char*)self.prop_alloc + (usz)self.prop_capacity * PropValue::size);
}

// ============================================================================
// HObject: HeapHeader-compatible helpers
// ============================================================================

// Returns a HeapHeader pointer to this object (binary-compatible cast).
fn HeapHeader* HObject.as_header(&self) @inline {
    return (HeapHeader*)self;
}

// ============================================================================
// HObject: shape accessors
// ============================================================================

// This object's Shape, resolved from `shape_id` through the owning heap's
// shapes array. Null when the id is out of range, which happens only for an
// object whose shape slot was released.
fn Shape* HObject.get_shape(&self, heap::Heap* h) @inline {
    if (self.shape_id >= h.shape_count) return null;
    return h.shapes[self.shape_id];
}

// ============================================================================
// HObject: flag accessors
// ============================================================================

// Returns the object's [[Class]].
fn ObjClass HObject.get_class(&self)    { return self.flags.obj_class; }

// Returns true when the object is [[Extensible]].
fn bool HObject.is_extensible(&self)    { return self.flags.extensible; }

// Returns true when the object is callable.
fn bool HObject.is_callable(&self)      @inline { return self.flags.callable; }

// Returns true when the object can be used as a constructor.
fn bool HObject.is_constructable(&self) @inline { return self.flags.constructable; }

// Returns true when the object is a bound function.
fn bool HObject.is_bound(&self)         @inline { return self.flags.is_bound; }

// Work out the callable kind from fields the object already has.
fn CallableKind HObject.callable_kind(&self) @inline {
    if (self.flags.is_bound) return CallableKind.BOUND_FN;
    if ((*self.extra_ptr()).func.builtin_fn_index >= 0) return CallableKind.BUILTIN_FN;
    if ((*self.extra_ptr()).func.comp_func != null) return CallableKind.COMPILED_FN;
    return CallableKind.OTHER;
}

// Seal the object: clear extensible and make every own property
// non-configurable.
//
// The flat array part holds TVals with no PropFlags of their own, so dense
// elements move into the named property table first and the array part is then
// abandoned with array_size set to 0.
fn void HObject.seal(&self, heap::Heap* h) {
    self.flags.extensible = false;

    // Move dense elements into the named table so each can carry its own flags.
    if (self.array_part() != null && self.array_used > 0) {
        char[12] digit_buf;
        for (uint i = 0; i < self.array_size; i++) {
            TVal v = self.array_part()[i];
            if (!v.is_undefined()) {
                int dlen = (int)(io::bprintf(&digit_buf, "%d", i) ?? digit_buf[:0]).len;
                if (dlen > 0) {
                    HString* key = h.str_intern(digit_buf[:(uint)dlen]);
                    if (key != null) {
                        // Non-configurable flags make put_prop skip its
                        // dense-write fast path, so this adds exactly one
                        // named-table reference. The dense slot's own reference
                        // is released just below.
                        self.put_prop((void*)key, v, PROP_FLAGS_NEC, h);
                        if (v.is_heap_allocated()) {
                            h.decref_tval(&self.array_part()[i]);
                        }
                    }
                }
            }
        }
    }

    // The dense part is gone, so shrink the block to fit the named table.
    // pool_free picks the class pool from the allocation-time size, so a block
    // must keep matching the size it was allocated with. If the shrink fails
    // (an oversized object at OOM), array_size stays so the block still
    // matches, and the abandoned slots read as undefined.
    if (self.prop_alloc != null) {
        usz old_size = self.prop_alloc_size();
        usz new_size = (usz)self.prop_capacity * PropValue::size;
        void* new_raw = h.pool_alloc(new_size) ?? null;
        if (new_raw != null) {
            mem::copy(new_raw, self.prop_alloc, (sz)((usz)self.prop_count * PropValue::size));
            h.pool_free(self.prop_alloc, old_size);
            self.prop_alloc = new_raw;
            self.array_size = 0;
        }
    } else {
        self.array_size = 0;
    }
    self.array_used = 0;

    self.make_shape_private(h);
    for (uint i = 0; i < self.prop_count; i++) {
        PropFlags f = self.get_prop_flags(i, h);
        f.configurable = false;
        self.set_prop_flags(i, f, h);
    }
}

// Freeze the object: seal it, then make every data property non-writable.
fn void HObject.freeze(&self, heap::Heap* h) {
    self.seal(h);
    for (uint i = 0; i < self.prop_count; i++) {
        PropFlags f = self.get_prop_flags(i, h);
        if (!f.is_accessor) {
            f.writable = false;
            self.set_prop_flags(i, f, h);
        }
    }
    // An ARRAY's "length" lives in array_len_ptr rather than the property
    // table, so the loop above misses it. ES5 §15.4.5.1 and §10.4.2.1 require it
    // to become non-writable here, so that Set(O, "length", _, true) throws.
    if (self.flags.exotic_array) {
        self.flags.array_len_writable = false;
    }
}

// ============================================================================
// Internal: pointer hashing
// ============================================================================

// Hash a key pointer into a hash-table index. Property keys are interned
// HStrings, so pointer identity is string equality and mixing the pointer bits
// is enough.
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
// HObject: property index lookup
// ============================================================================

// Each entry in a shape's hash table for fast property lookup.
struct HashEntry {
    void* key;
    uint  index;
}

// Choose a hash mask for a given property count.
fn uint prop_hash_mask_for(uint prop_count) @inline {
    uint slots = 2;
    while (prop_count * 10 > slots * 7) {
        slots *= 2;
    }
    return slots - 1;
}

// Allocate or grow the per-object hash table for property lookup, rebuilding
// from the shape chain. This is only ever called for an object whose shape
// chain has no second user; a shared shape's table already serves every
// object on it, so building one per object there would just repeat that
// table.
fn void HObject.ensure_prop_hash(&self, heap::Heap* h) {
    if (self.prop_count < HASH_MIN_PROPS) return;
    uint new_mask = prop_hash_mask_for(self.prop_count);
    // Nothing to do when the table is current and correctly sized.
    if (self.prop_hash != null && self.prop_hash.count == self.prop_count && self.prop_hash.mask == new_mask) return;

    usz new_bytes = (usz)(new_mask + 1) * HashEntry::size;
    void* new_table = h.alloc_func(h.heap_udata, new_bytes);
    if (new_table == null) return;
    mem::clear(new_table, (sz)(new_bytes));

    HashEntry* entries = (HashEntry*)new_table;
    uint mask = new_mask;

    // The shape chain is the authoritative key list. During put_prop growth the
    // new key is already in the shape but not yet in the old table, so rebuild
    // from the shape rather than from the table.
    hobject::Shape* sh = self.get_shape(h);
    while (sh != null) {
        hobject::ShapeProperty* sp = sh.props();
        for (uint j = 0; j < sh.own_count; j++) {
            void* k = sp[j].key;
            if (k == null) continue;
            uint hv = hash_key(k);
            uint slot = hv & mask;
            while (entries[slot].key != null) slot = (slot + 1) & mask;
            entries[slot].key = k;
            entries[slot].index = sh.offset + j;
        }
        sh = sh.parent_shape;
    }

    if (self.prop_hash != null) {
        h.free_func(h.heap_udata, self.prop_hash.table);
        self.prop_hash.mask = new_mask;
        self.prop_hash.count = self.prop_count;
        self.prop_hash.table = new_table;
    } else {
        PropHashInfo* phi = (PropHashInfo*)h.alloc_func(h.heap_udata, PropHashInfo::size);
        if (phi == null) {
            h.free_func(h.heap_udata, new_table);
            return;
        }
        phi.table = new_table;
        phi.mask = new_mask;
        phi.count = self.prop_count;
        self.prop_hash = phi;
    }
}

// Free an object's per-object property hash table, used when its shape chain
// gains a second user and a shared table takes over, or during deletion when
// the surviving indices have moved.
fn void HObject.drop_prop_hash(&self, heap::Heap* h) {
    if (self.prop_hash == null) return;
    h.free_func(h.heap_udata, self.prop_hash.table);
    h.free_func(h.heap_udata, self.prop_hash);
    self.prop_hash = null;
}

// The property key at `idx`, found by walking the shape chain. Null when the
// index is out of range.
fn void* HObject.prop_key_at(&self, uint idx, heap::Heap* h) @inline {
    hobject::Shape* sh = self.get_shape(h);
    while (sh != null) {
        if (idx >= sh.offset && idx < sh.offset + sh.own_count) {
            return sh.props()[idx - sh.offset].key;
        }
        sh = sh.parent_shape;
    }
    return null;
}

// The flags recorded in the shape chain at `idx`, read without the
// has_nondefault_flags short circuit that get_prop_flags() uses. Callers
// reconstructing a shape need the stored value verbatim.
fn PropFlags HObject.prop_flags_at(&self, uint idx, heap::Heap* h) @inline {
    hobject::Shape* sh = self.get_shape(h);
    while (sh != null) {
        if (idx >= sh.offset && idx < sh.offset + sh.own_count) {
            return sh.props()[idx - sh.offset].flags;
        }
        sh = sh.parent_shape;
    }
    return PROP_FLAGS_WEC;
}

// The property flags at `idx`. The ShapeProperty holds the authoritative copy,
// which writes keep in sync.
fn PropFlags HObject.get_prop_flags(&self, uint idx, heap::Heap* h) @inline {
    // With no non-default attribute ever installed, every own property is a
    // default WEC descriptor and the answer is O(1). The walk below is O(depth),
    // which reaches O(N) on dictionary-mode objects.
    if (!self.flags.has_nondefault_flags) return PROP_FLAGS_WEC;
    hobject::Shape* sh = self.get_shape(h);
    while (sh != null) {
        if (idx >= sh.offset && idx < sh.offset + sh.own_count) {
            return sh.props()[idx - sh.offset].flags;
        }
        sh = sh.parent_shape;
    }
    return {};
}

// Flatten this object's shape chain into one standalone shape it alone uses.
// The result stays out of the transition table, so no other object can reach
// it and per-object flag edits cannot leak.
fn void HObject.make_shape_private(&self, heap::Heap* h) {
    if (self.get_shape(h) == null) return;
    hobject::Shape* ns = shape_create(self.prop_count, 0, PRIVATE_SHAPE_PARENT, null, h);
    if (ns == null) return;

    hobject::ShapeProperty* new_sp = ns.props();
    hobject::Shape* walk = self.get_shape(h);
    while (walk != null) {
        hobject::ShapeProperty* old_sp = walk.props();
        for (uint j = 0; j < walk.own_count; j++) {
            uint global_idx = walk.offset + j;
            new_sp[global_idx].key   = old_sp[j].key;
            new_sp[global_idx].flags = old_sp[j].flags;
        }
        walk = walk.parent_shape;
    }

    // The shape being replaced is dead once the swap lands. Reclaim it first so
    // a long-running privatise loop reuses one slot instead of leaking one per
    // call; free_shape_slot ignores shared transition-table shapes.
    uint old_slot = (uint)self.shape_id;
    uint slot = h.alloc_shape_slot();
    if (slot != heap::SHAPE_NONE) {
        h.store_new_shape(slot, ns);
        self.shape_id = slot;
        // The new shape borrowed the old shape's key pointers verbatim, so the
        // old slot must not decref them on the way out.
        if (old_slot != slot) h.free_shape_slot(old_slot, false);
    } else {
        // The keys were copied without an incref, so shape_free must not decref.
        shape_free(ns, h, false);
    }
}

// Set the flags of an existing property. The shape becomes private first, so
// the change cannot leak to objects sharing it. Flags that already match skip
// that work entirely.
fn void HObject.set_prop_flags(&self, uint idx, PropFlags new_flags, heap::Heap* h) {
    // Record that a non-default attribute exists here, which is what lets
    // get_prop_flags() stay O(1) while it does not.
    if (new_flags != PROP_FLAGS_WEC) self.flags.has_nondefault_flags = true;
    // Matching flags need no shape mutation.
    hobject::Shape* sh = self.get_shape(h);
    while (sh != null) {
        if (idx >= sh.offset && idx < sh.offset + sh.own_count) {
            if (sh.props()[idx - sh.offset].flags == new_flags) return;
            break;
        }
        sh = sh.parent_shape;
    }
    self.make_shape_private(h);
    sh = self.get_shape(h);
    while (sh != null) {
        if (idx >= sh.offset && idx < sh.offset + sh.own_count) {
            sh.props()[idx - sh.offset].flags = new_flags;
            return;
        }
        sh = sh.parent_shape;
    }
}

// The index of the property with this interned key, or -1. A shape shared by
// more than one object uses its own lazily built hash table; a single-user
// shape chain keeps one per-object incremental table on the object. Both are
// built once the property count reaches HASH_MIN_PROPS, and the shape chain
// is walked when neither is available.
fn int HObject.find_prop_idx(&self, void* key, heap::Heap* h) {
    if (key == null || self.prop_count == 0) return -1;

    hobject::Shape* sh = self.get_shape(h);

    if (self.prop_count >= HASH_MIN_PROPS && sh != null) {
        if (sh.shared) {
            // The shape is shared, so one table for the whole chain serves every
            // object on it. Drop any per-object table left over from a growth
            // phase that happened while this object had the chain to itself.
            if (self.prop_hash != null) self.drop_prop_hash(h);
            if (sh.hash_table == null) shape_build_hash(sh, h);
            if (sh.hash_table != null) {
                return hash_table_probe(sh.hash_table, prop_hash_mask_for(self.prop_count), key);
            }
            // The table allocation failed, so fall through to the chain walk.
        } else {
            // Only this object uses the chain, so amortize its lookups with one
            // incremental per-object table rather than a table per shape, which
            // would be quadratic in both time and memory on a deep chain.
            self.ensure_prop_hash(h);
            if (self.prop_hash != null) {
                return hash_table_probe(self.prop_hash.table, self.prop_hash.mask, key);
            }
        }
    }

    // No hash table, so walk the shape chain.
    while (sh != null) {
        hobject::ShapeProperty* sp = sh.props();
        for (uint i = 0; i < sh.own_count; i++) {
            if (sp[i].key == key) return (int)(sh.offset + i);
        }
        sh = sh.parent_shape;
    }
    return -1;
}

// Order-preserving lookup of `key` in a hash table, returning the stored
// index or -1. Open addressing with linear probing.
fn int hash_table_probe(HashEntry* entries, uint mask, void* key) @inline {
    uint slot = hash_key(key) & mask;
    for (uint probes = 0; probes <= mask; probes++) {
        HashEntry* e = &entries[slot];
        if (e.key == null) return -1;
        if (e.key == key) return (int)e.index;
        slot = (slot + 1) & mask;
    }
    return -1;
}

// The value slot for this interned key, or PROP_NOT_FOUND.
fn PropValue*? HObject.find_prop(&self, void* key, heap::Heap* h) {
    int idx = self.find_prop_idx(key, h);
    if (idx < 0) {
        return PROP_NOT_FOUND~;
    }
    return &self.prop_values()[idx];
}

// ============================================================================
// HObject: property get, has, put, and delete
// ============================================================================

// Look up a named property by its interned string key.
fn TVal? HObject.get_prop(&self, void* key, heap::Heap* h) {
    int idx = self.find_prop_idx(key, h);
    if (idx < 0) {
        // On ARRAY and ARGUMENTS exotics, numeric-string keys are own properties
        // held in the dense array part. Builtins such as push() write through
        // set_array_idx alone, so the property table cannot answer these.
        TVal dense;
        if (self.dense_arridx_lookup(key, &dense)) {
            return dense;
        }
        return PROP_NOT_FOUND~;
    }
    return self.prop_values()[idx];
}

// Look up an own property, distinguishing data properties from accessors.
// This stops at the object itself, consulting neither the prototype chain nor
// proxy traps, which is what PrivateFieldGet needs to bypass proxy [[Get]].
// get_prop_or_accessor_proto does the full walk.
fn PropLookupResult HObject.get_prop_or_accessor_own(&self, void* key, bool want_getter, heap::Heap* h) {
    int idx = self.find_prop_idx(key, h);
    if (idx >= 0) {
        if (self.get_prop_flags((uint)idx, h).is_accessor) {
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
    // ARRAY and ARGUMENTS exotics keep numeric keys in the dense part.
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

// Look up an array-index string key ("0", "1", ...) in the dense array part
// of an ARRAY / ARGUMENTS exotic object. Returns true and stores the value in
// `out` when the slot exists and is not a hole (undefined = hole sentinel).
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

// Check whether the object has an own property with the given key.
fn bool HObject.has_prop(&self, void* key, heap::Heap* h) {
    if (self.find_prop_idx(key, h) >= 0) return true;
    TVal dense;
    return self.dense_arridx_lookup(key, &dense);
}

// Check whether a property is writable.
fn bool HObject.is_prop_writable(&self, void* key, heap::Heap* h) {
    int idx = self.find_prop_idx(key, h);
    if (idx < 0) return true;
    return self.get_prop_flags((uint)idx, h).writable;
}

// Whether an array-index write should grow the dense array part.
//
// The dense part is one contiguous TVal block, so growing it to reach a sparse
// index like `a[2**31] = x` would allocate billions of empty slots. An index
// stays dense while it is below a small floor, which keeps fresh arrays
// growing densely, or within a slack window past the current size. Anything
// further away is treated as sparse and goes to the named-property table.
const uint DENSE_GROW_FLOOR = 1024;        // below this index, always dense
const uint DENSE_GROW_SLACK = 1u << 16;    // how far past array_size an index may jump
fn bool dense_index_ok(uint cur_size, uint idx) {
    if (idx < DENSE_GROW_FLOOR) return true;
    return idx <= cur_size + DENSE_GROW_SLACK;
}

// Create or update a named property, returning false only on allocation
// failure. An existing property has its value and flags updated; a new one is
// appended, growing the table if needed. Adding a property leaves the shape
// transition to the caller, through Heap.transition_shape.
fn bool HObject.put_prop(&self, void* key, TVal val, PropFlags pflags, heap::Heap* h) {
    // Property lookup compares keys by pointer, so a stored key must be the
    // canonical interned string; callers hand in un-interned concatenation
    // results. Symbols pass through: their unique counter hash keeps them
    // distinct in the table.
    if (key != null && !((hstring::HString*)key).flags.is_interned) {
        key = (void*)h.ensure_interned((hstring::HString*)key);
    }
    // The interned "length" key. Null only before the builtin strings are
    // interned, during heap setup, when no exotic array exists yet for the
    // comparisons to match.
    void* length_key = (void*)h.strs[heap::BuiltinStr.LENGTH];
    if (pflags != PROP_FLAGS_WEC) self.flags.has_nondefault_flags = true;

    // Existing property: update in place.
    int idx = self.find_prop_idx(key, h);
    if (idx >= 0) {
        PropValue* pv = &self.prop_values()[idx];
        // The incoming value increfs before the old one decrefs, so a
        // self-assignment where val aliases *pv cannot free it early. This
        // mirrors Heap.tval_copy_ref. One combined test skips both sides for a
        // numeric or boolean overwrite, where neither value is heap-allocated.
        if (types::either_heap_allocated(&val, pv)) {
            if (val.is_heap_allocated()) {
                void* ptr = val.get_heapptr();
                if (ptr != null) {
                    ((types::HeapHeader*)ptr).incref();
                }
            }
            if (pv.is_heap_allocated()) {
                h.decref_tval(pv);
            }
        }
        *pv = val;
        self.set_prop_flags((uint)idx, pflags, h);
        // A length write on an ARRAY exotic updates the shadow copy.
        if (self.flags.exotic_array && key == length_key) {
            if (val.is_fastint()) {
                *self.array_len_ptr() = (uint)val.get_fastint();
            } else if (val.is_number()) {
                *self.array_len_ptr() = (uint)val.get_number();
            }
        }
        // Numeric-string keys also write through to the dense part, keeping the
        // two stores consistent. Builtins such as push() go through
        // set_array_idx and touch only the dense part, while PUTPROP writes the
        // property table, and a read through either path must see both.
        if (self.flags.exotic_array) {
            HString* ks = (HString*)key;
            if (ks.is_arridx()) {
                uint ks_idx = ks.array_index();
                if (ks_idx < self.array_size) {
                    self.set_array_idx(ks_idx, val, h);
                }
                if (ks_idx >= *self.array_len_ptr()) {
                    *self.array_len_ptr() = ks_idx + 1;
                    self.sync_named_length(h);
                }
            }
        }
        return true;
    }

    // A new integer-indexed element on an exotic array grows the dense part
    // rather than the named table. That table counts entries in a ushort, so
    // large indexed writes would silently truncate a long array past 2^16.
    // set_array_idx grows a uint-sized dense backing instead.
    if (self.flags.exotic_array && key != length_key) {
        HString* ks = (HString*)key;
        // The dense part marks holes with `undefined`, so it cannot tell a
        // stored `undefined` from an absent index. Those writes fall through to
        // the named table, which records presence properly.
        if (ks.is_arridx() && !val.is_undefined()
            && pflags.writable && pflags.enumerable && pflags.configurable
            && !pflags.is_accessor
            && dense_index_ok(self.array_size, ks.array_index())) {
            uint ks_idx = ks.array_index();
            if (self.set_array_idx(ks_idx, val, h)) {
                if (ks_idx >= *self.array_len_ptr()) {
                    *self.array_len_ptr() = ks_idx + 1;
                    self.sync_named_length(h);
                }
                return true;
            }
            // Dense growth failed, so fall through to the named-property path.
        }
    }

    if (self.prop_count >= self.prop_capacity) {
        self.grow_props(h);
        if (self.prop_count >= self.prop_capacity) {
            return false;
        }
    }

    // Append at the next slot.
    uint new_idx = self.prop_count;
    mem::clear(&self.prop_values()[new_idx], (sz)(PropValue::size));
    self.prop_values()[new_idx] = val;
    // Strings, objects, buffers, and BigInts are reference-counted heap
    // values held by properties, so the new value needs its own reference.
    if (val.is_heap_allocated()) {
        void* ptr = val.get_heapptr();
        if (ptr != null) {
            ((types::HeapHeader*)ptr).incref();
        }
    }
    self.prop_count++;

    // This is the only place a named-table slot is created, so it is the choke
    // point for detecting an array-index key entering the named table: dense
    // fast paths that trust array_part() need to know an index may no longer
    // live only there. Tracked for every class, not just exotic arrays: a
    // plain object can sit on an array's prototype chain, where an indexed
    // property must still take priority over CreateDataProperty on a receiver
    // appending past its own length. The dense-index case above returns early,
    // so this fires only for indices dense_index_ok rejected or an explicit
    // named-table promotion.
    HString* new_key_hs = (HString*)key;
    if (new_key_hs.is_arridx()) {
        self.flags.has_indexed_named_prop = true;
    }

    // Same length and dense-part syncing as the update path above.
    if (self.flags.exotic_array && key == length_key) {
        if (val.is_fastint()) {
            *self.array_len_ptr() = (uint)val.get_fastint();
        } else if (val.is_number()) {
            *self.array_len_ptr() = (uint)val.get_number();
        }
    }

    if (self.flags.exotic_array) {
        HString* ks = (HString*)key;
        if (ks.is_arridx()) {
            uint ks_idx = ks.array_index();
            if (ks_idx < self.array_size) {
                self.set_array_idx(ks_idx, val, h);
            }
            if (ks_idx >= *self.array_len_ptr()) {
                *self.array_len_ptr() = ks_idx + 1;
                self.sync_named_length(h);
            }
        }
    }

    // Move to a shape that includes the new property. find_prop_idx() above
    // already established the key is new, so transition_shape_new_flags() can
    // skip its chain walk. Keying the transition on (parent, key, flags) lets
    // every instance of a class installing the same private field share one
    // shape, where set_prop_flags() would give each a private, uncacheable one.
    //
    // The shape chain is the authoritative key list, so an object whose shape
    // does not name this key has not really stored it.
    // transition_shape_new_flags() returns the current ID unchanged when it
    // cannot allocate, so that case unwinds the append and reports failure
    // rather than claiming a write that later reads cannot see. The new
    // shape's hash table stays unbuilt until the first lookup needs it.
    uint new_shape_id = h.transition_shape_new_flags(self.shape_id, key, pflags);
    if (new_shape_id == heap::SHAPE_NONE) {
        // The shape pool is exhausted. Storing the value anyway would leave
        // a property the shape never records, so it would read back as
        // missing -- a silent wrong answer. Undo the append and report the
        // failure so the caller can raise instead.
        self.prop_count--;
        if (val.is_heap_allocated()) {
            h.decref_tval(&self.prop_values()[new_idx]);
        }
        mem::clear(&self.prop_values()[new_idx], (sz)(PropValue::size));
        return false;
    }
    self.shape_id = new_shape_id;

    // Keep the per-object hash table in step with this growth, but only for a
    // single-user shape chain. A shared shape's one table already names this
    // key and serves every object on it, so a per-object table there would
    // only waste memory. When the chain just turned shared, drop the table we
    // spent the unshared phase maintaining.
    hobject::Shape* new_leaf = h.get_shape(new_shape_id);
    if (self.prop_count >= HASH_MIN_PROPS) {
        if (new_leaf != null && !new_leaf.shared) {
            uint needed_mask = prop_hash_mask_for(self.prop_count);
            if (self.prop_hash == null) {
                self.ensure_prop_hash(h);
            } else if (self.prop_hash.mask != needed_mask) {
                self.ensure_prop_hash(h);
            } else {
                // Right size, so insert the new key in place instead of paying
                // for a full rebuild on every put_prop.
                HashEntry* entries = (HashEntry*)self.prop_hash.table;
                uint mask = self.prop_hash.mask;
                uint slot = hash_key(key) & mask;
                uint probes = 0;
                while (entries[slot].key != null && probes <= mask) {
                    if (entries[slot].key == key) {
                        // A new key should not already be present; repoint it.
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
                // A full table cannot happen at the 70% load factor.
            }
        } else if (self.prop_hash != null) {
            self.drop_prop_hash(h);
        }
    }

    return true;
}

// Delete an own property by interned key. The surviving values shift down to
// close the gap, and the object gets a fresh private shape that names the
// surviving keys at their new indexes.
fn bool HObject.delete_prop(&self, void* key, heap::Heap* h) {
    // On ARRAY and ARGUMENTS exotics a numeric-string key may also sit in the
    // dense part, so clear that slot to `undefined`, the hole sentinel, or a
    // later numeric-index read would return the stale value.
    if (key != null && (self.get_class() == hobject::ObjClass.ARRAY || self.get_class() == hobject::ObjClass.ARGUMENTS)) {
        HString* hkey = (HString*)key;
        if (hkey.is_arridx()) {
            uint ai = (uint)hkey.array_index();
            if (ai < self.array_size) {
                TVal undef; undef.set_undefined();
                self.set_array_idx(ai, undef, h);
            }
        }
    }

    int idx = self.find_prop_idx(key, h);
    if (idx < 0) {
        return false;
    }

    uint ui = (uint)idx;
    uint new_count = self.prop_count - 1;

    // An emptied object returns to the root shape in slot 0, which describes it
    // exactly. Allocating a fresh private shape on every delete would grow the
    // shapes array without bound for no benefit. Nothing on this path can fail,
    // so the compaction may start right away.
    if (new_count == 0) {
        h.decref_tval(&self.prop_values()[ui]);
        mem::clear(&self.prop_values()[ui], (sz)(PropValue::size));
        self.prop_count = 0;
        uint old_slot = (uint)self.shape_id;
        self.shape_id = 0;
        h.free_shape_slot(old_slot, true);
    } else {
        // Build the replacement private shape and reserve its slot before the
        // compaction. A failed allocation then leaves the object untouched
        // instead of compacting values under a stale shape that still names the
        // deleted key at its old index, which would answer reads with a
        // neighbour's value.
        Shape* ns = shape_create(new_count, 0, PRIVATE_SHAPE_PARENT, null, h);
        if (ns == null) return false;
        uint slot = h.alloc_shape_slot();
        if (slot == heap::SHAPE_NONE) {
            // Keys were copied without incref, so shape_free must not decref.
            shape_free(ns, h, false);
            return false;
        }

        // Collect surviving property names by walking the old shape chain.
        // The walk visits the newest shape first, so place each key at its
        // absolute index, less one past the deleted slot, so appending in
        // walk order would reverse the key order relative to the values,
        // which are compacted in index order below.
        ShapeProperty* new_sp = ns.props();
        Shape* walk = self.get_shape(h);
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

        // Release the deleted slot's own reference before it is overwritten by
        // the compaction shift below.
        h.decref_tval(&self.prop_values()[ui]);

        // Shift the surviving values down over the deleted slot.
        for (uint i = ui; i < new_count; i++) {
            self.prop_values()[i] = self.prop_values()[i + 1];
        }
        mem::clear(&self.prop_values()[new_count], (sz)(PropValue::size));
        self.prop_count = new_count;

        // The surviving keys moved to `ns` uncounted, so the old slot must not
        // decref them. Only the deleted key's own reference is dropped, and
        // only when the old shape was private; a shared shape keeps its keys
        // for its other objects and is left untouched.
        uint old_slot = (uint)self.shape_id;
        Shape* old_shape = self.get_shape(h);
        bool old_was_private = old_shape != null
                            && old_shape.parent == PRIVATE_SHAPE_PARENT;
        h.store_new_shape(slot, ns);
        self.shape_id = slot;
        if (old_was_private && old_slot != slot) {
            if (key != null) h.decref((HeapHeader*)key);
            h.free_shape_slot(old_slot, false);
        }
    }

    // The fresh private shape has no hash table yet, and the surviving indices
    // have moved, so a per-object table from before the delete is stale. Drop it
    // and let the next lookup rebuild from the new shape if the count still
    // reaches HASH_MIN_PROPS.
    self.drop_prop_hash(h);

    return true;
}

// ============================================================================
// HObject: the dense array part
// ============================================================================

// The value at `idx` in the dense array part. Fails when the index is out of
// range or the slot holds `undefined`, which marks a hole.
fn TVal? HObject.get_array_idx(&self, uint idx) {
    if (self.array_part() == null || idx >= self.array_size) {
        return PROP_NOT_FOUND~;
    }
    TVal v = self.array_part()[idx];
    if (v.is_undefined()) {
        return PROP_NOT_FOUND~;
    }
    return v;
}

// Store a value in the dense array part, growing it if needed. Returns false
// when the index cannot go there, because of overflow or a failed grow, and the
// caller should then fall through to put_prop.
// Keep a materialised named "length" property in sync with array_len_ptr.
//
// Most arrays never get a named "length" entry: array_len_ptr is the sole
// source of truth and every reader falls back to it. But SETALEN (array
// literals) and arr_set_length_or_throw call put_prop with the "length" key,
// which creates a real prop_values() slot holding a snapshot of the length.
// Once that slot exists, any write that bumps array_len_ptr through a fast
// path bypassing put_prop's key==length_key branch must update it too, or a
// reader that finds the named property first sees a stale value. A no-op
// lookup for the common case where no such property exists.
fn void HObject.sync_named_length(&self, heap::Heap* h) {
    if (!self.flags.exotic_array) return;
    void* length_key = (void*)h.strs[heap::BuiltinStr.LENGTH];
    int idx = self.find_prop_idx(length_key, h);
    if (idx < 0) return;
    ulong len = (ulong)*self.array_len_ptr();
    TVal len_tv;
    if (len <= (ulong)types::FASTINT_MAX) {
        len_tv.set_fastint((long)len);
    } else {
        len_tv.set_number((double)len);
    }
    self.prop_values()[idx] = len_tv;
}

fn bool HObject.set_array_idx(&self, uint idx, TVal val, heap::Heap* h) {
    if (idx >= self.array_size) {
        uint new_size = self.array_size;
        if (new_size == 0) {
            new_size = ARRAY_INITIAL_SIZE;
        }
        // Double until the index fits, stopping before the size overflows uint.
        while (new_size <= idx) {
            if (new_size >= 0x80000000) { return false; }
            new_size *= 2;
        }
        self.grow_array(new_size, h);
        // A failed grow leaves array_size unchanged.
        if (idx >= self.array_size) {
            return false;
        }
    }

    // Keep array_used in step with holes appearing and disappearing.
    TVal old_val = self.array_part()[idx];
    if (old_val.is_undefined() && !val.is_undefined()) {
        self.array_used++;
    } else if (!old_val.is_undefined() && val.is_undefined()) {
        if (self.array_used > 0) {
            self.array_used--;
        }
    }

    // Incref before decref, for the reason given in put_prop.
    TVal* slot = &self.array_part()[idx];
    if (types::either_heap_allocated(&val, slot)) {
        if (val.is_heap_allocated()) {
            void* ptr = val.get_heapptr();
            if (ptr != null) {
                ((types::HeapHeader*)ptr).incref();
            }
        }
        if (slot.is_heap_allocated()) {
            h.decref_tval(slot);
        }
    }
    *slot = val;
    return true;
}

// ============================================================================
// HObject: growth and rehashing
// ============================================================================

// Grow a full property value table. Moving off inline storage, meaning
// prop_alloc is still null, copies the inline props and the array data into the
// new block.
fn void HObject.grow_props(&self, heap::Heap* h) {
    uint new_cap;
    if (self.prop_capacity <= INLINE_PROPS) {
        new_cap = PROPS_INITIAL_CAPACITY;
    } else {
        new_cap = self.prop_capacity * PROPS_GROW_NUM / PROPS_GROW_DEN;
        if (new_cap <= self.prop_capacity) {
            new_cap = self.prop_capacity + 4;
        }
    }
    usz new_prop_bytes = (usz)new_cap * PropValue::size;
    usz new_size = new_prop_bytes + (usz)self.array_size * TVal::size;

    void* new_raw;
    if (self.prop_alloc == null) {
        // Leaving inline storage: allocate, then copy the inline data across.
        new_raw = h.pool_alloc(new_size) ?? null;
        if (new_raw == null) return;
        PropValue* inline_src = self.inline_props_ptr();
        mem::copy(new_raw, inline_src, (sz)((usz)self.prop_count * PropValue::size));
    } else {
        // The size-class pools have no realloc, so grow by copying both parts
        // to their new offsets in a fresh block and releasing the old one to
        // its class pool. The old block never sits half-way between classes,
        // which is where the fragmentation came from.
        usz old_size = self.prop_alloc_size();
        usz old_prop_bytes = (usz)self.prop_capacity * PropValue::size;
        new_raw = h.pool_alloc(new_size) ?? null;
        if (new_raw == null) return;
        mem::copy(new_raw, self.prop_alloc, (sz)old_prop_bytes);
        if (self.array_size > 0) {
            mem::copy((char*)new_raw + new_prop_bytes,
                      (char*)self.prop_alloc + old_prop_bytes,
                      (sz)((usz)self.array_size * TVal::size));
        }
        h.pool_free(self.prop_alloc, old_size);
    }

    self.prop_alloc = new_raw;
    uint old_prop_capacity = self.prop_capacity;
    self.prop_capacity = new_cap;

    // prop_alloc may have moved, so inline caches holding prop_value pointers
    // must be invalidated. shape_id is unchanged, so the generation bump is what
    // does it.
    h.bump_shape_gen(self.shape_id);

    if (new_cap > old_prop_capacity) {
        usz added_bytes = (usz)(new_cap - old_prop_capacity) * PropValue::size;
        void* start = (void*)((char*)self.prop_values() + (usz)old_prop_capacity * PropValue::size);
        mem::clear(start, (sz)(added_bytes));
    }
}

// Grow the dense array part to at least `new_size` TVal slots.
//
// New slots are initialised to undefined.
// When prop_alloc is null (inline props), allocates a new heap block
// and copies inline prop values to it.
fn void HObject.grow_array(&self, uint new_size, heap::Heap* h) {
    if (new_size <= self.array_size) return;

    usz new_bytes = (usz)self.prop_capacity * PropValue::size + (usz)new_size * TVal::size;

    void* new_raw;
    if (self.prop_alloc == null) {
        // Transition from inline to heap: allocate and copy inline props.
        new_raw = h.pool_alloc(new_bytes) ?? null;
        if (new_raw == null) return;
        PropValue* inline_src = self.inline_props_ptr();
        mem::copy(new_raw, inline_src, (sz)((usz)self.prop_count * PropValue::size));
    } else {
        // The array part offset does not change, so a straight copy of the old
        // block puts every byte where the new one expects it.
        usz old_size = self.prop_alloc_size();
        new_raw = h.pool_alloc(new_bytes) ?? null;
        if (new_raw == null) return;
        mem::copy(new_raw, self.prop_alloc, (sz)old_size);
        h.pool_free(self.prop_alloc, old_size);
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

// ============================================================================
// Allocation / deallocation
// ============================================================================

// Allocate and initialise a new HObject of the given class.
//
// `heap_ptr` is an opaque Heap pointer. The caller inserts the object into the
// heap's GC list; Heap.alloc_object wraps both steps.
//
// Pool allocation first, malloc fallback when the pool is exhausted
// (flags.pool_fallback records which, so hobject_free routes the free).
//
// The object starts with htype OBJECT, extensible, class `cls`, an empty
// property table, and no array part. Returns `null` on allocation failure.
fn HObject*? hobject_alloc(void* heap_ptr, ObjClass cls) {
    usz alloc_sz = alloc_size_for_class(cls);

    // Try pool allocation first
    void* raw = null;
    bool from_pool = false;
$if $feature(POOL_BYPASS):
    // Debug builds route every object through the heap allocator instead of a
    // FixedBlockPool, because a pooled free is invisible to AddressSanitizer.
    // hobject_free returns a pooled object to its pool's freelist and never
    // calls free(), so ASan has nothing to poison: a use-after-free on a
    // pooled object reads memory that is still legitimately mapped, and
    // silently sees whichever object the pool has since handed out at that
    // address. That is exactly how a missed GC root corrupts state without
    // tripping any sanitizer. Taking the fallback path below makes every
    // object a genuine allocator alloc/free pair (flags.pool_fallback already
    // routes hobject_free accordingly), so ASan sees the free and reports the
    // offending read at the instruction that made it.
    //
    // This costs an allocator round-trip per object, so it belongs only in the
    // asan/gc-stress targets, never in a build anyone measures.
$else
    void* pool = pool_for_class(heap_ptr, cls);
    if (pool != null) {
        raw = ((mem::mempool::FixedBlockPool*)pool).alloc();
        from_pool = true;
    }
$endif

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
    } else if (cls == ObjClass.ERROR) {
        // All-zero bits are not a valid TVal, since undefined has its own
        // nanbox tag, so set it explicitly and no getter can read garbage.
        (*obj.extra_ptr()).err.captured_stack = types::make_undefined();
    }

    obj.shape_id = 0;
    return obj;
}

// Free an HObject and everything it owns: the property table and the array
// part. The caller has already unlinked it from the heap's GC list.
//
// A pooled object (no flags.pool_fallback) goes back to its FixedBlockPool;
// the rest are freed through the heap's allocator, or mem::free when no heap
// is active.
fn void hobject_free(HObject* obj, void* heap_ptr, bool free_header) {
    if (obj == null) { return; }
    // The owning heap, which every caller supplies. Its `tearing_down` flag,
    // not the presence of a heap, decides whether the decref passes below run:
    // destroy() and reset() free every node directly and must not also release
    // references into a string table they are sweeping.
    heap::Heap* hp = (heap::Heap*)heap_ptr;

    if (obj.flags.obj_class == ObjClass.REGEXP && (*obj.extra_ptr()).regexp.regexp_data != null) {
        re_bindings::re_free((*obj.extra_ptr()).regexp.regexp_data);
        (*obj.extra_ptr()).regexp.regexp_data = null;
    }

    // Release the promise's settled value. The reactions are HObjects the
    // collector owns, so they are dropped rather than freed.
    if (obj.flags.obj_class == ObjClass.PROMISE && !hp.tearing_down) {
        heap::Heap* h = hp;
        h.decref_tval(&(*obj.extra_ptr()).promise.result);
        (*obj.extra_ptr()).promise.reactions_head = null;
        (*obj.extra_ptr()).promise.reactions_tail = null;
    }

    // A detached buffer has already released its backing store.
    if (obj.flags.obj_class == ObjClass.ARRAYBUFFER && !hp.tearing_down) {
        heap::Heap* h = hp;
        if ((*obj.extra_ptr()).ab.data != null) {
            h.free_func(h.heap_udata, (*obj.extra_ptr()).ab.data);
            (*obj.extra_ptr()).ab.data = null;
        }
    }

    // Decref getter/setter inside GetterSetter cells.
    if (obj.flags.obj_class == ObjClass.GETTER_SETTER && !hp.tearing_down) {
        heap::Heap* h = hp;
        h.decref_tval(&(*obj.extra_ptr()).gs.getter);
        h.decref_tval(&(*obj.extra_ptr()).gs.setter);
    }

    // Release [[BoundTargetFunction]], [[BoundThis]], and [[BoundArguments]].
    // A bound function never sets captured_this, so this cannot overlap with the
    // arrow-capture release below.
    if (obj.flags.obj_class == ObjClass.FUNCTION && obj.flags.is_bound && !hp.tearing_down) {
        heap::Heap* h = hp;
        h.decref_tval(&(*obj.extra_ptr()).func.bound_target);
        h.decref_tval(&(*obj.extra_ptr()).func.bound_this);
        if ((*obj.extra_ptr()).func.bound_args != null) {
            h.decref((types::HeapHeader*)(*obj.extra_ptr()).func.bound_args);
        }
    } else if (obj.flags.obj_class == ObjClass.FUNCTION && !hp.tearing_down) {
        // Decref an arrow function's captured lexical `this`.
        heap::Heap* h = hp;
        h.decref_tval(&(*obj.extra_ptr()).func.captured_this);
    }

    // Decref the stack string captured at Error construction time.
    if (obj.flags.obj_class == ObjClass.ERROR && !hp.tearing_down) {
        heap::Heap* h = hp;
        h.decref_tval(&(*obj.extra_ptr()).err.captured_stack);
    }

    // Release the owned collection target held by array/map/set iterators.
    if ((obj.flags.obj_class == ObjClass.ARRAY_ITERATOR
        || obj.flags.obj_class == ObjClass.MAP_ITERATOR
        || obj.flags.obj_class == ObjClass.SET_ITERATOR)
        && !hp.tearing_down && (*obj.extra_ptr()).iter.target != null) {
        heap::Heap* h = hp;
        h.decref((types::HeapHeader*)(*obj.extra_ptr()).iter.target);
        (*obj.extra_ptr()).iter.target = null;
    }

    // Release this object's reference to its GeneratorState. A single gs can
    // be held by several HObjects: the GENERATOR instance, plus every
    // `is_async_state` reaction closure parking the pointer in func.var_env.
    // Each took a gs.ref_count through heap::gs_acquire, so the last teardown
    // performs the free. See heap::gs_release for why the count, not any gs
    // field, decides.
    if (obj.flags.obj_class == ObjClass.GENERATOR) {
        heap::GeneratorState* gs = (heap::GeneratorState*)(*obj.extra_ptr()).gen.generator_data;
        (*obj.extra_ptr()).gen.generator_data = null;
        heap::gs_release(gs, heap_ptr, hp != null && !hp.tearing_down);
    } else if (obj.flags.obj_class == ObjClass.FUNCTION && obj.flags.is_async_state) {
        heap::GeneratorState* gs = (heap::GeneratorState*)(*obj.extra_ptr()).func.var_env;
        (*obj.extra_ptr()).func.var_env = null;
        heap::gs_release(gs, heap_ptr, hp != null && !hp.tearing_down);
    }

    // Release property slots and array elements. A neighbour referenced here
    // can be dying in the same sweep (a cycle), so these go through
    // Heap.decref and its sweep guard. Mark-and-sweep reclaims cycles; this
    // pass never does.
    if (obj.prop_alloc != null && !hp.tearing_down) {
        heap::Heap* h = hp;
        PropValue* pvs = obj.prop_values();
        for (uint i = 0; i < obj.prop_count; i++) {
            if (pvs[i].is_heap_allocated()) {
                h.decref_tval(&pvs[i]);
            }
        }
        TVal* arr = obj.array_part();
        if (arr != null) {
            for (uint i = 0; i < obj.array_size; i++) {
                if (arr[i].is_heap_allocated()) {
                    h.decref_tval(&arr[i]);
                }
            }
        }
    }

    // Free the per-object property hash table.
    if (obj.prop_hash != null) {
        if (hp != null) {
            heap::Heap* h = hp;
            h.free_func(h.heap_udata, obj.prop_hash.table);
            h.free_func(h.heap_udata, obj.prop_hash);
        } else {
            mem::free(obj.prop_hash.table);
            mem::free(obj.prop_hash);
        }
        obj.prop_hash = null;
    }

    // The collection lookup index, for MAP/SET/WEAKMAP/WEAKSET. It holds
    // indices into array_part rather than references, so it needs freeing but
    // never GC tracing.
    if (obj.coll_hash != null) {
        if (hp != null) {
            heap::Heap* h = hp;
            if (obj.coll_hash.slots != null) { h.free_func(h.heap_udata, obj.coll_hash.slots); }
            h.free_func(h.heap_udata, obj.coll_hash);
        } else {
            if (obj.coll_hash.slots != null) { mem::free(obj.coll_hash.slots); }
            mem::free(obj.coll_hash);
        }
        obj.coll_hash = null;
    }

    // Free the block holding prop_values and array_part. The shape is shared
    // and owned by the heap, so it stays.
    if (obj.prop_alloc != null) {
        if (hp != null) {
            heap::Heap* h = hp;
            h.pool_free(obj.prop_alloc, obj.prop_alloc_size());
        } else {
            mem::free(obj.prop_alloc);
        }
        obj.prop_alloc = null;
    }

    // Release the header unless the caller deferred it. The sweep runs every
    // teardown before freeing any header, so no decref can read freed memory.
    if (free_header) {
        hobject_free_header(obj, heap_ptr);
    }
}

// Release just the header's backing memory, whether a pool block or a malloc,
// once hobject_free(obj, heap, false) has run the sub-allocation teardowns and
// decrefs. The sweep runs all teardowns before any header free, so nothing is
// read from memory another dying node already released.
fn void hobject_free_header(HObject* obj, void* heap_ptr) {
    if (obj == null) { return; }
    heap::Heap* hp = (heap::Heap*)heap_ptr;
    if (obj.flags.pool_fallback) {
        if (hp != null) {
            heap::Heap* h = hp;
            h.free_func(h.heap_udata, obj);
        } else {
            mem::free(obj);
        }
    } else {
        void* pool = pool_for_class(heap_ptr, obj.flags.obj_class);
        if (pool != null) {
            ((mem::mempool::FixedBlockPool*)pool).dealloc(obj);
        } else {
            if (hp != null) {
                heap::Heap* h = hp;
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

// Returns the number of own enumerable properties.
fn uint HObject.enumerable_count(&self, heap::Heap* h) {
    uint count = 0;
    for (uint i = 0; i < self.prop_count; i++) {
        if (self.get_prop_flags(i, h).enumerable) {
            count++;
        }
    }
    return count;
}

// Returns the property entry at the given raw index, or `null` if `idx`
// is out of range. Intended for iteration over own properties.
fn PropValue*? HObject.get_prop_at(&self, uint idx) {
    if (idx >= self.prop_count) {
        return PROP_NOT_FOUND~;
    }
    return &self.prop_values()[idx];
}

// ============================================================================
// Prototype-chain helpers
// ============================================================================

// Walk the prototype chain looking for a named property, returning the first
// match or PROP_NOT_FOUND. The depth limit stops circular prototype chains.
fn TVal? HObject.get_prop_proto(&self, void* key, heap::Heap* h) {
    HObject* cur = self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        // Proxy exotic anywhere on the chain: route the whole [[Get]] through
        // the trap machinery (receiver = the original object).
        if (cur.flags.exotic_proxyobj) {
            if (h.proxy_get_fn != null && h.vm_ptr != null) {
                TVal recv = types::make_object(self);
                TVal out;
                if (h.proxy_get_fn(h.vm_ptr, h, cur, key, recv, &out)) {
                    return out;
                }
            }
            return PROP_NOT_FOUND~;  // trap threw: error pending in heap
        }
        int idx = cur.find_prop_idx(key, h);
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

// Search the prototype chain for an accessor (getter or setter), returning it
// with its owning object for `this` binding, or `.found = false`. A data
// property found first stops the search.
fn AccessorResult HObject.find_accessor_proto(&self, void* key, bool want_getter, heap::Heap* h) {
    HObject* cur = self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        int idx = cur.find_prop_idx(key, h);
        if (idx >= 0) {
            if (cur.get_prop_flags((uint)idx, h).is_accessor) {
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

// ES5 §8.12.3 [[Get]] / ES2020 §10.1.8.1 OrdinaryGet: full prototype-chain
// Get semantics, invoking accessor getters. Used by builtins needing a full
// Get (e.g. Map/Set constructors looking up `set` / `add`).
fn PropLookupResult HObject.get_with_accessors(&self, void* key, heap::Heap* h) {
    return self.get_prop_or_accessor_proto(key, true, h);
}

// Maximum prototype chain depth before a chain is treated as circular.
const uint MAX_PROTO_DEPTH = 256;

// Result of a combined accessor + data property lookup.
enum PropLookupKind {
    PROP_ACCESSOR,
    PROP_DATA,
    PROP_NOT_FOUND
}

// Combined result of a prototype-chain lookup. Check `kind` first: PROP_DATA
// reads `data_val` (and optionally `owner`), PROP_ACCESSOR reads `acc`.
struct PropLookupResult {
    PropLookupKind kind;
    TVal data_val;
    HObject* owner;
    AccessorResult acc;
}

// ============================================================================
// Shape, the hidden class describing an object's property layout
// ============================================================================

// A Shape records an object's named-property structure: which properties
// exist, at what indices, with what flags. Adding a property moves an object
// to a child shape, so shapes form a transition tree, and objects that gain
// the same properties in the same order share one -- which is what lets an
// inline cache predict a property's offset.
//
// One allocation holds the header followed by the ShapeProperty array; values
// live per object in PropValue[].
struct Shape {
    // Bumped when the object's property storage is reallocated, which moves
    // the values without changing the shape id. Caches that hold a pointer
    // into that storage compare it so they notice the move.
    uint      generation;
    // Parent shape index, or PRIVATE_SHAPE_PARENT when the shape is flat and
    // belongs to a single object.
    uint      parent;
    // How many properties this shape adds, not counting its ancestors'.
    uint      own_count;
    // Offset into the object's prop_values where this shape's props start.
    uint      offset;
    // Parent pointer for walking the chain, null at the root.
    Shape*    parent_shape;
    // Key-to-index table covering the whole chain from root to this shape,
    // shared by every object using it. Built on first lookup once prop_count
    // reaches HASH_MIN_PROPS and a second object has reached this shape.
    // Valid for the shape's whole life: keys and indexes never change after
    // creation. Null until built, or permanently when allocation failed.
    HashEntry* hash_table;
    // Set when a second object reaches this shape through the transition
    // table. A hash table costs O(prop_count) to build and hold; only a shape
    // more than one object uses can amortize that, so unshared shapes walk
    // the chain.
    bool      shared;
}

// ============================================================================
// Shape: memory layout helpers
// ============================================================================

// The ShapeProperty array, which follows the header in the same allocation.
fn ShapeProperty* Shape.props(&self) {
    return (ShapeProperty*)((char*)self + Shape::size);
}

// Total byte size of a shape allocation.
fn usz shape_alloc_size(uint own_count) {
    return Shape::size + (usz)own_count * ShapeProperty::size;
}

// Create a shape holding `own_count` properties of its own, which are the ones
// it adds to its parent chain. `offset` is where they start in the object's
// prop_values. `parent_id` and `parent_shape` identify the parent, and are
// SHAPE_NONE and null at the root. The shape's memory comes from `h`, the heap
// that will own it.
fn Shape* shape_create(uint own_count, uint offset, uint parent_id, Shape* parent_shape, heap::Heap* h) {
    usz bytes = shape_alloc_size(own_count);
    void* raw = h.alloc_func(h.heap_udata, bytes);
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

// Extend `parent` with one more property, storing only that property. Returns
// null if allocation fails.
fn Shape* shape_extend(Shape* parent, uint parent_id, void* new_key, PropFlags flags, heap::Heap* h) {
    uint offset = parent.offset + parent.own_count;
    Shape* ns = shape_create(1, offset, parent_id, parent, h);
    if (ns == null) return null;

    ns.props()[0].key   = new_key;
    ns.props()[0].flags = flags;

    // The shape now holds a reference to the key.
    if (new_key != null) {
        ((types::HeapHeader*)new_key).incref();
    }

    return ns;
}

// Build the hash table of `leaf`, covering every key from the root of the
// chain down to `leaf` itself. The shape chain is the authoritative key
// list, and it is immutable, so the finished table serves every object that
// shares the shape for the shape's whole life. Leaves hash_table null when
// the allocation fails; lookups then fall back to walking the chain.
fn void shape_build_hash(Shape* leaf, heap::Heap* h) {
    uint total = leaf.offset + leaf.own_count;
    uint mask = prop_hash_mask_for(total);
    usz bytes = (usz)(mask + 1) * HashEntry::size;
    HashEntry* entries = (HashEntry*)h.alloc_func(h.heap_udata, bytes);
    if (entries == null) return;
    mem::clear(entries, (sz)bytes);

    Shape* sh = leaf;
    while (sh != null) {
        ShapeProperty* sp = sh.props();
        for (uint j = 0; j < sh.own_count; j++) {
            void* k = sp[j].key;
            if (k == null) continue;
            uint slot = hash_key(k) & mask;
            while (entries[slot].key != null) slot = (slot + 1) & mask;
            entries[slot].key = k;
            entries[slot].index = sh.offset + j;
        }
        sh = sh.parent_shape;
    }
    leaf.hash_table = entries;
}

// Free a shape's backing memory, optionally releasing the key references it
// holds.
//
// `release_keys` is separate from the heap because the two questions are
// unrelated: a shape built by copying keys from another shape never took its
// own references and must not drop them, while the memory still belongs to
// this heap either way.
fn void shape_free(Shape* sh, heap::Heap* h, bool release_keys) {
    if (sh == null) return;
    if (release_keys) {
        ShapeProperty* sp = sh.props();
        for (uint i = 0; i < sh.own_count; i++) {
            if (sp[i].key != null) {
                h.decref((HeapHeader*)sp[i].key);
            }
        }
    }
    if (sh.hash_table != null) h.free_func(h.heap_udata, sh.hash_table);
    h.free_func(h.heap_udata, sh);
}

// ============================================================================
// ICEntry, one monomorphic inline cache entry per site
// ============================================================================

// Longest prototype chain an ICEntry can validate. Each level costs a pointer
// and a uint per entry, and entries are one per instruction; four covers an
// instance reaching a method a few subclasses up.
const uint IC_MAX_CHAIN = 4;

// One inline cache entry per GETPROP or PUTPROP site: the last lookup's
// result, so a later access on the same shape skips the prototype-chain walk.
//
// An entry covers a property up to IC_MAX_CHAIN links up the prototype chain,
// which is only sound while no intermediate has gained a shadowing property
// and no link has been repointed. The entry snapshots each intermediate's
// identity and shape, and the hit path replays that walk as pointer and
// shape-ID comparisons.
struct ICEntry {
    // Shape ID of the object when this entry was populated.
    uint   shape_id;
    // The receiver shape's generation when populated. A shape id is recycled,
    // so (id, generation) pairs uniquely name one layout.
    uint   shape_gen;
    // Property index within the owner's prop_values[].
    uint   prop_idx;
    // The property's flags, so a cache hit needs no shape walk.
    PropFlags prop_flags;
    // Number of prototype links from the receiver to the owner, so the last
    // link lands on the owner itself. Zero marks an own property.
    char   chain_len;
    // Shape of each object stepped onto, ending with the owner, so a property
    // added or deleted anywhere along the walk invalidates this entry.
    uint[IC_MAX_CHAIN] chain_shapes;
    // Each object stepped onto, ending with the owner, held as a weak pointer
    // compared only for identity against the live chain.
    void*[IC_MAX_CHAIN] chain_protos;
    // Where the property was found, or null when it is an own property.
    void*  proto;
    // The interned key this entry was filled for, compared by pointer.
    void*  key;
    // Direct pointer to the resolved PropValue, valid only while the owner's
    // prop_alloc still matches the snapshot below.
    TVal* prop_value_ptr;
    // The owner's prop_alloc when this entry was filled. A hit requires it to
    // still match, which is one pointer comparison.
    void*  cached_prop_alloc;
}

// This object's shape generation, or a value no entry can match when it has
// no shape. Paired with shape_id it names one property layout uniquely, since
// a recycled id is always stamped with a fresh generation.
fn uint HObject.shape_generation(&self, heap::Heap* h) @inline {
    Shape* sh = self.get_shape(h);
    return sh != null ? sh.generation : 0xFFFFFFFFu;
}

// Resolve the owner an ICEntry points at, or null when the entry no longer
// describes the live graph. The caller checks the receiver's own shape_id;
// this replays the recorded prototype walk, rejecting a repointed link, a
// shadowing property on an intermediate, and a delete on the owner (which
// moves the owner's shape but not its prop_alloc).
fn HObject* ic_resolve_owner(ICEntry* ic, HObject* hobj) @inline {
    if (ic.proto == null) return hobj;
    HObject* cur = hobj;
    uint links = (uint)ic.chain_len;
    for (uint i = 0; i < links; i++) {
        cur = cur.prototype;
        if (cur != (HObject*)ic.chain_protos[i]) return null;
        if (cur.shape_id != ic.chain_shapes[i]) return null;
    }
    return (HObject*)ic.proto;
}

// One entry in the global megamorphic cache, keyed by (shape_id, key), shared
// by every call site.
//
// Covers an own property or one found on the receiver's immediate prototype.
// A shape does not name a prototype, which Object.setPrototypeOf can repoint
// without touching shapes, so the entry also snapshots the prototype's
// identity and shape for the hit path to re-check.
struct MegamorphicEntry {
    void*   key;           // interned key pointer (null = empty slot)
    uint    shape_id;      // receiver's shape ID at lookup time
    uint    prop_idx;      // property index in owner.prop_values[]
    void*   proto;         // owning prototype (null = own property)
    // The owning prototype's shape when the entry was filled, so a property
    // added to or deleted from it is noticed. Meaningless when `proto` is null.
    uint    proto_shape_id;
    // The heap's shape-recycle epoch at population time: a freed shape id is
    // handed back out, so comparing the epoch says whether the id still names
    // the shape this entry was filled for.
    uint    recycle_epoch;
    TVal*   prop_value_ptr; // direct pointer to value slot
    void*   cached_prop_alloc; // owner.prop_values() snapshot for invalidation
    // True when prop_value_ptr names an accessor cell rather than a data value.
    bool    is_accessor;
}

// Hash function for megamorphic cache lookup.
fn uint mega_hash(uint shape_id, void* key) @inline {
    return ((uint)(uptr)key ^ (shape_id * 2654435761u)) & (heap::MEGA_CACHE_SIZE - 1);
}

// Probe the megamorphic cache, returning the entry on a hit and null on a miss.
fn MegamorphicEntry* mega_cache_lookup(heap::Heap* h, HObject* hobj, void* key) @inline {
    if (h.mega_cache == null) return null;
    uint slot = mega_hash(hobj.shape_id, key);
    MegamorphicEntry* e = h.mega_cache + slot;
    if (e.key != key || e.shape_id != hobj.shape_id) return null;
    if (e.recycle_epoch != h.shape_recycle_epoch) return null;
    HObject* owner = hobj;
    if (e.proto != null) {
        // The receiver's shape says it has no own `key`; the recorded link must
        // still be the live one, at the same shape, for the owner to answer.
        owner = (HObject*)e.proto;
        if (hobj.prototype != owner) return null;
        if (owner.shape_id != e.proto_shape_id) return null;
    }
    if (e.cached_prop_alloc != (void*)owner.prop_values()) return null;
    return e;
}

// Record a successful lookup in the megamorphic cache.
//
// Own properties and properties on the receiver's immediate prototype are
// stored; anything deeper is not, since the entry has room to re-check only
// one link and a longer chain could change out of sight.
fn void mega_cache_store(heap::Heap* h, HObject* hobj, void* key, HObject* owner, int prop_idx, bool is_accessor) @inline {
    if (h.mega_cache == null) return;
    bool own = owner == hobj;
    if (!own && hobj.prototype != owner) return;
    uint slot = mega_hash(hobj.shape_id, key);
    MegamorphicEntry* e = h.mega_cache + slot;
    e.key = key;
    e.shape_id = hobj.shape_id;
    e.prop_idx = (uint)prop_idx;
    e.proto = own ? null : (void*)owner;
    e.proto_shape_id = owner.shape_id;
    e.recycle_epoch = h.shape_recycle_epoch;
    e.prop_value_ptr = &owner.prop_values()[prop_idx];
    e.cached_prop_alloc = (void*)owner.prop_values();
    e.is_accessor = is_accessor;
}

// Inline cache for a GETVAR or TYPEOFIDENT site: the resolved environment
// record and property index, so later accesses skip the scope-chain walk.
struct VarICEntry {
    // The EnvRecord* owning the binding, null while unpopulated.
    void*   env;
    // The env's bindings object, whose shape the hit check compares.
    void*   bindings;
    // Shape ID of the bindings object when this entry was populated.
    uint    shape_id;
    // The heap's shape-recycle epoch at population time. Shape ids are reused,
    // so comparing the epoch says whether the id still names the filled shape;
    // this costs a load the hit path already has in cache instead of reaching
    // into the shapes table for the shape's generation.
    uint    recycle_epoch;
    // Property index within bindings.props[].
    uint    prop_idx;
    // The interned key this entry was filled for.
    void*   key;
    // act.lex_env at population time; a hit requires the same chain head
    // so entries never serve a different activation's environment.
    void*   search_head;
    // Set for PUTGLOBAL/INC_GLOBAL/DEC_GLOBAL/MOVE_GG slots whose property is
    // a writable but non-configurable data property (ES §9.3.4
    // CreateGlobalVarBinding): such a descriptor can never become an accessor
    // or turn read-only, so the store fast path skips re-checking writability.
    // Configurable globals (e.g. from `eval`) leave this false and take the
    // checking path; the shape_id compare runs either way.
    bool    varref_store_ok;
}

// Populate a variable IC entry, writing every guard field together: readers
// compare shape_id, recycle_epoch, key and search_head, and a partial fill can
// leave a previous occupant's stale value looking valid. `key` is a reference
// the GC sweep marks, so the old key is released and the new one held.
fn void var_ic_fill(VarICEntry* vic, void* env, void* bindings, uint shape_id,
                    uint prop_idx, void* key, void* search_head, bool store_ok,
                    heap::Heap* h) {
    vic.env = env;
    vic.bindings = bindings;
    vic.shape_id = shape_id;
    vic.prop_idx = prop_idx;
    vic.recycle_epoch = h.shape_recycle_epoch;
    if (vic.key != null) { h.decref((types::HeapHeader*)vic.key); }
    vic.key = key;
    if (key != null) { ((types::HeapHeader*)key).incref(); }
    vic.search_head = search_head;
    vic.varref_store_ok = store_ok;
}

// True when the megamorphic cache may answer a getter lookup on this receiver.
// A hit reports straight from the property table, so excluded are proxies
// ([[Get]] runs a trap), exotic arrays/arguments (dense part and array_len_ptr
// can answer instead of the table), and string wrappers (indexed keys are read
// from the primitive by the caller).
//
// The same test gates storing.
macro bool HObject.mega_cacheable(&self) {
    return !self.flags.exotic_proxyobj
        && !self.flags.exotic_array
        && !self.flags.exotic_stringobj
        && self.get_class() != ObjClass.ARGUMENTS;
}

// Walk the prototype chain once, returning whichever of an accessor or a data
// property is found first, along with its owner.
//
// Every full Get in the engine funnels through here: the VM's GETPROP slow
// path, builtins' spec-mandated Gets, and the coercion helpers. The megamorphic
// cache is probed here so all call sites share one invalidation story.
fn PropLookupResult HObject.get_prop_or_accessor_proto(&self, void* key, bool want_getter, heap::Heap* h) {
    HObject* cur = self;
    uint depth = 0;

    if (want_getter && self.mega_cacheable()) {
        MegamorphicEntry* me = mega_cache_lookup(h, self, key);
        if (me != null) {
            if (me.is_accessor) {
                return {
                    .kind = PropLookupKind.PROP_ACCESSOR,
                    .owner = me.proto == null ? self : (HObject*)me.proto,
                    .acc = {
                        .accessor_fn = hobject_access_getter(*me.prop_value_ptr),
                        .this_obj = self,
                        .found = true
                    }
                };
            }
            return {
                .kind = PropLookupKind.PROP_DATA,
                .data_val = *me.prop_value_ptr,
                .owner = me.proto == null ? self : (HObject*)me.proto
            };
        }
    }

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        // A proxy on the chain runs a getter search through the trap machinery
        // and reports the result as a data property with no owner, which keeps
        // inline caches from being populated. A setter search returns
        // PROP_NOT_FOUND, since PUTPROP's own proxy check handles [[Set]].
        if (cur.flags.exotic_proxyobj && want_getter) {
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
        int idx = cur.find_prop_idx(key, h);
        if (idx >= 0) {
            if (cur.get_prop_flags((uint)idx, h).is_accessor) {
                TVal gs_slot = cur.prop_values()[idx];
                TVal accessor_fn = want_getter ? hobject_access_getter(gs_slot) : hobject_access_setter(gs_slot);
                if (want_getter && depth <= 1 && self.mega_cacheable()) {
                    mega_cache_store(h, self, key, cur, idx, true);
                }
                return {
                    .kind = PropLookupKind.PROP_ACCESSOR,
                    .acc = {
                        .accessor_fn = accessor_fn,
                        .this_obj = self,
                        .found = true
                    }
                };
            }
            // Record the hit so the next lookup of this (shape, key) skips the
            // walk. mega_cache_store rejects an owner further than one link
            // away, so only depth 0 and 1 are offered.
            if (want_getter && depth <= 1 && self.mega_cacheable()) {
                mega_cache_store(h, self, key, cur, idx, false);
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
        if (cur.get_class() == ObjClass.ARRAY
            && key == (void*)h.strs[heap::BuiltinStr.LENGTH]) {
            return {
                .kind = PropLookupKind.PROP_DATA,
                .data_val = types::make_fastint((long)*cur.array_len_ptr()),
                .owner = null
            };
        }
        cur = cur.prototype;
        depth++;
    }

    return { .kind = PropLookupKind.PROP_NOT_FOUND };
}

// Check whether the property exists anywhere on the prototype chain.
fn bool HObject.has_prop_proto(&self, void* key, heap::Heap* h) {
    HObject* cur = self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        // Proxy exotic on the chain: route through the [[Has]] trap.
        if (cur.flags.exotic_proxyobj) {
            if (h.proxy_has_fn != null && h.vm_ptr != null) {
                bool has;
                if (h.proxy_has_fn(h.vm_ptr, h, cur, key, &has)) {
                    return has;
                }
            }
            return false;
        }
        if (cur.find_prop_idx(key, h) >= 0) {
            return true;
        }
        // ARRAY exotic: "length" lives in array_len_ptr.
        if (cur.get_class() == ObjClass.ARRAY
            && key == (void*)h.strs[heap::BuiltinStr.LENGTH]) {
            return true;
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

// Returns true if `probe` appears anywhere in the prototype chain of `self`.
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

// ES5 [[Delete]]: remove an own property.
//
// Returns true if the property was successfully removed or not found.
// Returns false only if the property exists and is non-configurable.
// The caller is responsible for throwing in strict mode when false.
fn bool HObject.es_delete_prop(&self, void* key, heap::Heap* h) {
    int idx = self.find_prop_idx(key, h);
    if (idx >= 0) {
        if (!self.get_prop_flags((uint)idx, h).configurable) {
            return false;  // Non-configurable → [[Delete]] returns false.
        }
        // delete_prop() clears the dense array slot (if any) as part of the
        // named-table removal.
        return self.delete_prop(key, h);
    }
    // String exotic (§10.4.3): char indices [0, char_length) are virtual
    // non-configurable own properties served via exotic_stringobj (never
    // materialised in the named table), so [[Delete]] on them must return
    // false even though find_prop_idx misses.
    if (key != null && self.flags.exotic_stringobj) {
        HString* skey = (HString*)key;
        if (skey.is_arridx()) {
            TVal prim = (*self.extra_ptr()).prim.primitive_value;
            if (prim.is_string()) {
                HString* pstr = (HString*)prim.get_heapptr();
                if (pstr != null && skey.array_index() < (ulong)pstr.char_length()) {
                    return false;
                }
            }
        }
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
                    self.set_array_idx(ai, undef, h);
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

