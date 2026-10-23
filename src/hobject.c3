// HObject, the representation behind every ECMAScript object. Each carries a
// HeapHeader-compatible prefix of flags and GC metadata, a prototype
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
import boomkat::features;
import boomkat::hstring;
import boomkat::hbigint;
import boomkat::bytecode;
import boomkat::env;
import boomkat::re_bindings;
import boomkat::heap;
import boomkat::lib::temporal;
import boomkat::pagepool;
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
// scope chain. Each pool cell's bindings object is an ordinary heap node:
// marking only the innermost link would miss enclosing scopes' bindings.
fn void* env_record_parent(void* env_ptr) {
    if (env_ptr == null) return null;
    return (void*)((env::EnvRecord*)env_ptr).parent;
}

// Free every environment pool block and reset the pool accounting. heap.c3
// owns the pool but cannot see EnvPoolBlock, so destroy and reset route the
// teardown through here.
fn void env_pool_teardown(heap::Heap* h) {
    env::env_pool_teardown(h);
}

// True when `env_ptr` is a cell-aligned member of `h`'s pool. HEAP_VERIFY's
// mark_env_chain check uses this to confirm a traced EnvRecord* is real.
fn bool env_pool_contains(heap::Heap* h, void* env_ptr) {
    return env_ptr != null && env::env_pool_contains(h, (env::EnvRecord*)env_ptr);
}

// Scan the pool's cells at collection start, clearing temporary-root pins at a
// quiescent safepoint or tracing every pinned cell's chain otherwise.
fn void env_pool_seed_or_clear_pins(heap::Heap* h, bool clear_pins) {
    env::env_pool_seed_or_clear_pins(h, clear_pins);
}

fn void env_pool_align_epoch(heap::Heap* h) {
    env::env_pool_align_epoch(h);
}

// Reclaim dead pool cells after a collection, releasing empty blocks and
// rebuilding the freelist. Runs after object sweep so bindings may already be
// freed; the sweep clears cell bytes without dereferencing them.
fn void env_pool_sweep(heap::Heap* h) {
    env::env_pool_sweep(h);
}

fn bool env_pool_sweep_slice(heap::Heap* h, uint budget) {
    return env::env_pool_sweep_step(h, &h.gc_env_sweep_cursor, budget);
}

fn bool env_pool_mark_slice(heap::Heap* h, uint budget) {
    return env::env_pool_mark_step(h, &h.gc_aux_env_cursor, budget);
}

// Flag/epoch accessors for heap.c3's first-visit mark and the pool sweep. Each
// reads or writes one EnvFlags bit through the opaque EnvRecord* so heap.c3
// never sees the record layout.
fn bool env_record_is_allocated(void* env_ptr) {
    return env_ptr != null && ((env::EnvRecord*)env_ptr).flags.allocated;
}

fn bool env_record_get_epoch(void* env_ptr) {
    return ((env::EnvRecord*)env_ptr).flags.mark_epoch;
}

fn void env_record_set_epoch(void* env_ptr, bool epoch) {
    ((env::EnvRecord*)env_ptr).flags.mark_epoch = epoch;
}

fn bool env_record_is_temproot(void* env_ptr) {
    return ((env::EnvRecord*)env_ptr).flags.temproot;
}

fn void env_record_clear_temproot(void* env_ptr) {
    ((env::EnvRecord*)env_ptr).flags.temproot = false;
}

fn void* env_record_gray_next(void* env_ptr) {
    return ((env::EnvRecord*)env_ptr).gc_gray_next;
}

fn void env_record_set_gray_next(void* env_ptr, void* next) {
    ((env::EnvRecord*)env_ptr).gc_gray_next = next;
}

fn bool env_record_gray_queued(void* env_ptr) {
    return ((env::EnvRecord*)env_ptr).gc_gray_queued;
}

fn void env_record_set_gray_queued(void* env_ptr, bool queued) {
    ((env::EnvRecord*)env_ptr).gc_gray_queued = queued;
}

// ============================================================================
// Constants
// ============================================================================

// PropValue slots carried inside the object allocation, after HObjectBase and
// any subtype fields. An object with no more than this many named properties,
// which is the common case, needs no separate prop_alloc.
const uint INLINE_PROPS = 4;
const uint COMPACT_INLINE_PROPS = 2;

const uint PROPS_INITIAL_CAPACITY = 8;

const uint ARRAY_INITIAL_SIZE = 16;

// Property table growth factor, as numerator over denominator, so 1.5x.
const uint PROPS_GROW_NUM = 3;
const uint PROPS_GROW_DEN = 2;

// Property count at which a hash table is worth building. Below it, the linear
// scan is faster.
const uint HASH_MIN_PROPS = 8;
// Entries a collection must hold before it builds a CollHashInfo. Below this,
// a linear scan over array_part is faster.
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
    // ECMA-262 Object Environment Record.
    OBJENV,
    // ECMA-262 Declarative Environment Record.
    DECENV,
    BIGINT,
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
    PROMISE_REACTION,
    ASYNC_CONTINUATION,
    GENERATOR,
    ARRAY_ITERATOR,
    STRING_ITERATOR,
    MAP_ITERATOR,
    SET_ITERATOR,
    REGEXP_STRING_ITERATOR,
    // Iterator Helper, the lazy result of map, filter, take, drop, or flatMap.
    // Backed by HObjectIteratorHelper rather than a generator.
    ITERATOR_HELPER,
    // %WrapForValidIteratorPrototype% instance, created by Iterator.from() to
    // adapt a plain iterator and next pair.
    WRAP_FOR_VALID_ITERATOR,
    // Internal GC cell for boxed accessor pairs (getter + setter).
    GETTER_SETTER,
    // Temporal proposal (Stage 4, shipped in V8/Safari/JSC). One shared
    // HObjectTemporal variant backs every Temporal class; obj_class
    // discriminates which internal slots are live. Runtime-registered host
    // classes preserve the limited ObjClass namespace; Temporal can use HOST
    // to reclaim its entries.
    TEMPORAL_PLAIN_DATE,      // Temporal.PlainDate
    TEMPORAL_PLAIN_TIME,      // Temporal.PlainTime
    TEMPORAL_PLAIN_DATETIME,  // Temporal.PlainDateTime
    TEMPORAL_PLAIN_YEARMONTH, // Temporal.PlainYearMonth
    TEMPORAL_PLAIN_MONTHDAY,  // Temporal.PlainMonthDay
    TEMPORAL_DURATION,        // Temporal.Duration
    TEMPORAL_INSTANT,         // Temporal.Instant (Phase 2)
    TEMPORAL_TIMEZONE,        // Temporal.TimeZone (Phase 2)
    TEMPORAL_ZONEDDATETIME,   // Temporal.ZonedDateTime (Phase 2)
    // Instance of a runtime-registered host class (embedder or add-on). The
    // concrete type is Heap.host_classes[extra.host.class_id]; see HostClass.
    HOST,
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
    // truth for [[Writable]] of length (ECMA-262 ArraySetLength). Set
    // false by Object.freeze and Object.defineProperty(arr,"length",{writable:false}).
    bool array_len_writable : 25;
    // [[IsRawJSON]], set on objects that JSON.rawJSON returns.
    // JSON.isRawJSON tests it; JSON.stringify embeds the "rawJSON" property
    // verbatim when serialising such an object.
    bool is_raw_json        : 26;
    // Set when any property other than a default WEC data property is
    // installed: an accessor, or one that is read-only, non-enumerable, or
    // non-configurable. Never cleared, so it is conservative.
    //
    // While it is false, get_prop_flags() returns PROP_FLAGS_WEC in O(1).
    // Walking the shape chain would be O(depth), and dictionary-mode objects
    // built by loops like `for (i) obj[i]=v` gain a node per property, so bulk
    // reads would be O(N^2).
    bool has_nondefault_flags : 27;
    // Module Namespace Exotic Object (ECMA-262). Exports are stored as
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
    // Deferred Module Namespace Exotic Object (import defer). Wraps a
    // module whose evaluation has not been forced yet: it carries the same
    // export accessors as a plain namespace (exotic_module_ns is set too), but
    // any string-keyed MOP operation must first evaluate the module graph.
    // Symbol keys and the prototype/extensibility operations never trigger it,
    // which is what makes `ns[Symbol()]` and `Object.isExtensible(ns)`
    // observable without evaluating.
    bool exotic_deferred_ns : 30;
    // Module Source object (source phase imports), the value an
    // `import source x from "m"` binding holds. Stands in for the spec's
    // [[ModuleSourceClassName]] internal slot: %AbstractModuleSource%'s
    // Symbol.toStringTag getter returns undefined for anything without it,
    // which is how the spec distinguishes a real module source from an
    // ordinary object that merely inherits the prototype.
    //
    // These objects are created lazily -- only a module actually named by a
    // source-phase import ever gets one (see module_source_object).
    bool is_module_source : 31;
}

$assert ObjClass::len <= (1 << $reflect(ObjFlags.obj_class).bitsize);

// Sets the temproot flag on this object.
fn void HObject.set_temproot(&self) @inline {
    ((types::HeapHeader*)self).set_temproot();
}

// Called after a change that moves this object's property values or alters an
// existing property's index or flags. A variable inline cache that bound the
// object keeps a pointer to the slot and the flags it saw, so the shared epoch
// bump is what ends its validity. Adding a property leaves both untouched.
tlocal ulong[3] opprof_epoch;
tlocal ulong[8] opprof_shape_site;
tlocal ulong[64] opprof_private_class;
tlocal ulong[64] opprof_dict_class;

fn void HObject.layout_moved(&self, heap::Heap* h) @inline {
    if (self.gc.ic_bound) {
        h.shape_recycle_epoch++;
        $if $feat(OP_PROFILE): opprof_epoch[2]++; $endif
    }
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
    // Non-writable binding from CreateImmutableBinding(N, false), as used for a
    // named function expression's own name. Assignment from sloppy code
    // silently no-ops; from strict code it throws. Ordinary object properties
    // never set this.
    bool immut_nonstrict : 4;
    // Own data property is a private method or accessor, installed by
    // PrivateMethodOrAccessorAdd. With the hidden-symbol key, this tells a
    // private field (writable bit ignored by PrivateSet) from a private
    // method or accessor (PrivateSet throws a TypeError). Ordinary object
    // properties never set this.
    bool is_private_method : 5;
}

// The flags a plain assignment creates: writable, enumerable, configurable.
const PropFlags PROP_FLAGS_WEC = {
    .writable     = true,
    .enumerable   = true,
    .configurable = true,
    .is_accessor  = false
};

// non-enumerable data property (writable, configurable).
// Used for built-in prototype methods.
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
// Used for global `var`/FunctionDeclaration bindings (ECMA-262
// CreateGlobalVarBinding and CreateGlobalFunctionBinding). The global object's
// own property for a script-level var or function is non-configurable, so it
// cannot be deleted, but stays writable and enumerable.
const PropFlags PROP_FLAGS_WE = {
    .writable     = true,
    .enumerable   = true,
    .configurable = false,
    .is_accessor  = false
};

// non-configurable data property (writable, enumerable).
// Used for the class constructor .prototype property (ECMA-262
// ClassDefinitionEvaluation): writable, non-enumerable, non-configurable.
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

// Class accessor property: non-enumerable, configurable, as set by
// ECMA-262 ClassDefinitionEvaluation.
const PropFlags PROP_FLAGS_CLASS_ACCESSOR = {
    .writable     = false,
    .enumerable   = false,
    .configurable = true,
    .is_accessor  = true
};

// Class method property: writable, non-enumerable, configurable, as set by
// ECMA-262 ClassDefinitionEvaluation.
const PropFlags PROP_FLAGS_CLASS_METHOD = {
    .writable     = true,
    .enumerable   = false,
    .configurable = true,
    .is_accessor  = false
};

// Private accessor property. PrivateMethodOrAccessorAdd, via PrivateElement,
// makes these non-configurable, where the public class accessors of
// PROP_FLAGS_CLASS_ACCESSOR stay configurable.
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

// The String exotic .length property (ECMA-262 String exotic objects).
const PropFlags PROP_FLAGS_NNC = {
    .writable     = false,
    .enumerable   = false,
    .configurable = false,
    .is_accessor  = false
};

// String exotic indexed properties (ECMA-262 String exotic objects).
const PropFlags PROP_FLAGS_NEC = {
    .writable     = true,
    .enumerable   = true,
    .configurable = false,
    .is_accessor  = false
};

// Result of searching the prototype chain for the first property descriptor.
struct AccessorResult {
    // The getter or setter TVal (function), or undefined if not found.
    TVal accessor_fn;
    // The object that owns the accessor (needed for `this` binding).
    HObject* this_obj;
    // Whether the first property is an accessor.
    bool found;
    // Whether any own property stopped the prototype walk. For a data
    // property, `found` remains false and `property_writable` carries its flag.
    bool property_found;
    bool property_writable;
}

// ============================================================================
// PropValue, the per-object property value storage
// ============================================================================

// One TVal per property slot, 8 bytes when NaN-boxed. A data property holds its
// value directly; an accessor property holds a pointer to a GETTER_SETTER
// object. Shape.PropFlags.is_accessor says which a reader is looking at.
//
// A distinct type with no implicit conversion either way, so every access
// states what it does and the compiler finds every store: a store into an
// object that may be old must pass the write barrier (plans/093).
//
//   get()            read the value
//   set_untraced(v)  store a value the collector does not trace
//   Heap.store_slot / store_slot_ref   store anything, with the barrier
typedef PropValue = TVal;

fn TVal PropValue.get(&self) @inline => (TVal)*self;

// Release this slot's owned refcounted payload without exposing a writable
// TVal pointer. The caller replaces or clears the slot separately.
fn void PropValue.release_ref(&self, heap::Heap* h) @inline {
    TVal value = self.get();
    h.decref_tval(&value);
}

<*
 Store a value no collector traces, such as a number, boolean or string. It
 cannot create an old-to-young edge, so it needs no barrier.
 @require !v.is_traced() : "a traced value must be stored with Heap.store_slot"
*>
fn void PropValue.set_untraced(&self, TVal v) @inline {
    *self = (PropValue)v;
}

fn void PropValue.set_undefined(&self) @inline {
    TVal u;
    u.set_undefined();
    *self = (PropValue)u;
}

fn void PropValue.set_fastint(&self, long v) @inline {
    TVal t;
    t.set_fastint(v);
    *self = (PropValue)t;
}

fn void PropValue.set_number(&self, double v) @inline {
    TVal t;
    t.set_number(v);
    *self = (PropValue)t;
}

// Store the Map/Set deletion sentinel.
fn void PropValue.set_deleted(&self) @inline {
    TVal d;
    d.set_deleted();
    *self = (PropValue)d;
}

// ---------------------------------------------------------------------------
// Boxed accessor pair helpers
// ---------------------------------------------------------------------------

// Allocate a GETTER_SETTER cell and return it as an object TVal.
fn TVal hobject_create_accessors(heap::Heap* h, TVal getter, TVal setter) {
    HObject*? gs_obj = h.alloc_object(ObjClass.GETTER_SETTER);
    if (try gs = gs_obj) {
        h.@set_edge(gs, (*gs.extra_ptr()).gs.getter, getter);
        h.@set_edge(gs, (*gs.extra_ptr()).gs.setter, setter);
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
    h.@set_edge(gs, (*gs.extra_ptr()).gs.getter, new_getter);
}

// Update the setter inside an existing GetterSetter cell (refcounted).
fn void hobject_set_access_setter(TVal slot, TVal new_setter, heap::Heap* h) {
    HObject* gs = (HObject*)slot.get_heapptr();
    h.@set_edge(gs, (*gs.extra_ptr()).gs.setter, new_setter);
}

// ============================================================================
// ShapeProperty, a property descriptor inside a Shape
// ============================================================================

// One entry in a Shape's property array: the key and its flags. Values are
// per-object and live in the object's own slots.
struct ShapeProperty {
    // Each shape owns its keys independently of its parent and other shapes.
    hstring::StringRef key;
    // Property attribute flags.
    PropFlags flags;
}

// ============================================================================
// HObject: the subtype structs of the HObjectExtra union
// ============================================================================

// Compiled function / native builtin extra fields.
struct CaptureRef {
    union {
        HObject* owner;
        TVal value;
    }
    uint     prop_idx;
    bool     is_cell;
    bool     guard_shadow;
    bool     is_value;
}

struct HObjectBound {
    TVal target;
    TVal this_arg;
    HObject* args;
}

$assert CaptureRef::size <= HObjectBound::size;

struct HObjectFunction {
    CompiledFunction* comp_func;
    EnvRecord*        var_env;
    EnvRecord*        lex_env;
    int               builtin_fn_index;
    // Arrow functions only ([[ThisMode]] lexical): the
    // enclosing activation's `this` from closure creation, reused however the
    // arrow is later invoked. Unused on non-arrows. It sits after
    // builtin_fn_index so HObjectProxy, which overlays this struct, keeps that
    // field at the same offset.
    TVal              captured_this;
    // Arrow functions only: the enclosing function's new.target from
    // closure-creation time, which outlives the enclosing frame. Null on
    // non-arrows and when the enclosing invocation had no new.target.
    HObject*          captured_new_target;
    // Bound functions and compiled closures have disjoint payloads. A single
    // capture fits in the bound-call storage without growing the object.
    union {
        HObjectBound bound;
        CaptureRef inline_capture;
    }
    // Resolved slots for the compiled function's captured names. Appended so
    // the proxy/function overlay offsets above remain unchanged.
    // GC traces owners and snapshot values independently of environment chains.
    CaptureRef*       capture_refs;
    heap::Realm*      realm;
}

// Host object (ObjClass.HOST): an instance of a class registered at runtime
// by an embedder or add-on. `class_id` indexes Heap.host_classes, which holds
// the finalizer and GC-mark callbacks; `payload` is opaque to the engine and
// owned by the registering module.
//
// Two words, so this adds nothing to HObjectExtra::size -- the union is already
// sized by larger members such as HObjectBufferView. Host classes therefore
// cost nothing in per-object memory for programs that never use one.
struct HObjectHost {
    void*             payload;
    uint              class_id;
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
// HObjects with native reaction fields, and all promise state lives in this
// union slot rather than the property table, where user code could reach it.
struct HObjectPromise {
    uint      state;             // one of PROMISE_PENDING/FULFILLED/REJECTED
    TVal      result;            // resolved value or rejection reason
    HObject*  reactions_head;    // linked list of reaction records
    HObject*  reactions_tail;    // tail pointer (O(1) append)
    // [[PromiseIsHandled]] (ECMA-262 Promise objects). Set the moment any
    // reaction is attached, including the handler-less pass-through ones that
    // `await` and promise adoption install, and never cleared: once something
    // is watching a promise, its rejection is somebody's to report.
    //
    // A rejection with this still false at the end of the microtask drain is
    // an unhandled rejection; see Heap.track_rejection.
    bool      is_handled;
    // Checkpoint reporting never changes [[PromiseIsHandled]].
    bool      rejection_reported;
    // True while this promise sits in Heap.unhandled_rejections, so a promise
    // rejected, un-tracked, and rejected again cannot be listed twice.
    bool      in_reject_list;
}

// Internal records are never exposed to JS. Slot 2 holds either a Promise or
// a custom capability wrapper; the queue can use it without allocating again.
struct HObjectReaction {
    TVal[3] values;
    HObject* next;
}

struct HObjectAsyncContinuation {
    heap::GeneratorState* state;
    HObject* next;
    bool rejected;
}

// Array/Map/Set iterator state.
// Active when flags.obj_class is ARRAY_ITERATOR, MAP_ITERATOR, or SET_ITERATOR.
struct HObjectIterator {
    HObject*          target;   /// The iterated object (array, Map, or Set).
    uint              index;    /// Current iteration position.
    uint              kind;     /// 0=values, 1=keys, 2=entries.
}

// String iterator (ECMA-262 %StringIteratorPrototype%): the string being
// iterated and the current code-unit position. A payload of its own rather than
// overlapping extra.prim with extra.iter.index, whose bytes collide once a TVal
// is 16 bytes under NONANBOX.
struct HObjectStringIterator {
    hstring::StringRef string;
    uint     index;        /// Current position in code units.
}

// RegExpStringIterator: lazy iteration over regexp matches.
// Active when flags.obj_class is REGEXP_STRING_ITERATOR.
// Owns the iterated string and traces the regexp.
struct HObjectRegExpStringIterator {
    hstring::StringRef string;
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

// Iterator Helper (ECMA-262 Iterator Helper objects), shared by the map, filter,
// take, drop, and flatMap results. Active when obj_class is ITERATOR_HELPER.
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
    // windows only: the persistent ring buffer (values live at
    // [(head + i) % windowSize] for i < count), plus the "allow-partial"
    // mode bit for the undersized argument.
    HObject* buffer;
    uint     buffer_head;
    uint     window_mode;
    // Set by a step that yields its closure's last value (the final partial
    // chunk/window): the yield still reports done=false, but the helper is
    // finished, so the next call must not step the underlying iterator again.
    bool     final_yield;
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

// The lookup index MAP, SET, WEAKMAP, and WEAKSET keep over their dense part,
// null until the collection is large enough to want one. These four keep their
// entries in array_part, so this is the only payload they need; every other
// class used to pay for the pointer. It is not the same thing as prop_hash,
// which indexes named properties and can be live on a Map at the same time.
struct HObjectCollHash {
    CollHashInfo* info;
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
// A resizable buffer sets `resizable` and caps growth at
// `max_byte_length`. Fixed buffers leave both unset, so the fixed-buffer fast
// path never reads the cap.
//
// An immutable buffer (transferToImmutable) sets `immutable`. Its data block
// never changes after construction: every write through a view is rejected,
// and it can be neither detached nor resized. `immutable` and `resizable` are
// mutually exclusive.
struct HObjectArrayBuffer {
    char*    data;          // heap.alloc_func'd, zeroed; null when detached or zero-length
    uint     byte_length;   // byte length; set to 0xFFFFFFFF on detach
    HObject* views_head;    // intrusive list of views (via HObjectBufferView.next_view)
    uint     max_byte_length; // cap for resizable buffers; unused (0) when !resizable
    bool     resizable;     // true iff constructed with {maxByteLength}
    bool     is_shared;     // true iff this is a SharedArrayBuffer (never detachable)
    bool     immutable;     // true iff produced by transferToImmutable
}

// TypedArray or DataView, active for INT8ARRAY through FLOAT64ARRAY and DATAVIEW.
//
// `length_tracking` is set when the view was created over a resizable
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

// ARGUMENTS exotic extra fields. `nargs` aliases array_length at offset 0.
// `mapped_bits` is the live [[ParameterMap]] for a sloppy mapped arguments
// object (ECMA-262 CreateMappedArgumentsObject): bit i set means index i still
// aliases formal parameter i. Deletion, an accessor define, and a writable:false
// define each clear the bit. Only the low 64 indices can map; a formal
// parameter list longer than that would leave the extra indices unmapped.
struct HObjectArguments {
    uint  nargs;
    uint  pad;
    ulong mapped_bits;
}

// The subtype fields, discriminated by flags.obj_class in the common header.
union HObjectExtra {
    HObjectFunction              func;
    HObjectPrimitive             prim;
    HObjectError                 err;
    HObjectRegExp                regexp;
    HObjectGenerator             gen;
    HObjectPromise               promise;
    HObjectReaction              reaction;
    HObjectAsyncContinuation     async_cont;
    HObjectIterator              iter;
    HObjectStringIterator        str_iter;
    HObjectRegExpStringIterator  regexp_iter;
    HObjectWrapForValidIterator  wrap_iter;
    HObjectIteratorHelper        iter_helper;
    HObjectGetterSetter          gs;
    HObjectCollHash              coll;
    HObjectHost                  host;
    HObjectProxy                 proxy;
    HObjectArrayBuffer           ab;
    HObjectBufferView            view;
    HObjectTemporal              temporal;
    uint                         array_length;  // For ARRAY objects: dense-element count.
    HObjectArguments             args;          // For ARGUMENTS objects (nargs aliases array_length).
}

// Temporal objects (Temporal.PlainDate, .PlainTime, .Instant, etc.). One
// shared variant for every Temporal class; `obj_class` discriminates which
// fields are live.
//
// Slot assignments (obj_class -> long_a..long_g, int_h..int_j):
//   PLAIN_DATE      long_a..long_c = y/m/d
//   PLAIN_TIME      long_a..long_f = h/mi/s/ms/us/ns
//   PLAIN_DATETIME  long_a..long_c = y/m/d; long_d..long_i = h/mi/s/ms/us/ns
//   DURATION        long_a..long_g = years..seconds; int_h..int_j = ms/us/ns
//   PLAIN_YEARMONTH long_a..long_b = y/m
//   PLAIN_MONTHDAY  long_a..long_b = m/d
//   INSTANT         big_ns = ns since epoch (BigInt limb vector)
//
// long_a..long_g are 64-bit because the Duration constructor accepts values up
// to 2^32 - 1 in each of the seven calendar/time units (years through
// seconds), which exceed int32. Plain types only need int32 range but share
// the slots. ms/us/ns are 0..999 and stay int32.
//
// PlainTime, PlainDate, PlainDateTime, PlainYearMonth, PlainMonthDay,
// Duration, Instant, ZonedDateTime, Calendar, and TimeZone all share this
// variant.
//
// HObjectExtra is sized by its largest member and alloc_size_for_class
// charges that to every FUNCTION/REGEXP/PROMISE object. Widening the seven
// leading slots from int to long pushed HObjectTemporal from 64 to 92 bytes,
// making it the union's max; every FUNCTION/REGEXP/PROMISE object now pays
// +20 bytes. The widening is required for Temporal.Duration, whose seven
// calendar/time-unit fields accept values up to 2^32 - 1 per spec.
//
// Baseline (nanbox, default build, macOS arm64, 2026-08-25):
//   HObjectTemporal::size         = 92  (current max; +20 B over previous
//                                        HObjectFunction-led layout)
//   HObjectIteratorHelper::size   = 64
//   HObjectPromise::size          = 40
//   HObjectBufferView::size       = 32
//   INLINE_EXTRA                  = 32
//   OBJ_SIZE_FUNC                 = 204
// All ten Duration slots are widened to `long` so values up to 2^32 - 1 fit
// without overflow. ms/us/ns are usually small (0..999) but can hold the
// whole diff when `largestUnit` is finer than seconds. PlainTime / PlainDate
// fields continue to use `long` too (see slot assignments below).
struct HObjectTemporal {
    HBigInt*        big_ns;
    long            long_a;
    long            long_b;
    long            long_c;
    long            long_d;
    long            long_e;
    long            long_f;
    long            long_g;
    long            long_h;
    long            long_i;
    long            long_j;
    // TimeZone uses identifier; the classes with a calendar use calendar.
    union {
        temporal::CalendarId calendar;
        StringRef identifier;
    }
    HObject*        timezone;
}

// HObjectExtra is charged to every FUNCTION/REGEXP/PROMISE object, so its size
// is a memory budget as well as a layout fact. Which variant sets it depends on
// the representation, because a TVal is 8 bytes when NaN-boxed and 16 when
// tagged: the Temporal variant is on top of the NaN-boxed build, and the
// iterator helper above it in the tagged build. A third variant growing past
// the current max is a size regression to re-baseline here, not a compile
// error, so each representation states its own bound.
//
// Sizes with 8-byte TVals: extra 104, temporal 104, helper 88, function 80,
// promise 40, getter/setter 16, arraybuffer 32, bufferview 32.
// With 16-byte TVals: extra 112, helper 112, temporal 104, function 104,
// promise 48, getter/setter 32, arraybuffer 32, bufferview 32.
fn void assert_union_max() @feat(!NONANBOX) {
    $assert HObjectExtra::size == HObjectTemporal::size;
}

fn void assert_union_max() @feat(NONANBOX) {
    $assert HObjectExtra::size == HObjectIteratorHelper::size;
}

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

// The prefix every HObject variant starts with, which lets the GC walk the
// allocation registries and reach shapes and properties at fixed offsets. Its first
// fields are binary-compatible with HeapHeader, so a raw cast at offset 0
// works.
//
// HObject flattens these fields into its own layout with
// `inline HObjectBase base`. Classes that need subtype fields add an
// HObjectExtra after this prefix; see alloc_size_for_class.
struct HObjectBase {
    ObjFlags      flags;
    union {
        uint      refcount;  // unused: only strings are counted
        GcBits    gc;
    }
    // Mark work links live outside the allocation and sweep lists.
    HObject*      prototype;
    uint          shape_id;
    uint          prop_capacity;
    uint          prop_count;
    uint          array_size;
    uint          array_used;
    void*         prop_alloc;
    PropHashInfo* prop_hash;
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
    HObjectExtra      extra;       // at HObjectBase::size; ARRAY uses length and an inline-pool tag
}

// ============================================================================
// HObject: per-class allocation sizes and trailing-data accessors
// ============================================================================

// Pool size classes, derived from the struct sizes plus the inline prop space.
//
// A class pays only for the union members it actually uses, so ARRAY and
// ARGUMENTS are much smaller than the FUNCTION-led classes, which must cover
// HObjectExtra in full. The trailing inline props must stay 8-aligned, which
// rounds each extra slot up to a multiple of PropValue::alignment.
// Logical allocation size for a class whose payload is `$Payload`: the common
// header, the payload, and the inline property slots. A class reports its own
// size even when it shares a pool with larger classes, because the fallback
// allocation used when a pool is exhausted is sized from it.
macro usz obj_size_for($Payload) => HObjectBase::size + $Payload::size + INLINE_EXTRA;

const usz INLINE_EXTRA = INLINE_PROPS * PropValue::size;
const usz ARRAY_EXTRA    = 8;                                            // ARRAY: length and inline-literal pool capacity
const usz OBJ_SIZE_PLAIN = HObjectBase::size + INLINE_EXTRA;             // classes with no payload of their own
const usz OBJ_SIZE_COMPACT = HObjectBase::size + COMPACT_INLINE_PROPS * PropValue::size;
const usz OBJ_SIZE_ARRAY = HObjectBase::size + ARRAY_EXTRA;
// A literal of up to this many elements keeps them in its header block, so it
// costs one allocation, one free and one cache line fetch less than an array
// with a separate element store. Each capacity has its own exact-size pool.
const uint ARRAY_INLINE_MAX_CAPACITY = 16;

macro usz inline_array_alloc_size(uint capacity) => OBJ_SIZE_ARRAY + (usz)capacity * TVal::size;
const usz OBJ_SIZE_ARGS  = obj_size_for(HObjectArguments);               // nargs aliases array_length, plus mapped_bits
const usz OBJ_SIZE_GS    = HObjectBase::size + HObjectGetterSetter::size; // GETTER_SETTER, which has no inline props

const usz OBJ_SIZE_ERROR       = obj_size_for(HObjectError);       // captured_stack
const usz OBJ_SIZE_PRIM        = obj_size_for(HObjectPrimitive);   // BOOLEAN, NUMBER, STRING, SYMBOL, DATE
const usz OBJ_SIZE_GENERATOR   = obj_size_for(HObjectGenerator);
const usz OBJ_SIZE_ARRAYBUFFER = obj_size_for(HObjectArrayBuffer);
const usz OBJ_SIZE_VIEW        = obj_size_for(HObjectBufferView);  // DATAVIEW and the typed arrays
const usz OBJ_SIZE_HOST        = obj_size_for(HObjectHost);
const usz OBJ_SIZE_WRAP_ITER   = obj_size_for(HObjectWrapForValidIterator);
const usz OBJ_SIZE_ITER        = obj_size_for(HObjectIterator);    // ARRAY_ITERATOR, MAP_ITERATOR, SET_ITERATOR
const usz OBJ_SIZE_STR_ITER    = obj_size_for(HObjectStringIterator);
const usz OBJ_SIZE_COLL        = obj_size_for(HObjectCollHash);    // MAP, SET, WEAKMAP, WEAKSET
const usz OBJ_SIZE_REGEXP      = obj_size_for(HObjectRegExp);
const usz OBJ_SIZE_REGEXP_ITER = obj_size_for(HObjectRegExpStringIterator);
const usz OBJ_SIZE_PROMISE     = obj_size_for(HObjectPromise);

// A function payload is 80 bytes and a proxy overlays its first 32, so both fit
// a class of their own instead of the full union. HObjectProxy keeps
// builtin_fn_index at the offset HObjectFunction uses for it, which is what lets
// the two share an allocation size and a pool.
const usz OBJ_SIZE_FUNCTION = obj_size_for(HObjectFunction);

// Two pools take everything else. The small one serves every class whose
// payload fits the promise payload; the big one serves the two payloads that do
// not, and which of those leads depends on the value representation.
const usz OBJ_SIZE_ITER_HELPER = obj_size_for(HObjectIteratorHelper);
const usz OBJ_SIZE_TEMPORAL    = obj_size_for(HObjectTemporal);
// Leave one slot of headroom in the small pool for changes to common subtype
// payloads. The class limit below checks every class routed to this pool.
const usz OBJ_SIZE_SMALL = OBJ_SIZE_PROMISE + 8;
const usz OBJ_SIZE_BIG   = OBJ_SIZE_TEMPORAL > OBJ_SIZE_ITER_HELPER
    ? OBJ_SIZE_TEMPORAL : OBJ_SIZE_ITER_HELPER;

$assert obj_size_for(HObjectReaction) <= OBJ_SIZE_SMALL : "reaction record exceeds its pool";

$assert ARRAY_EXTRA >= uint::size : "array_length does not fit in the ARRAY extra slot";
$assert OBJ_SIZE_ARRAY % PropValue::alignment == 0 : "an ARRAY header must preserve value alignment";
$assert ARRAY_EXTRA >= 2 * uint::size : "ARRAY inline-capacity metadata needs the reserved extra word";
$assert OBJ_SIZE_ARRAY % PropValue::alignment == 0 : "inline array elements must preserve value alignment";
$assert OBJ_SIZE_ARGS % PropValue::alignment == 0 : "an ARGUMENTS' inline props would be misaligned";
// Every class routed to the small pool must fit its block. The promise payload
// is the largest of them in both representations.
$assert OBJ_SIZE_REGEXP <= OBJ_SIZE_SMALL && OBJ_SIZE_REGEXP_ITER <= OBJ_SIZE_SMALL
    && OBJ_SIZE_ERROR <= OBJ_SIZE_SMALL && OBJ_SIZE_PRIM <= OBJ_SIZE_SMALL
    && OBJ_SIZE_GENERATOR <= OBJ_SIZE_SMALL && OBJ_SIZE_ARRAYBUFFER <= OBJ_SIZE_SMALL
    && OBJ_SIZE_VIEW <= OBJ_SIZE_SMALL && OBJ_SIZE_HOST <= OBJ_SIZE_SMALL
    && OBJ_SIZE_WRAP_ITER <= OBJ_SIZE_SMALL && OBJ_SIZE_ITER <= OBJ_SIZE_SMALL
    && OBJ_SIZE_STR_ITER <= OBJ_SIZE_SMALL && OBJ_SIZE_COLL <= OBJ_SIZE_SMALL
    : "the small pool block is smaller than one of the layouts it serves";
$assert OBJ_SIZE_TEMPORAL <= OBJ_SIZE_BIG && OBJ_SIZE_ITER_HELPER <= OBJ_SIZE_BIG
    : "the big pool block is smaller than one of the layouts it serves";

// Allocation size includes inline named slots except for ARRAY and
// GETTER_SETTER. Arrays allocate named storage on its first insertion.
fn usz alloc_size_for_class(ObjClass cls) @inline {
    switch (cls) {
        // Classes whose state lives entirely in the common header: a dense part
        // in array_part, or nothing at all beyond the named property table.
        case ObjClass.OBJECT:
        case ObjClass.JSON:
        case ObjClass.REFLECT:
        case ObjClass.WEAKREF:
        case ObjClass.FINALIZATION_REGISTRY:
            return OBJ_SIZE_PLAIN;
        case ObjClass.MAP:
        case ObjClass.SET:
        case ObjClass.WEAKMAP:
        case ObjClass.WEAKSET:
            return OBJ_SIZE_COLL;
        case ObjClass.ARRAY:
            return OBJ_SIZE_ARRAY;
        case ObjClass.ARGUMENTS:
            return OBJ_SIZE_ARGS;
        case ObjClass.GETTER_SETTER:
            return OBJ_SIZE_GS;
        case ObjClass.FUNCTION:
        case ObjClass.PROXY:
            return OBJ_SIZE_FUNCTION;
        case ObjClass.ERROR:
            return OBJ_SIZE_ERROR;
        case ObjClass.BOOLEAN:
        case ObjClass.BIGINT:
        case ObjClass.NUMBER:
        case ObjClass.STRING:
        case ObjClass.SYMBOL:
        case ObjClass.DATE:
            return OBJ_SIZE_PRIM;
        case ObjClass.STRING_ITERATOR:
            return OBJ_SIZE_STR_ITER;
        case ObjClass.GENERATOR:
            return OBJ_SIZE_GENERATOR;
        case ObjClass.ARRAYBUFFER:
            return OBJ_SIZE_ARRAYBUFFER;
        case ObjClass.DATAVIEW:
        case ObjClass.INT8ARRAY:
        case ObjClass.UINT8ARRAY:
        case ObjClass.UINT8CLAMPEDARRAY:
        case ObjClass.INT16ARRAY:
        case ObjClass.UINT16ARRAY:
        case ObjClass.INT32ARRAY:
        case ObjClass.UINT32ARRAY:
        case ObjClass.FLOAT16ARRAY:
        case ObjClass.FLOAT32ARRAY:
        case ObjClass.FLOAT64ARRAY:
        case ObjClass.BIGINT64ARRAY:
        case ObjClass.BIGUINT64ARRAY:
            return OBJ_SIZE_VIEW;
        case ObjClass.HOST:
            return OBJ_SIZE_HOST;
        case ObjClass.WRAP_FOR_VALID_ITERATOR:
            return OBJ_SIZE_WRAP_ITER;
        case ObjClass.ARRAY_ITERATOR:
        case ObjClass.MAP_ITERATOR:
        case ObjClass.SET_ITERATOR:
            return OBJ_SIZE_ITER;
        case ObjClass.REGEXP:
            return OBJ_SIZE_REGEXP;
        case ObjClass.REGEXP_STRING_ITERATOR:
            return OBJ_SIZE_REGEXP_ITER;
        case ObjClass.PROMISE:
            return OBJ_SIZE_PROMISE;
        case ObjClass.PROMISE_REACTION:
            return obj_size_for(HObjectReaction);
        case ObjClass.ASYNC_CONTINUATION:
            return obj_size_for(HObjectAsyncContinuation);
        default:
            return OBJ_SIZE_BIG;
    }
}

// The HObjectExtra union, which sits at HObjectBase::size from the object.
// Only classes allocated with extra-data space have one; see
// alloc_size_for_class.
fn HObjectExtra* HObject.extra_ptr(&self) @inline {
    return (HObjectExtra*)((char*)self + HObjectBase::size);
}

// extra.array_length, the first 4 bytes of the union. ARRAY objects keep their
// dense-element count here; ARGUMENTS objects stash the actual argument count.
fn uint* HObject.array_len_ptr(&self) @inline {
    return &self.extra.array_length;
}

// The second word of ARRAY's extra slot records the inline literal allocation
// capacity. It remains set after migration so teardown can return the header
// to the size class that originally allocated it.
fn uint* HObject.array_inline_capacity_ptr(&self) @inline {
    return (uint*)((char*)self.extra_ptr() + uint::size);
}

fn uint HObject.array_inline_capacity(&self) @inline {
    if (self.flags.obj_class != ObjClass.ARRAY) return 0;
    return self.array_inline_capacity_ptr()[0];
}

// extra.args.mapped_bits, the live [[ParameterMap]] of a mapped ARGUMENTS
// object (see HObjectArguments).
fn ulong* HObject.mapped_bits_ptr(&self) @inline {
    return &self.extra.args.mapped_bits;
}

// extra.coll.info, the lookup index MAP, SET, WEAKMAP, and WEAKSET keep over
// their dense part.
fn CollHashInfo** HObject.coll_hash_ptr(&self) @inline {
    return &self.extra.coll.info;
}

// True for the four classes that keep a lookup index in extra.coll. Reading it
// on any other class would read whatever its payload holds instead.
fn bool HObject.has_coll_hash(&self) @inline {
    return self.flags.obj_class == ObjClass.MAP || self.flags.obj_class == ObjClass.SET
        || self.flags.obj_class == ObjClass.WEAKMAP || self.flags.obj_class == ObjClass.WEAKSET;
}

// ============================================================================
// Pool allocation helpers
// ============================================================================

// The pool an object class allocates from. Each pool's block is the largest
// layout it serves. Dense arrays have a dedicated pool; arguments and
// collections share the ARGUMENTS block size.
fn void* pool_for_class(void* heap_ptr, ObjClass cls) @inline {
    heap::Heap* h = (heap::Heap*)heap_ptr;
    switch (cls) {
        case ObjClass.OBJECT:
        case ObjClass.JSON:
        case ObjClass.REFLECT:
        case ObjClass.WEAKREF:
        case ObjClass.FINALIZATION_REGISTRY:
            return &h.obj_pool_plain;
        case ObjClass.MAP:
        case ObjClass.SET:
        case ObjClass.WEAKMAP:
        case ObjClass.WEAKSET:
        case ObjClass.ARGUMENTS:
            return &h.obj_pool_array;
        case ObjClass.ARRAY:
            return &h.obj_pool_dense_array;
        case ObjClass.GETTER_SETTER:
            return &h.obj_pool_gs;
        case ObjClass.FUNCTION:
        case ObjClass.PROXY:
            return &h.obj_pool_func;
        case ObjClass.ERROR:
        case ObjClass.BOOLEAN:
        case ObjClass.BIGINT:
        case ObjClass.NUMBER:
        case ObjClass.STRING:
        case ObjClass.SYMBOL:
        case ObjClass.DATE:
        case ObjClass.STRING_ITERATOR:
        case ObjClass.GENERATOR:
        case ObjClass.ARRAYBUFFER:
        case ObjClass.DATAVIEW:
        case ObjClass.INT8ARRAY:
        case ObjClass.UINT8ARRAY:
        case ObjClass.UINT8CLAMPEDARRAY:
        case ObjClass.INT16ARRAY:
        case ObjClass.UINT16ARRAY:
        case ObjClass.INT32ARRAY:
        case ObjClass.UINT32ARRAY:
        case ObjClass.FLOAT16ARRAY:
        case ObjClass.FLOAT32ARRAY:
        case ObjClass.FLOAT64ARRAY:
        case ObjClass.BIGINT64ARRAY:
        case ObjClass.BIGUINT64ARRAY:
        case ObjClass.HOST:
        case ObjClass.WRAP_FOR_VALID_ITERATOR:
        case ObjClass.ARRAY_ITERATOR:
        case ObjClass.MAP_ITERATOR:
        case ObjClass.SET_ITERATOR:
        case ObjClass.REGEXP:
        case ObjClass.REGEXP_STRING_ITERATOR:
        case ObjClass.PROMISE:
        case ObjClass.PROMISE_REACTION:
        case ObjClass.ASYNC_CONTINUATION:
            return &h.obj_pool_small;
        default:
            return &h.obj_pool_big;
    }
}

// ============================================================================
// HObject: property allocation helpers
// ============================================================================

// Size of the external block in prop_alloc. Embedded short array storage is
// part of the object allocation and is not included here.
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
    usz inline_bytes = self.flags.obj_class == ObjClass.ARRAY ? 0 : INLINE_EXTRA;
    usz base_size = alloc_size_for_class(self.flags.obj_class) - inline_bytes;
    return (PropValue*)((char*)self + base_size);
}

// The property values array: inline storage while prop_alloc is null, and the
// heap-allocated block once it is not.
fn PropValue* HObject.prop_values(&self) @inline {
    if (self.prop_alloc != null) return (PropValue*)self.prop_alloc;
    return self.inline_props_ptr();
}

// The dense array part, which follows the property values inside prop_alloc.
// A short literal uses the trailing bytes of its header until growth or
// a named-property insertion moves both parts into prop_alloc.
fn PropValue* HObject.array_part(&self) @inline {
    if (self.array_size == 0) return null;
    if (self.prop_alloc == null) {
        if (self.array_inline_capacity() > 0) return (PropValue*)((char*)self + OBJ_SIZE_ARRAY);
        return null;
    }
    return (PropValue*)((char*)self.prop_alloc + (usz)self.prop_capacity * PropValue::size);
}

// ============================================================================
// HObject: HeapHeader-compatible helpers
// ============================================================================

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

fn ObjClass HObject.get_class(&self)    { return self.flags.obj_class; }

fn bool HObject.is_extensible(&self)    { return self.flags.extensible; }

fn bool HObject.is_callable(&self)      @inline { return self.flags.callable; }

fn bool HObject.is_constructable(&self) @inline { return self.flags.constructable; }

fn bool HObject.is_bound(&self)         @inline { return self.flags.is_bound; }

// Returns true when the object is a class constructor. A class is
// constructable but not callable in the ECMA-262 IsCallable sense: calling one
// without `new` is a TypeError, so wherever the spec asks for a callable --
// GetMethod, a Proxy trap, a callback argument -- a class does not qualify,
// even though `typeof` still reports "function".
fn bool HObject.is_class_ctor(&self) {
    if (self.flags.obj_class != ObjClass.FUNCTION) return false;
    HObjectFunction* fn_extra = (HObjectFunction*)self.extra_ptr();
    if (fn_extra.comp_func == null) return false;
    return fn_extra.comp_func.is_class_ctor();
}

fn CallableKind HObject.callable_kind(&self) @inline {
    if (self.flags.is_bound) return CallableKind.BOUND_FN;
    if ((*self.extra_ptr()).func.builtin_fn_index >= 0) return CallableKind.BUILTIN_FN;
    if ((*self.extra_ptr()).func.comp_func != null) return CallableKind.COMPILED_FN;
    return CallableKind.OTHER;
}

// The flat array part holds TVals with no PropFlags of their own, so dense
// elements move into the named property table first and the array part is then
// abandoned with array_size set to 0.
fn void HObject.seal(&self, heap::Heap* h) {
    self.flags.extensible = false;

    // Move dense elements into the named table so each can carry its own flags.
    if (self.array_part() != null && self.array_used > 0) {
        char[12] digit_buf;
        for (uint i = 0; i < self.array_size; i++) {
            TVal v = self.array_part()[i].get();
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
                            self.array_part()[i].release_ref(h);
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
            self.layout_moved(h);
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
    // table, so the loop above misses it. ECMA-262 Array [[DefineOwnProperty]]
    // requires it to become non-writable here, so that Set(O, "length", _, true)
    // throws.
    if (self.flags.exotic_array) {
        self.flags.array_len_writable = false;
    }
    // A frozen ARGUMENTS object's data properties all become non-writable, which
    // drops each such index from the [[ParameterMap]] (ECMA-262 arguments
    // [[DefineOwnProperty]]).
    if (self.get_class() == ObjClass.ARGUMENTS) {
        *self.mapped_bits_ptr() = 0;
    }
}

// ============================================================================
// Internal: pointer hashing
// ============================================================================

// Hash a key pointer into a hash-table index. Property keys are interned
// HStrings, so pointer identity is string equality. Keys are at least 48 bytes
// apart and the allocator hands them out in address order. Dropping the
// alignment bits keeps keys created together in neighbouring slots, so a build
// or scan walks the table sequentially. Folding the high bits down spreads
// separate pages across the table.
fn uint hash_key(void* key) @inline {
    uint h = (uint)((usz)key >> 4);
    return h ^ (h >> 11);
}

// ============================================================================
// HObject: property index lookup
// ============================================================================

// One slot of a property hash table: a key pointer and its index in prop_values.
struct HashEntry {
    void* key;
    uint  index;
}

fn uint prop_hash_mask_for(uint prop_count) @inline {
    uint min_slots = (uint)(((ulong)prop_count * 10 + 6) / 7);
    if (min_slots <= 2) return 1;
    return (1u << (32 - (min_slots - 1).clz())) - 1;
}

// Store `key -> index` in an open-addressing table, repointing the entry when
// the key is already present. Callers keep the load factor at or below 70%, so
// a free slot always exists.
fn void hash_table_insert(HashEntry* entries, uint mask, void* key, uint index) @inline {
    uint slot = hash_key(key) & mask;
    while (entries[slot].key != null && entries[slot].key != key) slot = (slot + 1) & mask;
    entries[slot].key = key;
    entries[slot].index = index;
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
    h.account_auxiliary_allocation(new_bytes);
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
            void* k = sp[j].key.borrow();
            if (k != null) hash_table_insert(entries, mask, k, sh.offset + j);
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

// Move a current per-object table, one that holds every key but the newest,
// into a table of `new_mask + 1` slots. The old table already names each key
// and index, so this skips the shape-chain walk ensure_prop_hash would do, a
// pointer chase through one shape per property. False when the allocation fails.
fn bool HObject.resize_prop_hash(&self, uint new_mask, heap::Heap* h) {
    usz new_bytes = (usz)(new_mask + 1) * HashEntry::size;
    HashEntry* entries = (HashEntry*)h.alloc_func(h.heap_udata, new_bytes);
    if (entries == null) return false;
    h.account_auxiliary_allocation(new_bytes);
    mem::clear(entries, (sz)new_bytes);

    HashEntry* old_entries = (HashEntry*)self.prop_hash.table;
    for (uint i = 0; i <= self.prop_hash.mask; i++) {
        if (old_entries[i].key != null) hash_table_insert(entries, new_mask, old_entries[i].key, old_entries[i].index);
    }
    h.free_func(h.heap_udata, old_entries);
    self.prop_hash.table = entries;
    self.prop_hash.mask = new_mask;
    return true;
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
            return sh.props()[idx - sh.offset].key.borrow();
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
    $if $feat(OP_PROFILE):
        opprof_shape_site[0]++;
        opprof_private_class[(uint)self.get_class().ordinal & 63]++;
    $endif
    hobject::Shape* ns = shape_flatten(self.get_shape(h), 0, h);
    if (ns == null) return;

    // The shape being replaced is dead once the swap lands. Reclaim it first so
    // a long-running privatise loop reuses one slot instead of leaking one per
    // call; free_shape_slot ignores shared transition-table shapes.
    uint old_slot = (uint)self.shape_id;
    uint slot = h.alloc_shape_slot();
    if (slot != heap::SHAPE_NONE) {
        h.store_new_shape(slot, ns);
        self.shape_id = slot;
        self.layout_moved(h);
        if (old_slot != slot) h.free_shape_slot(old_slot);
    } else {
        shape_free(ns, h);
    }
}

const uint RETRANSITION_MAX_PROPS = 16;

// Re-derive a shared shape with one property's flags changed by replaying the
// object's keys through the transition table. Objects that make the same
// change, such as every scope initializing a captured const, then share one
// shape instead of each minting a private one. Small shared chains only.
fn bool HObject.retransition_flags(&self, uint idx, PropFlags new_flags, heap::Heap* h) {
    uint count = self.prop_count;
    if (count > RETRANSITION_MAX_PROPS || self.flags.exotic_array) return false;
    void*[RETRANSITION_MAX_PROPS] keys;
    PropFlags[RETRANSITION_MAX_PROPS] flags;
    uint seen = 0;
    for (Shape* sh = self.get_shape(h); sh != null; sh = sh.parent_shape) {
        if (sh.dict || (sh.parent == PRIVATE_SHAPE_PARENT && sh.own_count != 0)) return false;
        if (sh.offset + sh.own_count > count) return false;
        for (uint i = 0; i < sh.own_count; i++) {
            keys[sh.offset + i] = (void*)sh.props()[i].key;
            flags[sh.offset + i] = sh.props()[i].flags;
        }
        seen += sh.own_count;
    }
    if (seen != count) return false;
    flags[idx] = new_flags;
    uint id = 0;
    for (uint i = 0; i < count; i++) {
        id = h.transition_shape_new_flags(id, keys[i], flags[i]);
        if (id == heap::SHAPE_NONE || id == 0) return false;
        Shape* ns = h.shapes[id];
        if (ns.dict || ns.parent == PRIVATE_SHAPE_PARENT) return false;
    }
    if (self.prop_hash != null) self.drop_prop_hash(h);
    self.shape_id = id;
    self.layout_moved(h);
    return true;
}

// Replay small immutable chains through the transition table so identical
// descriptor edits share a shape. Other edits use a private shape.
fn void HObject.set_prop_flags(&self, uint idx, PropFlags new_flags, heap::Heap* h) {
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
    if (self.retransition_flags(idx, new_flags, h)) return;
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
            if (self.prop_hash == null || self.prop_hash.count != self.prop_count) self.ensure_prop_hash(h);
            if (self.prop_hash != null) {
                return hash_table_probe(self.prop_hash.table, self.prop_hash.mask, key);
            }
        }
    }

    while (sh != null) {
        hobject::ShapeProperty* sp = sh.props();
        for (uint i = 0; i < sh.own_count; i++) {
            if (sp[i].key.borrow() == key) return (int)(sh.offset + i);
        }
        sh = sh.parent_shape;
    }
    return -1;
}

// Look up `key` in a hash table, returning the stored index or -1. Open
// addressing with linear probing.
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
    return self.prop_values()[idx].get();
}

// Look up an own property, distinguishing data properties from accessors.
// This stops at the object itself, consulting neither the prototype chain nor
// proxy traps, which is what PrivateFieldGet needs to bypass proxy [[Get]].
// get_prop_or_accessor_proto does the full walk.
fn PropLookupResult HObject.get_prop_or_accessor_own(&self, void* key, bool want_getter, heap::Heap* h) {
    int idx = self.find_prop_idx(key, h);
    if (idx >= 0) {
        if (self.get_prop_flags((uint)idx, h).is_accessor) {
            TVal gs_slot = self.prop_values()[idx].get();
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
            .data_val = self.prop_values()[idx].get(),
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

// ARRAY and ARGUMENTS objects keep integer keys in the dense array part rather
// than the named-property table (the "indexed exotic" objects).
fn bool HObject.is_indexed_exotic(&self) @inline {
    ObjClass cls = self.get_class();
    return cls == ObjClass.ARRAY || cls == ObjClass.ARGUMENTS;
}

// Look up an array-index string key ("0", "1", ...) in the dense array part
// of an ARRAY / ARGUMENTS exotic object. Returns true and stores the value in
// `out` when the slot exists and is not a hole (undefined = hole sentinel).
fn bool HObject.dense_arridx_lookup(&self, void* key, TVal* out) {
    if (key == null) return false;
    if (!self.is_indexed_exotic()) return false;
    if (self.array_part() == null) return false;
    HString* hkey = (HString*)key;
    if (!hkey.is_arridx()) return false;
    uint ai = (uint)hkey.array_index();
    if (!self.dense_idx_present(ai)) return false;
    *out = self.array_part()[ai].get();
    return true;
}

fn bool HObject.has_prop(&self, void* key, heap::Heap* h) {
    if (self.find_prop_idx(key, h) >= 0) return true;
    TVal dense;
    return self.dense_arridx_lookup(key, &dense);
}

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
// True when dense slot `idx` is an own indexed property of `self`.
//
// The dense part marks a hole with `undefined`, so a stored `undefined` is
// indistinguishable from an absent index. Writers keep the dense part free of
// `undefined` (those stores take the named-table path, which records presence
// properly), so within the dense part the sentinel means "absent".
//
// ARGUMENTS objects are the exception and are still wrong here: their slots
// are filled at call time from the actual arguments, `undefined` included, so
// an `undefined` argument reads back as an absent index. Fixing that needs
// per-index presence tracking, since `delete arguments[i]` must still produce
// a real hole; see plans/084 §11.
fn bool HObject.dense_idx_present(&self, uint idx) {
    if (idx >= self.array_size) return false;
    return !self.array_part()[idx].get().is_undefined();
}

// True when nothing on an array's prototype chain can intercept a store to a
// new index: OrdinarySet would find no inherited element and define it on the
// array. The usual chain is answered by Heap.index_clean_proto; any other
// takes the general walk.
macro bool HObject.index_store_unshadowed(&self, heap::Heap* h) {
    HObject* p = self.prototype;
    return p == h.index_clean_proto || p == null || proto_chain_index_free(p);
}

// True when no object on the chain from `proto` (inclusive) could intercept an
// indexed [[Set]]: no Proxy exotic, and no own array-index property, named
// (has_indexed_named_prop, sticky) or dense (array_used > 0, since a prototype
// can itself be an Array with live elements that never reach the named table).
fn bool proto_chain_index_free(HObject* proto) {
    HObject* cur = proto;
    uint depth = 0;
    while (cur != null && depth < MAX_PROTO_DEPTH) {
        if (cur.is_proxy()) return false;
        if (cur.array_part() != null && cur.array_used > 0) return false;
        if (cur.flags.has_indexed_named_prop) return false;
        cur = cur.prototype;
        depth++;
    }
    return true;
}

// Where an object holds its own property at an array index. An ordinary
// object keeps an index in one of two places: the named table, for an accessor
// or a data property with non-default attributes, or the dense part, for a
// plain data element. Where both exist the named entry is the property, and the
// dense slot only mirrors it (put_prop). EXOTIC marks an object that
// synthesizes or intercepts index keys, a Proxy, String wrapper, arguments
// object, typed array or module namespace, whose own path must answer.
// One past the largest array index, 2^32 - 2.
const ulong MAX_ARRAY_INDEX_END = 0xFFFFFFFFUL;

enum IndexHold : char {
    ABSENT,
    DENSE,
    NAMED,
    EXOTIC,
}

struct IndexProp {
    IndexHold hold;
    // The named-table slot, for NAMED.
    uint slot;
    // The element, for DENSE.
    TVal value;
}

fn bool HObject.synthesizes_indices(&self) @inline {
    ObjClass cls = self.get_class();
    return self.is_proxy() || self.flags.exotic_stringobj || self.flags.exotic_arguments
        || self.flags.exotic_module_ns || cls == ObjClass.ARGUMENTS
        || (cls >= ObjClass.INT8ARRAY && cls <= ObjClass.BIGUINT64ARRAY);
}

// The own property of `self` at integer index `idx`. Only an object flagged
// has_indexed_named_prop holds an array index in its named table, so any other
// answers without a string. The flag covers array indices alone, below
// 2^32 - 1; a larger integer key, which an array-like may use up to 2^53, is
// an ordinary name. The probe never interns: the flag is sticky, and an
// unshift across a sparse length would otherwise intern every index it visits.
fn IndexProp HObject.own_index(&self, ulong idx, heap::Heap* h) {
    if (self.synthesizes_indices()) return { .hold = EXOTIC };
    if (self.flags.has_indexed_named_prop || idx >= MAX_ARRAY_INDEX_END) {
        HString* key = h.find_int_hstring((long)idx);
        int slot = key == null ? -1 : self.find_prop_idx(key, h);
        if (slot >= 0) return { .hold = NAMED, .slot = (uint)slot };
    }
    if (try value = self.get_array_idx_wide(idx)) return { .hold = DENSE, .value = value };
    return { .hold = ABSENT };
}

// The first object on the chain from `self` with an own property at `idx`, or
// null when none has one; `found` describes the property. The walk stops at an
// EXOTIC object, since only that object's own path knows whether it holds the
// index. Array.prototype and Object.prototype are skipped together while
// Heap.index_clean_proto vouches that neither has held an array index.
fn HObject* HObject.find_index_holder(&self, ulong idx, heap::Heap* h, IndexProp* found) {
    HObject* clean = idx < MAX_ARRAY_INDEX_END ? h.index_clean_proto : null;
    HObject* cur = self;
    for (uint depth = 0; cur != null && cur != clean && depth < MAX_PROTO_DEPTH; depth++) {
        IndexProp own = cur.own_index(idx, h);
        if (own.hold != ABSENT) {
            *found = own;
            return cur;
        }
        cur = cur.prototype;
    }
    *found = { .hold = ABSENT };
    return null;
}

// Remove the own property at array index `idx`, which own_index found as
// NAMED or DENSE. A dense element becomes a hole; a named one leaves the table
// through delete_prop, which also clears any dense mirror.
fn void HObject.delete_own_index(&self, ulong idx, IndexProp* own, heap::Heap* h) {
    if (own.hold == NAMED) {
        HString* key = h.int_to_hstring((long)idx);
        if (key != null) self.delete_prop(key, h);
    } else if (own.hold == DENSE) {
        TVal hole;
        hole.set_undefined();
        self.set_array_idx((uint)idx, hole, h);
    }
}

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
        TVal old_value = pv.get();
        if (types::either_heap_allocated(&val, &old_value)) {
            val.incref_if_heap();
            if (pv.get().is_heap_allocated()) {
                pv.release_ref(h);
            }
        }
        h.store_slot(self, pv, val);
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
                // A dense `undefined` reads back as a hole, so the named entry
                // written above is the only record of this index. Clear the
                // stale dense value instead of mirroring the store: reads
                // consult the named table when the dense slot is a hole.
                if (ks_idx < self.array_size && !val.is_undefined()) {
                    self.set_array_idx(ks_idx, val, h);
                } else if (ks_idx < self.array_size) {
                    TVal hole; hole.set_undefined();
                    self.set_array_idx(ks_idx, hole, h);
                }
                if (ks_idx >= *self.array_len_ptr()) {
                    *self.array_len_ptr() = ks_idx + 1;
                    self.sync_named_length(h);
                }
            }
        }
        return true;
    }

    return self.put_prop_new(key, val, pflags, h);
}

// The append half of put_prop, for a key already established to be absent.
//
// Callers that have just run find_prop_idx() and seen a miss enter here to
// skip a second identical lookup: on a fresh object literal every key is new,
// so that lookup misses every time and its cost is pure repetition. The key
// must be interned and genuinely absent; passing a present key appends a
// duplicate the shape chain cannot describe.
fn bool HObject.put_prop_new(&self, void* key, TVal val, PropFlags pflags, heap::Heap* h) {
    void* length_key = (void*)h.strs[heap::BuiltinStr.LENGTH];
    if (pflags != PROP_FLAGS_WEC) self.flags.has_nondefault_flags = true;

    // A new integer-indexed element on an exotic array goes to the dense part,
    // which set_array_idx grows as needed. Indices past dense_index_ok stay in
    // the named table.
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

    uint new_idx = self.prop_count;
    mem::clear(&self.prop_values()[new_idx], (sz)(PropValue::size));
    h.store_slot(self, &self.prop_values()[new_idx], val);
    // Strings, objects, buffers, and BigInts are reference-counted heap
    // values held by properties, so the new value needs its own reference.
    val.incref_if_heap();
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
        h.invalidate_array_indices(self);
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
            self.prop_values()[new_idx].release_ref(h);
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
            } else if (self.prop_hash.mask == needed_mask || self.resize_prop_hash(needed_mask, h)) {
                // The insert is unconditional: a call earlier in this append can
                // have rebuilt the table before the shape named the new key.
                hash_table_insert((HashEntry*)self.prop_hash.table, self.prop_hash.mask, key, new_idx);
                self.prop_hash.count = self.prop_count;
            } else {
                self.drop_prop_hash(h);
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
    if (key != null && self.is_indexed_exotic()) {
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
    $if $feat(OP_PROFILE): opprof_shape_site[1]++; $endif

    // An emptied object returns to the root shape in slot 0, which describes it
    // exactly. Allocating a fresh private shape on every delete would grow the
    // shapes array without bound for no benefit. Nothing on this path can fail,
    // so the compaction may start right away.
    if (new_count == 0) {
        self.prop_values()[ui].release_ref(h);
        mem::clear(&self.prop_values()[ui], (sz)(PropValue::size));
        self.prop_count = 0;
        uint old_slot = (uint)self.shape_id;
        self.shape_id = 0;
        self.layout_moved(h);
        h.free_shape_slot(old_slot);
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
            shape_free(ns, h);
            return false;
        }

        // Collect surviving property names by walking the old shape chain.
        // The walk visits the newest shape first, so each key is written at its
        // own index (shifted down past the deleted slot) rather than appended.
        // Appending in walk order would reverse the keys relative to the values,
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
                    new_sp[new_idx].key.set(h, old_sp[j].key.borrow());
                    new_sp[new_idx].flags = old_sp[j].flags;
                }
            }
            walk = walk.parent_shape;
        }

        // Release the deleted slot's own reference before it is overwritten by
        // the compaction shift below.
        self.prop_values()[ui].release_ref(h);

        // Shift the surviving values down over the deleted slot.
        for (uint i = ui; i < new_count; i++) {
            h.store_slot(self, &self.prop_values()[i], self.prop_values()[i + 1].get());
        }
        mem::clear(&self.prop_values()[new_count], (sz)(PropValue::size));
        self.prop_count = new_count;

        uint old_slot = (uint)self.shape_id;
        Shape* old_shape = self.get_shape(h);
        bool old_was_private = old_shape != null
                            && old_shape.parent == PRIVATE_SHAPE_PARENT;
        h.store_new_shape(slot, ns);
        self.shape_id = slot;
        self.layout_moved(h);
        if (old_was_private && old_slot != slot) {
            h.free_shape_slot(old_slot);
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
    TVal v = self.array_part()[idx].get();
    if (v.is_undefined()) {
        return PROP_NOT_FOUND~;
    }
    return v;
}

// get_array_idx for a 53-bit index, which never matches past the dense part.
fn TVal? HObject.get_array_idx_wide(&self, ulong idx) @inline {
    if (idx >= (ulong)self.array_size) return PROP_NOT_FOUND~;
    return self.get_array_idx((uint)idx);
}

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
    self.prop_values()[idx].set_untraced(len_tv);
}

// Store a value in the dense array part, growing it if needed. Returns false
// when the index cannot go there, because of overflow or a failed grow, and the
// caller should then fall through to put_prop.
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
    TVal old_val = self.array_part()[idx].get();
    if (old_val.is_undefined() && !val.is_undefined()) {
        self.array_used++;
    } else if (!old_val.is_undefined() && val.is_undefined()) {
        if (self.array_used > 0) {
            self.array_used--;
        }
    }

    // Incref before decref, for the reason given in put_prop.
    PropValue* slot = &self.array_part()[idx];
    TVal old_slot_value = slot.get();
    if (types::either_heap_allocated(&val, &old_slot_value)) {
        val.incref_if_heap();
        if (slot.get().is_heap_allocated()) {
            slot.release_ref(h);
        }
    }
    h.store_slot(self, slot, val);
    return true;
}

// Copy `count` dense elements from index `from` to index `to`, holes included,
// with memmove's handling of an overlap; the source slots keep their values.
// An array's length grows to cover the last element copied past it. Returns
// false, copying nothing, when the dense part cannot grow to hold the target.
fn bool HObject.move_dense(&self, uint to, uint from, uint count, heap::Heap* h) {
    if (count == 0 || to == from) return true;
    if (to + count > self.array_size) {
        self.grow_array(to + count, h);
        if (to + count > self.array_size) return false;
    }
    PropValue* part = self.array_part();
    // A source past the dense part is all holes.
    uint have = from >= self.array_size ? 0 : min(count, self.array_size - from);
    // Reference the copies before releasing what they overwrite, which may be
    // among them. The values stay in this object, so the only barrier needed is
    // the marker's: a copy may land in a slot it has already scanned.
    bool marking = h.gc_phase == heap::GcPhase.MARK;
    for (uint i = 0; i < have; i++) {
        TVal v = part[from + i].get();
        if (v.is_heap_allocated() && v.get_heapptr() != null) ((types::HeapHeader*)v.get_heapptr()).incref();
        if (marking && v.is_traced()) h.shade_value(v);
    }
    for (uint i = 0; i < count; i++) {
        PropValue* slot = &part[to + i];
        if (slot.get().is_undefined()) continue;
        self.array_used--;
        slot.release_ref(h);
    }
    mem::move(&part[to], &part[from], (sz)((usz)have * PropValue::size));
    TVal hole;
    hole.set_undefined();
    for (uint i = have; i < count; i++) part[to + i].set_untraced(hole);
    uint last_present = 0;
    for (uint i = 0; i < have; i++) {
        if (part[to + i].get().is_undefined()) continue;
        self.array_used++;
        last_present = to + i + 1;
    }
    if (self.flags.exotic_array && last_present > *self.array_len_ptr()) {
        *self.array_len_ptr() = last_present;
        self.sync_named_length(h);
    }
    return true;
}

// ============================================================================
// HObject: growth and rehashing
// ============================================================================

// Reserve one external block for a fresh array's named properties and dense
// elements. RegExp match arrays know both bounds before inserting captures;
// reserving here avoids allocating elements, then copying them when the first
// named property moves the array off its header.
fn bool HObject.reserve_array_storage(&self, uint prop_capacity, uint array_capacity,
                                      heap::Heap* h) {
    if (self.flags.obj_class != ObjClass.ARRAY || self.prop_alloc != null
        || self.prop_count != 0 || self.prop_capacity != 0 || self.array_size != 0) {
        return false;
    }

    usz max_size = ~((usz)0);
    if ((usz)prop_capacity > max_size / PropValue::size) return false;
    usz prop_bytes = (usz)prop_capacity * PropValue::size;
    if ((usz)array_capacity > (max_size - prop_bytes) / TVal::size) return false;
    usz total_bytes = prop_bytes + (usz)array_capacity * TVal::size;
    if (total_bytes == 0) return true;

    void*? raw = h.pool_alloc(total_bytes);
    if (catch err = raw) return false;
    mem::clear(raw, (sz)total_bytes);

    self.prop_alloc = raw;
    self.prop_capacity = prop_capacity;
    self.array_size = array_capacity;
    PropValue* slots = self.array_part();
    for (uint i = 0; i < array_capacity; i++) slots[i].set_undefined();
    return true;
}

// Grow a full property value table. Moving off inline storage, meaning
// prop_alloc is still null, copies the inline props and the array data into the
// new block.
// Give an object that has no properties yet room for `cap` of them, so adding
// them never moves a slot.
fn void HObject.reserve_props(&self, heap::Heap* h, uint cap) {
    if (cap <= self.prop_capacity || self.prop_count != 0 || self.prop_alloc != null
        || self.array_size != 0) return;
    usz bytes = (usz)cap * PropValue::size;
    void* raw = h.pool_alloc(bytes) ?? null;
    if (raw == null) return;
    mem::clear(raw, (sz)bytes);
    self.prop_alloc = raw;
    self.prop_capacity = cap;
}

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
        PropValue* inline_array = self.array_part();
        if (inline_array != null) {
            mem::copy((char*)new_raw + new_prop_bytes, inline_array,
                      (sz)((usz)self.array_size * TVal::size));
        }
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
    self.layout_moved(h);

    if (new_cap > old_prop_capacity) {
        usz added_bytes = (usz)(new_cap - old_prop_capacity) * PropValue::size;
        void* start = (void*)((char*)self.prop_values() + (usz)old_prop_capacity * PropValue::size);
        mem::clear(start, (sz)(added_bytes));
    }
}

// Grow the dense array part to at least `new_size` TVal slots. New slots are
// initialised to undefined. With no external block, copy any inline properties
// and dense slots before publishing the replacement.
fn void HObject.grow_array(&self, uint new_size, heap::Heap* h) {
    if (new_size <= self.array_size) return;
    h.invalidate_array_indices(self);

    usz new_bytes = (usz)self.prop_capacity * PropValue::size + (usz)new_size * TVal::size;

    void* new_raw;
    if (self.prop_alloc == null) {
        // Transition from inline to heap: allocate and copy inline props.
        new_raw = h.pool_alloc(new_bytes) ?? null;
        if (new_raw == null) return;
        PropValue* inline_src = self.inline_props_ptr();
        mem::copy(new_raw, inline_src, (sz)((usz)self.prop_count * PropValue::size));
        PropValue* inline_array = self.array_part();
        if (inline_array != null) {
            mem::copy((char*)new_raw + (usz)self.prop_capacity * PropValue::size,
                      inline_array, (sz)((usz)self.array_size * TVal::size));
        }
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
    self.layout_moved(h);
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
// heap's allocation registry; Heap.alloc_object wraps both steps.
//
// Pool allocation first, malloc fallback when the pool is exhausted
// (flags.pool_fallback records which, so hobject_free routes the free).
//
// The object starts with htype OBJECT, extensible, class `cls`, and an empty
// property table. A short array literal reserves its dense slots in the
// header allocation. Returns `null` on allocation failure.
fn HObject*? hobject_alloc(void* heap_ptr, ObjClass cls, uint inline_array_capacity = 0, bool compact_props = false) @inline {
    compact_props = compact_props && cls == ObjClass.OBJECT;
    bool inline_literal_array = cls == ObjClass.ARRAY
        && inline_array_capacity > 0 && inline_array_capacity <= ARRAY_INLINE_MAX_CAPACITY;
    usz alloc_sz = compact_props ? OBJ_SIZE_COMPACT : inline_literal_array
        ? inline_array_alloc_size(inline_array_capacity)
        : alloc_size_for_class(cls);

    void* raw = null;
    bool from_pool = false;
$if $feat(POOL_BYPASS):
    // Debug builds bypass the pools so ASan sees every free. A pooled free never
    // calls free(), so a use-after-free on a pooled object reads memory that is
    // still mapped and may already hold another object. The fallback path below
    // makes each object a real allocator alloc/free pair, so ASan reports the
    // offending read. This costs an allocator round-trip per object: asan and
    // gc-stress targets only.
$else
    if (compact_props) {
        raw = ((heap::Heap*)heap_ptr).obj_pool_compact.alloc();
        from_pool = raw != null;
    } else if (inline_literal_array) {
        raw = ((heap::Heap*)heap_ptr).obj_pool_inline_arrays[inline_array_capacity - 1].alloc();
        from_pool = raw != null;
    } else {
        void* pool = pool_for_class(heap_ptr, cls);
        if (pool != null) {
            raw = ((pagepool::PagePool*)pool).alloc();
            from_pool = true;
        }
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

    // A pool block arrives zeroed: the pool's pages are calloc'd and a
    // recycled block is cleared when it leaves the freelist.
    if (!from_pool) mem::clear(raw, (sz)(alloc_sz));

    HObject* obj = (HObject*)raw;

    obj.prop_alloc = null;
    obj.prop_capacity = cls == ObjClass.ARRAY ? 0 : compact_props ? COMPACT_INLINE_PROPS : INLINE_PROPS;
    obj.prop_count = 0;

    obj.flags.htype        = HType.OBJECT;
    obj.flags.extensible   = true;
    obj.flags.obj_class    = cls;
    obj.flags.pool_fallback = !from_pool;
    obj.gc                 = {};
    obj.gc.compact_props   = compact_props;

    if (cls == ObjClass.FUNCTION) {
        obj.flags.callable      = true;
        obj.flags.constructable = true;
        (*obj.extra_ptr()).func.builtin_fn_index = -1;
    } else if (cls == ObjClass.ARRAY) {
        obj.flags.exotic_array = true;
        obj.flags.array_len_writable = true;
        obj.array_len_ptr()[0] = 0;
        if (inline_literal_array) {
            obj.array_inline_capacity_ptr()[0] = inline_array_capacity;
            obj.array_size = inline_array_capacity;
            PropValue* slots = obj.array_part();
            for (uint i = 0; i < inline_array_capacity; i++) slots[i].set_undefined();
        }
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

// Free a block that was allocated through the heap when one is present, or
// through the process allocator when teardown runs without a heap.
fn void free_block(heap::Heap* hp, void* p) @inline {
    if (hp != null) {
        hp.free_func(hp.heap_udata, p);
    } else {
        mem::free(p);
    }
}

// Free an HObject and everything it owns: the property table and the array
// part. The caller controls its removal from the allocation registry.
//
// A pooled object (no flags.pool_fallback) goes back to its PagePool;
// the rest are freed through the heap's allocator, or mem::free when no heap
// is active.
fn void hobject_free_impl(HObject* obj, void* heap_ptr, bool free_header, bool slots_released) {
    if (obj == null) { return; }
    // The owning heap, which every caller supplies. Its `tearing_down` flag,
    // not the presence of a heap, decides whether the decref passes below run:
    // destroy() and reset() free every node directly and must not also release
    // references into a string table they are sweeping.
    heap::Heap* hp = (heap::Heap*)heap_ptr;

    // Subtype resources are disjoint. Ordinary objects and arrays own only
    // the shared property and element storage released below.
    switch (obj.flags.obj_class) {
        case ObjClass.HOST:
            void* payload = (*obj.extra_ptr()).host.payload;
            if (payload != null) {
                heap::HostClassEntry* hc = hp.host_class_at((*obj.extra_ptr()).host.class_id);
                if (hc != null && hc.finalizer != null) {
                    heap::HostClassFinalizeFn fin = (heap::HostClassFinalizeFn)hc.finalizer;
                    fin(payload, hc.udata);
                }
                (*obj.extra_ptr()).host.payload = null;
            }
        case ObjClass.REGEXP:
            if ((*obj.extra_ptr()).regexp.regexp_data != null) {
                re_bindings::re_free((*obj.extra_ptr()).regexp.regexp_data);
                (*obj.extra_ptr()).regexp.regexp_data = null;
            }
            if (!hp.tearing_down) hp.decref_tval(&(*obj.extra_ptr()).prim.primitive_value);
        case ObjClass.PROMISE:
            if (!hp.tearing_down) {
                hp.decref_tval(&(*obj.extra_ptr()).promise.result);
                (*obj.extra_ptr()).promise.reactions_head = null;
                (*obj.extra_ptr()).promise.reactions_tail = null;
            }
        case ObjClass.PROMISE_REACTION:
            if (!hp.tearing_down) {
                for (uint i = 0; i < 3; i++) hp.decref_tval(&(*obj.extra_ptr()).reaction.values[i]);
            }
        case ObjClass.ARRAYBUFFER:
            if (!hp.tearing_down && (*obj.extra_ptr()).ab.data != null) {
                hp.free_func(hp.heap_udata, (*obj.extra_ptr()).ab.data);
                (*obj.extra_ptr()).ab.data = null;
            }
        case ObjClass.GETTER_SETTER:
            if (!hp.tearing_down) {
                hp.decref_tval(&(*obj.extra_ptr()).gs.getter);
                hp.decref_tval(&(*obj.extra_ptr()).gs.setter);
            }
        case ObjClass.FUNCTION:
            if (!hp.tearing_down) {
                if (obj.flags.is_bound) {
                    hp.decref_tval(&(*obj.extra_ptr()).func.bound.target);
                    hp.decref_tval(&(*obj.extra_ptr()).func.bound.this_arg);
                } else {
                    hp.decref_tval(&(*obj.extra_ptr()).func.captured_this);
                }
            }
            // One capture descriptor lives inline; larger vectors use pools.
            if (!obj.flags.is_async_state && (*obj.extra_ptr()).func.capture_refs != null) {
                uint count = (*obj.extra_ptr()).func.comp_func.capture_count;
                if (!hp.tearing_down) {
                    for (uint i = 0; i < count; i++) {
                        CaptureRef* ref = &(*obj.extra_ptr()).func.capture_refs[i];
                        if (ref.is_value) hp.decref_tval(&ref.value);
                    }
                }
                if ((*obj.extra_ptr()).func.capture_refs != &(*obj.extra_ptr()).func.inline_capture) {
                    hp.pool_free((*obj.extra_ptr()).func.capture_refs, (usz)count * CaptureRef::size);
                }
                (*obj.extra_ptr()).func.capture_refs = null;
            }
            // GeneratorState ownership is shared with generators and reactions.
            // Release by reference count without following any dying JS nodes.
            if (obj.flags.is_async_state) {
                heap::GeneratorState* gs = (heap::GeneratorState*)(*obj.extra_ptr()).func.var_env;
                (*obj.extra_ptr()).func.var_env = null;
                heap::gs_release(gs, heap_ptr, !hp.tearing_down);
            }
        case ObjClass.ERROR:
            if (!hp.tearing_down) hp.decref_tval(&(*obj.extra_ptr()).err.captured_stack);
        case ObjClass.ASYNC_CONTINUATION:
            heap::GeneratorState* gs = (*obj.extra_ptr()).async_cont.state;
            (*obj.extra_ptr()).async_cont.state = null;
            heap::gs_release(gs, heap_ptr, !hp.tearing_down);
        case ObjClass.GENERATOR:
            heap::GeneratorState* gs = (heap::GeneratorState*)(*obj.extra_ptr()).gen.generator_data;
            (*obj.extra_ptr()).gen.generator_data = null;
            heap::gs_release(gs, heap_ptr, !hp.tearing_down);
        case ObjClass.BOOLEAN:
        case ObjClass.BIGINT:
        case ObjClass.NUMBER:
        case ObjClass.STRING:
        case ObjClass.SYMBOL:
        case ObjClass.DATE:
            if (!hp.tearing_down) hp.decref_tval(&(*obj.extra_ptr()).prim.primitive_value);
        case ObjClass.TEMPORAL_TIMEZONE:
            if (!hp.tearing_down) (*obj.extra_ptr()).temporal.identifier.release(hp);
        case ObjClass.WRAP_FOR_VALID_ITERATOR:
            if (!hp.tearing_down) hp.decref_tval(&(*obj.extra_ptr()).wrap_iter.next_method);
        case ObjClass.ITERATOR_HELPER:
            if (!hp.tearing_down) {
                hp.decref_tval(&(*obj.extra_ptr()).iter_helper.next_method);
                hp.decref_tval(&(*obj.extra_ptr()).iter_helper.callback);
                hp.decref_tval(&(*obj.extra_ptr()).iter_helper.inner_next);
            }
        case ObjClass.STRING_ITERATOR:
            if (!hp.tearing_down) (*obj.extra_ptr()).str_iter.string.release(hp);
        case ObjClass.REGEXP_STRING_ITERATOR:
            if (!hp.tearing_down) (*obj.extra_ptr()).regexp_iter.string.release(hp);
        default:
    }

    // Release the strings held in property slots and array elements. Every
    // other value is reclaimed by the collector, so Heap.decref ignores it.
    if (!hp.tearing_down && !slots_released) {
        heap::Heap* h = hp;
        PropValue* pvs = obj.prop_values();
        for (uint i = 0; i < obj.prop_count; i++) {
            if (pvs[i].get().is_heap_allocated()) {
                pvs[i].release_ref(h);
            }
        }
        hobject::PropValue* arr = obj.array_part();
        if (arr != null) {
            for (uint i = 0; i < obj.array_size; i++) {
                if (arr[i].get().is_heap_allocated()) {
                    arr[i].release_ref(h);
                }
            }
        }
    }

    // A private shape, from a dictionary or a delete, belongs to this object
    // alone and dies with it. Teardown frees every shape directly.
    if (!hp.tearing_down) {
        Shape* sh = hp.get_shape(obj.shape_id);
        if (sh != null && sh.parent == PRIVATE_SHAPE_PARENT) {
            $if $feat(OP_PROFILE): opprof_shape_site[3]++; $endif
            hp.free_shape_slot(obj.shape_id);
        }
    }

    if (obj.prop_hash != null) {
        free_block(hp, obj.prop_hash.table);
        free_block(hp, obj.prop_hash);
        obj.prop_hash = null;
    }

    // The collection lookup index, for MAP/SET/WEAKMAP/WEAKSET. It holds
    // indices into array_part rather than references, so it needs freeing but
    // never GC tracing.
    if (obj.has_coll_hash()) {
        CollHashInfo* coll = *obj.coll_hash_ptr();
        if (coll != null) {
            if (coll.slots != null) free_block(hp, coll.slots);
            free_block(hp, coll);
            *obj.coll_hash_ptr() = null;
        }
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

    // Release the header after its slots and subtype resources, unless the
    // caller deferred returning the backing memory.
    if (free_header) {
        hobject_free_header(obj, heap_ptr);
    }
}

// Teardown can be paused between slots while the header and its backing array
// stay allocated. The sweep keeps both off its free list until this returns
// true. A slot is visited at most once, so string ownership is released once.
fn bool hobject_free_step(HObject* obj, void* heap_ptr, usz* cursor, uint budget) {
    if (obj == null) return true;
    heap::Heap* h = (heap::Heap*)heap_ptr;
    usz prop_count = obj.prop_count;
    usz total = h.tearing_down ? 0 : prop_count + (usz)obj.array_size;
    usz i = *cursor;
    usz remaining = total - i;
    usz end = i + (remaining < (usz)budget ? remaining : (usz)budget);
    // The cursor lives in a local so the loops keep it in a register; it goes
    // back to the caller once, below.
    if (i < prop_count) {
        PropValue* props = obj.prop_values();
        usz props_end = end < prop_count ? end : prop_count;
        for (; i < props_end; i++) {
            if (props[i].get().is_heap_allocated()) props[i].release_ref(h);
        }
    }
    if (i < end) {
        PropValue* arr = obj.array_part();
        usz base = prop_count;
        if (arr != null) {
            for (; i < end; i++) {
                if (arr[i - base].get().is_heap_allocated()) arr[i - base].release_ref(h);
            }
        }
        i = end;
    }
    *cursor = i;
    if (*cursor < total) return false;
    hobject_free_impl(obj, heap_ptr, false, true);
    return true;
}

fn void hobject_free(HObject* obj, void* heap_ptr, bool free_header) {
    hobject_free_impl(obj, heap_ptr, free_header, false);
}

// Release just the header's backing memory, whether a pool block or a malloc,
// once hobject_free(obj, heap, false) has run the sub-allocation teardowns and
// decrefs. Object edges carry no reference count, so teardown does not follow
// another dying node that the sweep may already have released.
fn void hobject_free_header(HObject* obj, void* heap_ptr) {
    if (obj == null) { return; }
    heap::Heap* hp = (heap::Heap*)heap_ptr;
    if (obj.flags.pool_fallback) {
        free_block(hp, obj);
    } else if (obj.gc.compact_props) {
        hp.obj_pool_compact.dealloc(obj);
    } else {
        uint inline_capacity = obj.array_inline_capacity();
        if (inline_capacity > 0) {
            if (hp == null) {
                mem::free(obj);
            } else {
                hp.obj_pool_inline_arrays[inline_capacity - 1].dealloc(obj);
            }
        } else {
            void* pool = pool_for_class(heap_ptr, obj.flags.obj_class);
            if (pool != null) {
                ((pagepool::PagePool*)pool).dealloc(obj);
            } else {
                free_block(hp, obj);
            }
        }
    }
}

// ============================================================================
// Enumeration helpers
// ============================================================================

fn uint HObject.enumerable_count(&self, heap::Heap* h) {
    uint count = 0;
    for (uint i = 0; i < self.prop_count; i++) {
        if (self.get_prop_flags(i, h).enumerable) {
            count++;
        }
    }
    return count;
}

// Returns the property value slot at the raw index `idx`, or PROP_NOT_FOUND
// when it is out of range. Intended for iteration over own properties.
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
        if (cur.is_proxy()) {
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
            return cur.prop_values()[idx].get();
        }
        // ARRAY exotic: "length" lives in array_len_ptr, not the named table
        // (mirrors has_prop_proto and the VM's GETPROP). Without this a
        // `with`-env read of an inherited array length misses the binding.
        if (cur.get_class() == ObjClass.ARRAY
            && key == (void*)h.strs[heap::BuiltinStr.LENGTH]) {
            TVal len;
            len.set_fastint((long)*cur.array_len_ptr());
            return len;
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

// Search once for the first property. Accessors use `found` and `accessor_fn`;
// a data property stops the walk with `property_found` and its writable flag.
// A caller that has already missed `self`'s own table passes `own_missed` to
// start at the prototype; `this_obj` stays `self` either way.
fn AccessorResult HObject.find_accessor_proto(&self, void* key, bool want_getter, heap::Heap* h,
                                              bool own_missed = false) {
    HObject* cur = own_missed ? self.prototype : self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        int idx = cur.find_prop_idx(key, h);
        if (idx >= 0) {
            PropFlags flags = cur.get_prop_flags((uint)idx, h);
            if (flags.is_accessor) {
                TVal gs_slot = cur.prop_values()[idx].get();
                TVal accessor_fn = want_getter ? hobject_access_getter(gs_slot) : hobject_access_setter(gs_slot);
                return { .accessor_fn = accessor_fn, .this_obj = self, .found = true, .property_found = true };
            }
            return { .property_found = true, .property_writable = flags.writable };
        }
        cur = cur.prototype;
        depth++;
    }

    return { .found = false };
}

// ECMA-262 OrdinaryGet: full prototype-chain Get semantics, invoking accessor
// getters. Used by builtins that need a full Get, such as the Map and Set
// constructors looking up `set` and `add`.
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

struct JsonShapeEntry {
    StringRef key;
    uint slot;
    uint quoted_offset;
    uint quoted_length;
}

// The shape owns one reference; a serializer holds another across callbacks
// that can move the receiver to a different shape and collect the old one.
struct JsonShapePlan {
    uint refs;
    uint count;
    JsonShapeEntry* entries;
    char* quoted_keys;
}

fn void json_shape_plan_release(JsonShapePlan* plan, heap::Heap* h) {
    if (plan == null || --plan.refs != 0) return;
    for (uint i = 0; i < plan.count; i++) plan.entries[i].key.release(h);
    h.free_func(h.heap_udata, plan.entries);
    if (plan.quoted_keys != null) h.free_func(h.heap_udata, plan.quoted_keys);
    h.free_func(h.heap_udata, plan);
}

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
    // Properties the allocation has room for. Equal to own_count except on a
    // dictionary shape, which grows in place.
    uint      capacity;
    // A flat private shape that its one object extends in place instead of
    // moving to a new shape per property, so an object used as a dictionary
    // costs one allocation however many keys it takes. Its shape id stays
    // put as keys arrive, which inline caches must not read as "no new keys":
    // see HObject.in_dict_mode.
    bool      dict;
    // Named by compiled code (an object-literal shape baked into NEWOBJ_SHAPE)
    // or cached in a Heap field, so the shape sweep keeps it and its ancestors
    // with no object using them.
    bool      pinned;
    bool      json_plan_rejected;
    // Built lazily for immutable ordinary-object shapes used by JSON.stringify.
    JsonShapePlan* json_plan;
}

// ============================================================================
// Shape: memory layout helpers
// ============================================================================

// The ShapeProperty array, which follows the header in the same allocation.
fn ShapeProperty* Shape.props(&self) {
    return (ShapeProperty*)((char*)self + Shape::size);
}

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
    sh.capacity     = own_count;
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

    ns.props()[0].key.set(h, (HString*)new_key);
    ns.props()[0].flags = flags;

    return ns;
}

// Copy `src`'s whole chain into one flat shape that only the caller's object
// will use, with room for at least `capacity` properties.
fn Shape* shape_flatten(Shape* src, uint capacity, heap::Heap* h) {
    uint count = src.offset + src.own_count;
    Shape* ns = shape_create(capacity > count ? capacity : count, 0, PRIVATE_SHAPE_PARENT, null, h);
    if (ns == null) return null;
    ns.own_count = count;

    ShapeProperty* new_sp = ns.props();
    for (Shape* walk = src; walk != null; walk = walk.parent_shape) {
        ShapeProperty* old_sp = walk.props();
        for (uint j = 0; j < walk.own_count; j++) {
            new_sp[walk.offset + j].key.set(h, old_sp[j].key.borrow());
            new_sp[walk.offset + j].flags = old_sp[j].flags;
        }
    }
    return ns;
}

// Append a property to a dictionary shape in place, doubling the allocation
// when it is full. Returns the shape, which moves when it grows, or null when
// the allocation fails and the shape is unchanged.
fn Shape* shape_dict_push(Shape* sh, void* key, PropFlags flags, heap::Heap* h) {
    if (sh.own_count == sh.capacity) {
        uint capacity = sh.capacity * 2;
        usz old_bytes = shape_alloc_size(sh.capacity);
        Shape* grown = (Shape*)h.realloc_func(h.heap_udata, sh, shape_alloc_size(capacity));
        if (grown == null) return null;
        h.account_auxiliary_allocation(shape_alloc_size(capacity));
        mem::clear((char*)grown + old_bytes, (sz)(shape_alloc_size(capacity) - old_bytes));
        grown.capacity = capacity;
        sh = grown;
    }
    ShapeProperty* sp = &sh.props()[sh.own_count];
    sp.key.set(h, (HString*)key);
    sp.flags = flags;
    sh.own_count++;
    return sh;
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
            void* k = sp[j].key.borrow();
            if (k != null) hash_table_insert(entries, mask, k, sh.offset + j);
        }
        sh = sh.parent_shape;
    }
    leaf.hash_table = entries;
}

// Each shape releases exactly the keys stored in its own segment.
fn void shape_free(Shape* sh, heap::Heap* h) {
    if (sh == null) return;
    json_shape_plan_release(sh.json_plan, h);
    ShapeProperty* sp = sh.props();
    for (uint i = 0; i < sh.own_count; i++) sp[i].key.release(h);
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

// One inline cache entry per property bytecode site. GETPROP caches a resolved
// value slot; PUTPROP caches an own slot or a proven absent-property decision.
//
// Read entries cover a property up to IC_MAX_CHAIN links up the chain. An
// absent-property write entry covers the whole chain and its null terminator.
// Both snapshot each stepped object's identity and shape, so a hit can replay
// the walk without searching property tables.
struct ICEntry {
    // Receiver shape ID when this entry was populated.
    uint   shape_id;
    // Receiver shape generation for slot caches, or the heap-wide shape-recycle
    // epoch for absent-property PUTPROP entries.
    uint   shape_gen;
    // Property index within the owner's prop_values[], or IC_PROP_ABSENT for a
    // PUTPROP entry proving that a store adds the key: absent from the
    // receiver, and on its chain absent or a writable data property.
    uint   prop_idx;
    // The property's flags, so a cache hit needs no shape walk.
    PropFlags prop_flags;
    // Prototype links to a read owner, or the full chain length for an absent
    // write. Zero marks an own read or a receiver with a null prototype.
    char   chain_len;
    // Shape of each object stepped onto, ending with the owner for reads or
    // covering the full chain for an absent-property write.
    uint[IC_MAX_CHAIN] chain_shapes;
    // Each object stepped onto, held as a weak pointer compared only for
    // identity against the live chain.
    void*[IC_MAX_CHAIN] chain_protos;
    // Where the property was found, or null for own and absent entries.
    void*  proto;
    // The interned key this entry was filled for, compared by pointer.
    hstring::StringRef key;
    // Absent-property PUTPROP entries: the shape after appending the key.
    uint absent_next_shape;
}

// An absent-property PUTPROP cache reuses the normal property-index field for
// its marker. No real property index can reach this value.
const uint IC_PROP_ABSENT = 0xFFFFFFFFu;

fn bool plain_property_object(HObject* obj) @inline {
    return obj != null
        && obj.get_class() == ObjClass.OBJECT
        && !obj.is_proxy()
        && !obj.flags.exotic_array
        && !obj.flags.exotic_arguments
        && !obj.flags.exotic_stringobj
        && !obj.flags.exotic_module_ns
        && !obj.flags.exotic_deferred_ns;
}

// Validate an absent-property PUTPROP cache. The stored shape_gen is the
// heap-wide recycle epoch: this cache keeps no property-slot pointer, so a
// storage reallocation does not invalidate it, while a reused shape ID does.
fn bool ic_matches_absent_put(ICEntry* ic, HObject* receiver, void* key,
                              heap::Heap* h) @inline {
    if (ic.prop_idx != IC_PROP_ABSENT || ic.proto != null
        || ic.key.borrow() != key
        || ic.shape_id != receiver.shape_id
        || ic.shape_gen != h.shape_recycle_epoch
        || !receiver.flags.extensible
        || !plain_property_object(receiver)) {
        return false;
    }

    return ic_matches_absent_chain(ic, receiver.prototype);
}

fn bool ic_matches_absent_chain(ICEntry* ic, HObject* prototype) @inline {
    uint links = (uint)ic.chain_len;
    if (links > IC_MAX_CHAIN) return false;
    HObject* cur = prototype;
    for (uint i = 0; i < links; i++) {
        if (cur == null || cur != (HObject*)ic.chain_protos[i]
            || cur.shape_id != ic.chain_shapes[i]
            || !plain_property_object(cur)) {
            return false;
        }
        cur = cur.prototype;
    }
    // The snapshot includes the terminating null, so a later chain extension
    // cannot turn an absent property into an inherited setter or data value.
    return cur == null;
}

// Append `val` under a validated absent-property cache, moving the receiver
// straight to the recorded shape. Returns false, having changed nothing, when
// the property storage is full and put_prop_new must grow it.
fn bool HObject.append_cached_prop(&self, ICEntry* ic, TVal val, heap::Heap* h) @inline {
    if (self.prop_count >= self.prop_capacity || self.prop_hash != null) return false;
    PropValue* slot = &self.prop_values()[self.prop_count];
    mem::clear(slot, (sz)(PropValue::size));
    h.store_slot(self, slot, val);
    val.incref_if_heap();
    self.prop_count++;
    self.shape_id = ic.absent_next_shape;
    return true;
}

// Record a store that added a property, only when the whole chain is short and
// uses ordinary object semantics. The add stays right while every prototype
// keeps its shape: an inherited holder of the key that turns read-only or an
// accessor changes shape, as any flag edit does. `next_shape_id` is the shape the
// slow path moved the receiver to. Only a transition-table shape is cached:
// it is never freed and stays valid while `recycle_epoch` does, where a
// private or dictionary shape belongs to the one receiver. A receiver at the
// hash threshold keeps a table of its own while its shape chain is unshared,
// which an append would have to update, so for one that large the cache needs
// a shared shape, whose single table already names the key.
// Record a `var` declaration that appended `key` to a function scope's
// bindings, moving them from `from_shape` to `to_shape`. A later scope of the
// same function on `from_shape` lacks the key, so the declaration appends it
// again by the same transition. Bindings have no prototype to consult.
fn void ic_fill_declare(ICEntry* ic, HObject* bindings, void* key,
                        uint from_shape, uint to_shape, heap::Heap* h) {
    if (bindings.prototype != null || bindings.prop_hash != null
        || h.lookup_transition(from_shape, key, (char)PROP_FLAGS_WE) != to_shape) return;
    if (bindings.prop_count > HASH_MIN_PROPS) {
        Shape* next = h.get_shape(to_shape);
        if (next == null || !next.shared) return;
    }
    ic.shape_id = from_shape;
    ic.shape_gen = h.shape_recycle_epoch;
    ic.proto = null;
    ic.chain_len = 0;
    ic.prop_idx = IC_PROP_ABSENT;
    ic.prop_flags = PROP_FLAGS_WE;
    ic.key.set(h, (HString*)key);
    ic.absent_next_shape = to_shape;
}

fn bool ic_fill_absent_put(ICEntry* ic, HObject* receiver, void* key,
                           uint receiver_shape_id, uint next_shape_id,
                           uint recycle_epoch, heap::Heap* h) {
    if (h.lookup_transition(receiver_shape_id, key, (char)PROP_FLAGS_WEC) != next_shape_id) return false;
    if (receiver.prop_count >= HASH_MIN_PROPS) {
        Shape* next = h.get_shape(next_shape_id);
        if (next == null || !next.shared) return false;
    }
    void*[IC_MAX_CHAIN] protos;
    uint[IC_MAX_CHAIN] shapes;
    uint chain_len = 0;
    HObject* cur = receiver.prototype;
    while (cur != null) {
        if (chain_len >= IC_MAX_CHAIN || !plain_property_object(cur) || cur.in_dict_mode(h)) return false;
        protos[chain_len] = (void*)cur;
        shapes[chain_len] = cur.shape_id;
        chain_len++;
        cur = cur.prototype;
    }

    ic.shape_id = receiver_shape_id;
    ic.shape_gen = recycle_epoch;
    ic.proto = null;
    ic.chain_len = (char)chain_len;
    for (uint i = 0; i < IC_MAX_CHAIN; i++) {
        if (i < chain_len) {
            ic.chain_protos[i] = protos[i];
            ic.chain_shapes[i] = shapes[i];
        } else {
            ic.chain_protos[i] = null;
            ic.chain_shapes[i] = 0;
        }
    }
    ic.prop_idx = IC_PROP_ABSENT;
    ic.prop_flags = PROP_FLAGS_WEC;
    ic.key.set(h, (HString*)key);
    ic.absent_next_shape = next_shape_id;
    return true;
}

// This object's shape generation, or a value no entry can match when it has
// no shape. Paired with shape_id it names one property layout uniquely, since
// a recycled id is always stamped with a fresh generation.
fn uint HObject.shape_generation(&self, heap::Heap* h) @inline {
    Shape* sh = self.get_shape(h);
    return sh != null ? sh.generation : 0xFFFFFFFFu;
}

// shape_generation for a hit path that has just matched `shape_id` against a
// cache entry filled from a live shape. Every object carries a live shape id,
// so the lookup skips the range and liveness tests.
fn uint HObject.live_shape_generation(&self, heap::Heap* h) @inline {
    return h.shapes[self.shape_id].generation;
}

// True when this object's shape is a dictionary: keys can join it without its
// shape id changing. An inline cache entry that proves a key absent from the
// object, or that skips the object on the way to a prototype, would go stale
// the moment the key arrives, so such entries must not describe it. An entry
// for a property the object already has stays valid, since indexes never move.
fn bool HObject.in_dict_mode(&self, heap::Heap* h) @inline {
    Shape* sh = self.get_shape(h);
    return sh != null && sh.dict;
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

// The validated shape fixes the slot index. Resolve it against the owner's
// current storage so growing the property buffer does not invalidate a hit.
fn PropValue* ic_resolve_slot(ICEntry* ic, HObject* hobj) @inline {
    if (hobj.is_proxy()) return null;
    HObject* owner = ic_resolve_owner(ic, hobj);
    if (owner == null || owner.is_proxy()) return null;
    return &owner.prop_values()[ic.prop_idx];
}

// The slot of a cached data property, or null for a miss or an accessor entry.
fn PropValue* ic_resolve_value(ICEntry* ic, HObject* hobj) @inline {
    if (ic.prop_flags.is_accessor) return null;
    return ic_resolve_slot(ic, hobj);
}

// One entry in the global megamorphic cache, shared by every call site. An own
// property is keyed by (shape_id, key); one found on the receiver's immediate
// prototype is keyed by (shape_id, key, prototype), since receivers of one
// shape can have different prototypes (every fresh object starts at the empty
// shape) and would otherwise evict each other's entries.
//
// A shape does not name a prototype, which Object.setPrototypeOf can repoint
// without touching shapes, so a prototype entry also snapshots the prototype's
// identity and shape for the hit path to re-check.
struct MegamorphicEntry {
    hstring::StringRef key;           // interned key pointer (null = empty slot)
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
    // True when the slot holds an accessor cell rather than a data value.
    bool    is_accessor;
    // The property's flags, which its owner's shape fixes.
    PropFlags flags;
}

fn uint mega_hash(uint shape_id, void* key) @inline {
    return ((uint)(uptr)key ^ (shape_id * 2654435761u)) & (heap::MEGA_CACHE_SIZE - 1);
}

// The slot for a property found on the immediate prototype `proto`.
fn uint mega_hash_proto(uint shape_id, void* key, void* proto) @inline {
    return ((uint)(uptr)key ^ (shape_id * 2654435761u) ^ (((uint)(uptr)proto >> 4) * 2246822519u))
        & (heap::MEGA_CACHE_SIZE - 1);
}

// Probe the megamorphic cache for `key` on `hobj`, returning the property's
// slot and its entry on a hit and null on a miss.
fn PropValue* mega_cache_lookup(heap::Heap* h, HObject* hobj, void* key, MegamorphicEntry** entry) @inline {
    if (h.mega_cache == null) return null;
    MegamorphicEntry* e = h.mega_cache + mega_hash(hobj.shape_id, key);
    if (e.key.borrow() == key && e.shape_id == hobj.shape_id && e.proto == null) {
        if (e.recycle_epoch != h.shape_recycle_epoch) return null;
        *entry = e;
        return &hobj.prop_values()[e.prop_idx];
    }
    if (hobj.prototype == null) return null;
    e = h.mega_cache + mega_hash_proto(hobj.shape_id, key, (void*)hobj.prototype);
    if (e.key.borrow() != key || e.shape_id != hobj.shape_id || e.proto == null) return null;
    if (e.recycle_epoch != h.shape_recycle_epoch) return null;
    *entry = e;
    // The receiver's shape says it has no own `key`; the recorded link must
    // still be the live one, at the same shape, for the owner to answer.
    HObject* owner = (HObject*)e.proto;
    if (hobj.prototype != owner || owner.shape_id != e.proto_shape_id) return null;
    return &owner.prop_values()[e.prop_idx];
}

// Record a successful lookup in the megamorphic cache.
//
// Own properties and properties on the receiver's immediate prototype are
// stored; anything deeper is not, since the entry has room to re-check only
// one link and a longer chain could change out of sight.
fn void mega_cache_store(heap::Heap* h, HObject* hobj, void* key, HObject* owner, int prop_idx, bool is_accessor) @inline {
    if (h.mega_cache == null) return;
    bool own = owner == hobj;
    // A dictionary shape can lose a key without changing its id.
    if (hobj.in_dict_mode(h) || (!own && (hobj.prototype != owner || owner.in_dict_mode(h)))) return;
    uint slot = own ? mega_hash(hobj.shape_id, key) : mega_hash_proto(hobj.shape_id, key, (void*)owner);
    MegamorphicEntry* e = h.mega_cache + slot;
    e.key.set(h, (HString*)key);
    e.shape_id = hobj.shape_id;
    e.prop_idx = (uint)prop_idx;
    e.proto = own ? null : (void*)owner;
    e.proto_shape_id = owner.shape_id;
    e.recycle_epoch = h.shape_recycle_epoch;
    e.is_accessor = is_accessor;
    e.flags = owner.get_prop_flags((uint)prop_idx, h);
}

// True when `instanceof` with `rfunc` on the right is plain OrdinaryHasInstance:
// rfunc is callable and unbound, and its @@hasInstance, found through the
// megamorphic cache, is the one on this realm's Function.prototype. That
// property is neither writable nor configurable, so its owner names its value.
fn bool uses_default_has_instance(heap::Heap* h, HObject* rfunc) @inline {
    if (!rfunc.is_callable() || rfunc.flags.is_bound || rfunc.is_proxy() || h.hasinstance_symbol == null) return false;
    MegamorphicEntry* me;
    PropValue* slot = mega_cache_lookup(h, rfunc, (void*)h.hasinstance_symbol, &me);
    return slot != null && !me.is_accessor && me.proto == (void*)h.function_proto;
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
    // The property's flags, guarded by the shape id and recycle epoch.
    PropFlags prop_flags;
    // Byte offset from bindings to its inline property storage. An object's
    // class, and so this offset, never changes, which spares a hit the
    // class-dependent size lookup that prop_values() performs.
    uint    props_off;
    // The validated chain head. A new activation needs re-arm checks before
    // replacing it. The GETGLOBAL family runs in one activation.
    void*   search_head;
    // Set for PUTGLOBAL/INC_GLOBAL/DEC_GLOBAL slots whose property is
    // a writable but non-configurable data property (ECMA-262
    // CreateGlobalVarBinding): such a descriptor can never become an accessor
    // or turn read-only, so the store fast path skips re-checking writability.
    // Configurable globals (e.g. from `eval`) leave this false and take the
    // checking path; the shape_id compare runs either way.
    bool    varref_store_ok;
    // The binding's slot, valid while recycle_epoch matches the heap's:
    // HObject.layout_moved advances the epoch whenever the slot moves or the
    // cached flags change. Null while unpopulated.
    PropValue* slot_ptr;
    // How many records the lookup passed before the owner, when every one of
    // them (and the owner, at depth 0) is a per-call scope identified by its
    // shape: a different activation of the same code can then re-arm the
    // entry instead of missing. VAR_IC_NO_REARM otherwise.
    char    rearm_depth;
    // The passed records, nearest first: the same record is trusted as the
    // original fill trusts its chain, and a different one must have the shape.
    void*[VAR_IC_REARM_MAX] passed_envs;
    uint[VAR_IC_REARM_MAX] passed_shapes;
}

const char VAR_IC_NO_REARM = 0xFF;
const uint VAR_IC_REARM_MAX = 4;

// The cached binding's slot. Valid only after the shape_id and recycle_epoch
// checks, which keep prop_idx current.
fn PropValue* VarICEntry.slot(&self) @inline {
    HObject* b = (HObject*)self.bindings;
    PropValue* values = b.prop_alloc != null ? (PropValue*)b.prop_alloc : (PropValue*)((char*)b + self.props_off);
    return &values[self.prop_idx];
}

// Populate a variable IC entry, writing every guard field together: readers
// compare shape_id, recycle_epoch and search_head, and a partial fill can leave
// a previous occupant's stale value looking valid. An entry belongs to one
// instruction, so the name it was filled for never changes.
fn void var_ic_fill(VarICEntry* vic, void* env, void* bindings, uint shape_id,
                    uint prop_idx, void* search_head, bool store_ok, heap::Heap* h) {
    vic.env = env;
    vic.bindings = bindings;
    vic.shape_id = shape_id;
    vic.prop_idx = prop_idx;
    vic.prop_flags = bindings != null ? ((HObject*)bindings).get_prop_flags(prop_idx, h) : (PropFlags){};
    vic.recycle_epoch = h.shape_recycle_epoch;
    vic.props_off = bindings != null
        ? (uint)((char*)((HObject*)bindings).inline_props_ptr() - (char*)bindings) : 0;
    vic.search_head = search_head;
    vic.varref_store_ok = store_ok;
    vic.rearm_depth = VAR_IC_NO_REARM;
    vic.slot_ptr = null;
    h.var_ic_filled = true;
    if (bindings != null) {
        ((HObject*)bindings).gc.ic_bound = true;
        vic.slot_ptr = vic.slot();
        if (vic.prop_flags.is_accessor) var_ic_alias_import(vic, h);
    }
}

// Set by builtins: the builtin index of the module import getter. A live
// import is an accessor whose getter reads one binding of the exporting
// module's environment, named by these two internal slots.
tlocal int module_getter_index = -1;
const char[] MODULE_BINDING_ENV_SLOT = "\xFFmoduleBindingEnv";
const char[] MODULE_BINDING_KEY_SLOT = "\xFFmoduleBindingKey";

// Retarget an entry filled on a live import binding at the exporter's own data
// slot, following re-export chains. The import itself is immutable, so the
// entry is marked read-only: stores and updates fall back to the full path,
// which throws. `env` keeps the importer's record, which owns the reference.
// The exporter's bindings become ic_bound, so a layout move there
// advances the epoch that guards every hit.
fn void var_ic_alias_import(VarICEntry* vic, heap::Heap* h) {
    if (module_getter_index < 0) return;
    void* env_key = (void*)h.str_intern(MODULE_BINDING_ENV_SLOT);
    void* name_key = (void*)h.str_intern(MODULE_BINDING_KEY_SLOT);
    if (env_key == null || name_key == null) return;
    for (int depth = 0; depth < 8; depth++) {
        TVal acc = vic.slot_ptr.get();
        if (!acc.is_object()) return;
        TVal getter = hobject_access_getter(acc);
        if (!getter.is_object()) return;
        HObject* g = (HObject*)getter.get_heapptr();
        if (g.get_class() != ObjClass.FUNCTION
            || (*g.extra_ptr()).func.builtin_fn_index != module_getter_index) return;
        int ei = g.find_prop_idx(env_key, h);
        int ki = g.find_prop_idx(name_key, h);
        if (ei < 0 || ki < 0) return;
        TVal env_tv = g.prop_values()[ei].get();
        TVal key_tv = g.prop_values()[ki].get();
        if (!env_tv.is_object() || !key_tv.is_string()) return;
        HObject* src = (HObject*)env_tv.get_heapptr();
        int idx = src.find_prop_idx(key_tv.get_heapptr(), h);
        if (idx < 0) return;
        vic.bindings = src;
        vic.shape_id = src.shape_id;
        vic.prop_idx = (uint)idx;
        vic.prop_flags = src.get_prop_flags((uint)idx, h);
        vic.props_off = (uint)((char*)src.inline_props_ptr() - (char*)src);
        src.gc.ic_bound = true;
        vic.slot_ptr = vic.slot();
        vic.prop_flags.writable = false;
        if (!vic.prop_flags.is_accessor) return;
    }
    vic.slot_ptr = null;
}

// Clear every field of a variable IC entry. Readers guard on bindings or
// search_head rather than env, so clearing only env would leave a stale pointer
// that a later lookup dereferences.
fn void var_ic_clear(VarICEntry* vic) {
    vic.env = null;
    vic.bindings = null;
    vic.shape_id = 0;
    vic.prop_idx = 0;
    vic.prop_flags = {};
    vic.recycle_epoch = 0;
    vic.props_off = 0;
    vic.search_head = null;
    vic.varref_store_ok = false;
    vic.slot_ptr = null;
}

// True when the megamorphic cache may answer a getter lookup of `key` on this
// receiver. A hit reports straight from the property table, so excluded are
// proxies ([[Get]] runs a trap), arguments objects, and string wrappers
// (indexed keys are read from the primitive by the caller). An exotic array
// answers `length` from array_len_ptr and indexed keys from its dense part, so
// only the other keys are served from the table.
//
// The same test gates storing.
macro bool HObject.mega_cacheable(&self, void* key, heap::Heap* h) {
    if (self.is_proxy() || self.flags.exotic_stringobj || self.get_class() == ObjClass.ARGUMENTS) return false;
    return !self.flags.exotic_array
        || (key != null && !((hstring::HString*)key).is_arridx() && key != (void*)h.strs[heap::BuiltinStr.LENGTH]);
}

// Evaluates `cur`'s module if it is a deferred module namespace object (import
// defer) searched with a triggering key. Called from each prototype-chain walk,
// so `Object.create(ns).x`, `key in Object.create(ns)` and `super.x` through a
// namespace all see live bindings rather than TDZ ones.
//
// The trigger goes through a heap hook for the same reason the proxy cases in
// those walks do: hobject cannot depend on the module subsystem. Symbol and
// "then" keys are exempt, and the flag clears once forced, so the common path
// is a single predictable branch per hop.
//
// Returns false only when evaluation threw; the error is on the heap channel.
fn bool force_deferred_ns_on_chain(HObject* cur, void* key, heap::Heap* h) @inline {
    if (!cur.flags.exotic_deferred_ns) return true;
    if (h.force_deferred_ns_fn == null || h.vm_ptr == null) return true;
    hstring::HString* ks = (hstring::HString*)key;
    if (ks == null || ks.is_symbol() || ks.equals("then")) return true;
    return h.force_deferred_ns_fn(h, h.vm_ptr, cur);
}

// Walk the prototype chain once, returning whichever of an accessor or a data
// property is found first, along with its owner.
//
// Every full Get in the engine funnels through here: the VM's GETPROP slow
// path, builtins' spec-mandated Gets, and the coercion helpers. The megamorphic
// cache is probed here so all call sites share one invalidation story.
fn PropLookupResult HObject.get_prop_or_accessor_proto(&self, void* key, bool want_getter, heap::Heap* h,
                                                          TVal* recv_override = null) {
    HObject* cur = self;
    uint depth = 0;

    if (want_getter && self.mega_cacheable(key, h)) {
        MegamorphicEntry* me;
        PropValue* cached = mega_cache_lookup(h, self, key, &me);
        if (cached != null) {
            if (me.is_accessor) {
                return {
                    .kind = PropLookupKind.PROP_ACCESSOR,
                    .owner = me.proto == null ? self : (HObject*)me.proto,
                    .acc = {
                        .accessor_fn = hobject_access_getter(cached.get()),
                        .this_obj = self,
                        .found = true
                    }
                };
            }
            return {
                .kind = PropLookupKind.PROP_DATA,
                .data_val = cached.get(),
                .owner = me.proto == null ? self : (HObject*)me.proto
            };
        }
    }

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        if (!force_deferred_ns_on_chain(cur, key, h)) {
            return { .kind = PropLookupKind.PROP_NOT_FOUND };
        }
        // A proxy on the chain runs a getter search through the trap machinery
        // and reports the result as a data property with no owner, which keeps
        // inline caches from being populated. A setter search returns
        // PROP_NOT_FOUND, since PUTPROP's own proxy check handles [[Set]].
        if (cur.is_proxy() && want_getter) {
            if (h.proxy_get_fn != null && h.vm_ptr != null) {
                // Pass the property access's receiver to the [[Get]] trap: for
                // a primitive receiver the trap must see the primitive, not
                // the wrapper prototype the walk started from (ECMA-262 GetV
                // and OrdinaryGet). recv_override carries the
                // primitive when the caller is primitive_getprop; otherwise
                // (e.g. object.[[Get]]) self is the receiver.
                TVal recv = recv_override != null ? *recv_override : types::make_object(self);
                TVal out;
                if (h.proxy_get_fn(h.vm_ptr, h, cur, key, recv, &out)) {
                    return { .kind = PropLookupKind.PROP_DATA, .data_val = out, .owner = null };
                }
            }
            return { .kind = PropLookupKind.PROP_NOT_FOUND };
        }
        if (cur.is_proxy() && !want_getter) {
            return { .kind = PropLookupKind.PROP_NOT_FOUND };
        }
        int idx = cur.find_prop_idx(key, h);
        if (idx >= 0) {
            if (cur.get_prop_flags((uint)idx, h).is_accessor) {
                TVal gs_slot = cur.prop_values()[idx].get();
                TVal accessor_fn = want_getter ? hobject_access_getter(gs_slot) : hobject_access_setter(gs_slot);
                if (want_getter && depth <= 1 && self.mega_cacheable(key, h)) {
                    mega_cache_store(h, self, key, cur, idx, true);
                }
                return {
                    .kind = PropLookupKind.PROP_ACCESSOR,
                    .owner = cur,
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
            if (want_getter && depth <= 1 && self.mega_cacheable(key, h)) {
                mega_cache_store(h, self, key, cur, idx, false);
            }
            return {
                .kind = PropLookupKind.PROP_DATA,
                .data_val = cur.prop_values()[idx].get(),
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
        if (!force_deferred_ns_on_chain(cur, key, h)) return false;
        // Proxy exotic on the chain: route through the [[Has]] trap.
        if (cur.is_proxy()) {
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

// Result of a prototype-chain property lookup, returned by
// get_prop_proto_full. The caller must check `found` before reading
// `value` / `is_accessor` / `owner`.
struct PropProtoResult {
    bool found;
    TVal value;
    bool is_accessor;
    HObject* owner;
}

// Walk the prototype chain looking for a named property. Returns whether
// the property exists anywhere, the slot value (or accessor boxed pair),
// whether the slot is an accessor, and the object that owns the slot —
// the latter is what `with`-env reads pass as `this` to a getter.
fn PropProtoResult HObject.get_prop_proto_full(&self, void* key, heap::Heap* h) {
    PropProtoResult result;
    result.found = false;
    result.value = types::make_undefined();
    result.is_accessor = false;
    result.owner = null;
    HObject* cur = self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        if (cur.is_proxy()) {
            // Proxy exotic anywhere on the chain: route [[Get]] through
            // the trap machinery (receiver = the original object). The
            // owner stays the with object so a getter sees it as `this`.
            if (h.proxy_get_fn != null && h.vm_ptr != null) {
                TVal recv = types::make_object(self);
                TVal out;
                if (h.proxy_get_fn(h.vm_ptr, h, cur, key, recv, &out)) {
                    result.found = true;
                    result.value = out;
                    result.owner = self;
                    return result;
                }
            }
            return result;
        }
        int idx = cur.find_prop_idx(key, h);
        if (idx >= 0) {
            result.found = true;
            result.value = cur.prop_values()[idx].get();
            result.is_accessor = cur.get_prop_flags((uint)idx, h).is_accessor;
            result.owner = cur;
            return result;
        }
        // ARRAY exotic: "length" lives in array_len_ptr, not the named table
        // (mirrors has_prop_proto and the VM's GETPROP). Without this a
        // `with`-env read of an inherited array length misses the binding.
        if (cur.get_class() == ObjClass.ARRAY
            && key == (void*)h.strs[heap::BuiltinStr.LENGTH]) {
            result.found = true;
            result.value.set_fastint((long)*cur.array_len_ptr());
            result.is_accessor = false;
            result.owner = cur;
            return result;
        }
        cur = cur.prototype;
        depth++;
    }

    return result;
}

// Returns true if `probe` appears in the prototype chain of `self`, starting
// at `self`'s prototype, so `self` itself never matches (ECMA-262
// Object.prototype.isPrototypeOf).
fn bool HObject.is_prototype_of(&self, HObject* probe) {
    HObject* cur = self.prototype;
    uint depth = 0;
    while (cur != null && depth < MAX_PROTO_DEPTH) {
        if (cur == probe) return true;
        cur = cur.prototype;
        depth++;
    }
    return false;
}

// [[Delete]] of an own property (ECMA-262 ordinary [[Delete]]).
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
    // String exotic objects: char indices [0, char_length) are virtual
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
    if (key != null && self.is_indexed_exotic()) {
        HString* hkey = (HString*)key;
        if (hkey.is_arridx()) {
            uint ai = (uint)hkey.array_index();
            if (ai < self.array_size) {
                TVal old = self.array_part()[ai].get();
                if (!old.is_undefined()) {
                    TVal undef; undef.set_undefined();
                    self.set_array_idx(ai, undef, h);
                }
            }
        } else if (self.get_class() == hobject::ObjClass.ARRAY) {
            // ARRAY "length" is a non-configurable own property (ECMA-262 Array
            // exotic objects), so [[Delete]] returns false for it. That keeps
            // `delete Array.prototype.length` and similar failing.
            if (hkey.equals("length")) {
                return false;
            }
        }
    }
    return true;  // Not found (or cleared from dense) → [[Delete]] returns true.
}

macro bool HObject.is_proxy(&self) {
    $if !features::PROXY:
        return false;
    $else
        return self.flags.exotic_proxyobj;
    $endif
}
