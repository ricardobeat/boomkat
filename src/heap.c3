module duktape::heap;

import duktape::types;
import duktape::hstring;
import duktape::hobject;
import duktape::bytecode;
import std::io;
import libc;

// ============================================================================
// Heap management — allocator, GC bookkeeping, string table
// ============================================================================

// --- Allocator callback signatures ----------------------------------------

alias AllocFunc   = fn void*(void* udata, usz size);
alias ReallocFunc = fn void*(void* udata, void* ptr, usz size);
alias FreeFunc    = fn void(void* udata, void* ptr);
alias FatalFunc   = fn void(void* udata, char* msg);

/// Function pointer type for calling a JS handler function from builtins.
/// Takes an opaque VM pointer, the handler TVal, an argument TVal pointer.
/// Returns the result TVal.
alias VmCallHandlerFn = fn TVal(void* vm, TVal handler, TVal* arg);
/// Callback to mark activation-record env bindings during GC mark phase.
alias MarkActivationsFn = fn void(void* vm, void* heap);

/// Callback invoked after a microtask handler completes.  Receives the heap,
/// VM, handler return value, and the downstream promise to resolve.
alias MicrotaskAfterFn = fn void(void* heap, void* vm, TVal result, TVal downstream);

/// Function pointer type for calling a JS function with multiple arguments.
/// Takes an opaque VM pointer, the function TVal, args array, arg count, and this TVal.
/// Returns the result TVal.
alias VmCallFn = fn TVal(void* vm, TVal func, TVal* args, uint nargs, TVal this_val);

// --- Faults ---------------------------------------------------------------

faultdef HEAP_ALLOC_FAULT;

// --- Constants ------------------------------------------------------------

const uint  INITIAL_STR_TABLE_SIZE  = 256;
const float STR_TABLE_LOAD_FACTOR   = 0.70;
const long  GC_INITIAL_TRIGGER      = 1024;
/// Sentinel refcount for strings that must never be freed (builtins, symbols).
/// Large enough that decref can never decrement it to zero in practice.
const uint  STRING_PINNED_REFCOUNT  = 0x7FFF_FFFF;
const long  GC_TRIGGER_GROW_FACTOR  = 2;
const long  GC_MAX_TRIGGER          = 4096;
/// Initial capacity for the gray object stack (grows as needed).
const uint  GRAY_STACK_INITIAL_CAP  = 64;
const usz   STRS_CACHE_SIZE         = 256;
const uint  GC_MAX_ROOTS            = 16;

// --- LongjmpState ---------------------------------------------------------

enum LjType : char {
    UNKNOWN,
    THROW,
    YIELD,
    RESUME,
    BREAK,
    CONTINUE,
    RETURN,
    NORMAL,
}

struct LongjmpState {
    LjType   lj_type;
    TVal     value1;
    TVal     value2;
    bool     iserror;
}

// --- GeneratorState (ES6 §25.3) -------------------------------------------

/// Generator execution state per ES6 §25.3.3.1 GeneratorState.
enum GeneratorStateType : char {
    GEN_SUSPENDED_START,
    GEN_SUSPENDED_YIELD,
    GEN_EXECUTING,
    GEN_COMPLETED,
}

/// How a generator was resumed — determines what the YIELD opcode does
/// when execution reaches a yield point.
enum ResumeKind : char {
    NEXT,     /// .next() — yield returns IteratorResult as usual
    THROW,    /// .throw() — inject exception at yield point
    RETURN,   /// .return() — inject return at yield point
}

/// Saved execution context for a generator.
///
/// When a generator function is called, instead of executing the body
/// immediately, the VM saves the initial execution state in this struct
/// and returns a generator object.  Subsequent calls to .next(), .throw(),
/// or .return() resume execution from the saved state.
struct GeneratorState {
    GeneratorStateType state;
    void* func;               // CompiledFunction* (opaque to avoid circular deps)
    TVal* saved_regs;         // malloc'd array of register values
    uint num_regs;
    void* saved_pc;           // Instruction* (opaque)
    void* var_env;            // EnvRecord* (opaque)
    void* lex_env;            // EnvRecord* (opaque)
    void* cat;                // Catcher* chain head (opaque) — saved across yields
    TVal this_binding;
    TVal resume_value;        // value passed by .next()
    ResumeKind resume_kind;   // how the generator was resumed
    TVal throw_value;         // exception to inject (when resume_kind == THROW)
    TVal return_value;        // value to return (when resume_kind == RETURN)
    // yield* delegation state
    void* delegated_iter;     // HObject* — iterator being delegated to
    uint delegated_index;     // current index in delegation loop
}

// --- Heap struct ----------------------------------------------------------

struct Heap {
    // Allocator callbacks
    AllocFunc    alloc_func;
    ReallocFunc  realloc_func;
    FreeFunc     free_func;
    void*        heap_udata;
    FatalFunc    fatal_func;

    // Flags
    uint flags;

    // Object lists (doubly-linked via HeapHeader.next/.prev)
    HeapHeader*  heap_allocated;
    HeapHeader*  finalize_list;

    // String interning table (open-addressing)
    HString**    str_table;
    uint         str_table_size;
    uint         str_table_used;

    // Built-in strings cache (indexed by string constant IDs)
    void*[STRS_CACHE_SIZE]  strs;

    // GC state
    long  gc_trigger_counter;
    uint  live_obj_count;
    uint  peak_live_obj_count;   /// High-water mark for live objects

    // Gray set for iterative mark — dynamic array of HObject* pointers.
    // Avoids C-stack overflow on deep object graphs.
    void** gray_objects;
    uint   gray_count;
    uint   gray_capacity;

    // Current execution thread (HThread*)
    void* curr_thread;

    // Longjmp state for error handling
    LongjmpState lj;

    // Error flag: set by the VM when an unhandled throw occurs.
    // Cleared before each top-level call. Checked by builtins (e.g. JSON)
    // that call back into JS and need to detect errors from call_fn.
    bool has_error;
    TVal error_value;

    // Simple xorshift32 PRNG state
    uint rnd_state;

    // Fixed hash seed (set at heap creation, never changes)
    uint hash_seed;

    // Built-in error prototypes (for builtin constructor dispatch)
    HObject* err_proto;
    HObject* type_err_proto;
    HObject* range_err_proto;
    HObject* ref_err_proto;
    HObject* syntax_err_proto;
    HObject* eval_err_proto;
    HObject* uri_err_proto;
    HObject* aggregate_err_proto;

    // Built-in constructor prototypes
    HObject* object_proto;
    HObject* bool_proto;
    HObject* string_proto;
    HObject* number_proto;
    HObject* array_proto;
    HObject* function_proto;
    HObject* date_proto;
    HObject* regexp_proto;
    HObject* map_proto;
    HObject* set_proto;
    HObject* weakmap_proto;
    HObject* weakset_proto;
    HObject* symbol_proto;
    HObject* promise_proto;
    HObject* generator_proto;
    HObject* iterator_proto;   // %IteratorPrototype% (ES6 §25.1.2)

    // Generator resume state (set by .next()/.throw()/.return() builtins,
    // read by the VM CALL handler and YIELD/RET opcodes).
    GeneratorState* resume_gen;
    TVal yield_value;          /// Value yielded by YIELD opcode
    bool did_yield;            /// True when YIELD was just executed

    // Global symbol registry for Symbol.for / Symbol.keyFor
    HString** symbol_registry_keys;   /// Array of key HString* pointers
    HString** symbol_registry_syms;   /// Array of symbol HString* pointers
    uint      symbol_registry_count;  /// Number of entries
    uint      symbol_registry_cap;    /// Allocated capacity

    // Global checkpoint for __resetGlobals() — saves initial global state
    void**    checkpoint_keys;   /// Array of HString* pointers
    TVal*     checkpoint_vals;   /// Parallel array of TVal values
    uint      checkpoint_count;  /// Number of saved entries
    uint      checkpoint_cap;    /// Allocated capacity

    // Environment record pool — freelist of EnvRecord nodes
    void*     env_freelist;     /// EnvRecord* freelist (chains via .parent)
    void*     env_pool_blocks;  /// EnvPoolBlock* linked list for cleanup

    // CompiledFunction tracking — growable array of all CompiledFunction*
    // allocated through the compiler.  Freed in Heap.destroy.
    void**    compiled_funcs;    /// Array of CompiledFunction* pointers
    uint      compiled_func_cap; /// Allocated capacity
    uint      compiled_func_count; /// Number of tracked entries

    // GC root registration (pointers to always-reachable HeapHeader*)
    void*[GC_MAX_ROOTS] gc_roots;
    uint                gc_root_count;

    // VM valstack pointers for GC root scanning.
    // valstack_base is updated on VM create / resize.
    // valstack_top_ptr is a pointer to vm.valstack_top so GC always
    // reads the current value (no sync needed on push/pop).
    TVal*      valstack_base;    /// VM's valstack base pointer
    TVal**     valstack_top_ptr; /// Points to vm.valstack_top

    // GC re-entrancy guard
    bool                gc_running;

    // VM callback for calling JS functions from builtins (set by vm_create)
    VmCallHandlerFn     call_handler_fn;
    VmCallFn            call_fn;
    /// Callback to mark activation-record env bindings during GC (set by vm_create).
    MarkActivationsFn   mark_activations_fn;

    // Cached iterator symbol (lazily created, rooted via this field).
    HString*            iterator_symbol;

    // Cached Symbol.toPrimitive (lazily created, rooted via this field).
    HString*            toprimitive_symbol;

    // Microtask completion callback (set by builtins init, resolves downstream promises)
    MicrotaskAfterFn    microtask_after_fn;

    // Promise resolve/reject target stack (synchronous executor calls only).
    // Before calling a Promise executor, push the target promise; resolve/reject
    // lightfuncs read from the top; pop after the executor returns.
    HObject**  promise_resolve_stack;
    uint       promise_resolve_top;
    uint       promise_resolve_cap;

    // Microtask queue — enqueued by promise_trigger_reactions, drained after
    // each top-level script execution and after vm_call_fn_impl returns.
    // Each entry is 3 TVal slots: [handler, arg, downstream].
    // downstream is the promise to resolve with the handler's return value (or undefined).
    TVal*     microtask_queue;
    uint      microtask_count;
    uint      microtask_capacity;
    bool      microtask_draining;  // re-entrancy guard

    // Shape (hidden class) system for inline cache support.
    hobject::Shape**    shapes;       // pointer array — each element points to a shape allocation
    uint                shape_count;
    uint                shape_capacity;
    uint                shape_gen;

    // Shape transition deduplication table.
    // Maps (parent_shape_id, key_pointer) → child_shape_id so that two
    // objects following the same property-addition path share one Shape.
    TransitionEntry*    trans_table;
    uint                trans_mask;   // table has mask+1 entries
    uint                trans_count;
}

// ============================================================================
// Built-in string cache — pre-interned at heap creation
// ============================================================================

/// Indices into Heap.strs[] for frequently-used interned strings.
/// Eliminates repeated hash+lookup for these strings on every property
/// access, typeof, and error path.
enum BuiltinStr : uint {
    UNDEFINED,   // "undefined"
    OBJECT,      // "object"
    BOOLEAN,     // "boolean"
    NUMBER,      // "number"
    STRING,      // "string"
    FUNCTION,    // "function"
    TRUE,        // "true"
    FALSE,       // "false"
    NULL_STR,    // "null"
    MESSAGE,     // "message"
    PROTOTYPE,   // "prototype"
    CONSTRUCTOR, // "constructor"
    LENGTH,      // "length"
    VALUE,       // "value"
    DONE,        // "done"
    ARGUMENTS,   // "arguments"
    SYMBOL,      // "symbol"
    NAME,        // "name"
    EMPTY,       // ""
    NAN_STR,     // "NaN"
    POSITIVE_INFINITY, // "Infinity"
    NEGATIVE_INFINITY, // "-Infinity"
}

// ============================================================================
// Default allocator functions (libc-backed)
// ============================================================================

fn void* default_alloc(void* udata, usz size) {
    if (size == 0) { return null; }
    return libc::malloc(size);
}

fn void* default_realloc(void* udata, void* ptr, usz size) {
    if (size == 0) {
        libc::free(ptr);
        return null;
    }
    return libc::realloc(ptr, size);
}

fn void default_free(void* udata, void* ptr) {
    libc::free(ptr);
}

fn void default_fatal(void* udata, char* msg) {
    io::eprintfn("DUKTAPE FATAL: %s", msg);
    libc::abort();
}

// ============================================================================
// Heap creation / destruction
// ============================================================================

/**
 * Allocate and initialise a brand-new Heap.
 *
 * If any allocator callback is `null` the corresponding default (libc)
 * version is used.  Returns a fault on allocation failure.
 */
fn Heap*? create(
    AllocFunc    a,
    ReallocFunc  r,
    FreeFunc     f,
    void*        udata,
    FatalFunc    fatal
) {
    // Resolve defaults
    AllocFunc   afn   = a     != null ? a     : &default_alloc;
    ReallocFunc rfn   = r     != null ? r     : &default_realloc;
    FreeFunc    ffn   = f     != null ? f     : &default_free;
    FatalFunc   fatfn = fatal != null ? fatal : &default_fatal;

    // Allocate the Heap struct itself through the chosen allocator
    void* raw = afn(udata, Heap::size);
    if (raw == null) {
        return HEAP_ALLOC_FAULT~;
    }

    Heap* h = (Heap*)raw;

    // Zero-fill the whole struct
    libc::memset(raw, 0, Heap::size);

    // Store allocator pointers
    h.alloc_func   = afn;
    h.realloc_func = rfn;
    h.free_func    = ffn;
    h.heap_udata   = udata;
    h.fatal_func   = fatfn;

    // GC tunables
    h.gc_trigger_counter    = GC_INITIAL_TRIGGER;

    // Allocate gray object stack
    void* gray_raw = afn(udata, void*::size * GRAY_STACK_INITIAL_CAP);
    if (gray_raw == null) {
        ffn(udata, raw);
        return HEAP_ALLOC_FAULT~;
    }
    h.gray_objects   = (void**)gray_raw;
    h.gray_count     = 0;
    h.gray_capacity  = GRAY_STACK_INITIAL_CAP;

    // PRNG seed (non-zero required for xorshift32)
    h.rnd_state = 0xDEAD_BEEF;

    // Fixed hash seed (never changes after creation)
    h.hash_seed = h.rnd_state;

    // Allocate the initial string table
    usz tbl_bytes = HString*::size * INITIAL_STR_TABLE_SIZE;
    void* tbl_raw = afn(udata, tbl_bytes);
    if (tbl_raw == null) {
        ffn(udata, raw);
        return HEAP_ALLOC_FAULT~;
    }
    libc::memset(tbl_raw, 0, tbl_bytes);

    h.str_table      = (HString**)tbl_raw;
    h.str_table_size = INITIAL_STR_TABLE_SIZE;
    h.str_table_used = 0;

    // Pre-intern well-known strings
    h.init_builtin_strs();

    // Initialize shape system
    h.init_shapes();

    // Allocate Promise resolve/reject target stack (16 slots initial)
    h.promise_resolve_cap = 16;
    h.promise_resolve_stack = (HObject**)afn(udata, HObject*::size * 16);
    if (h.promise_resolve_stack != null) {
        libc::memset(h.promise_resolve_stack, 0, HObject*::size * 16);
    }
    h.promise_resolve_top = 0;

    // Allocate microtask queue (32 entries initial = 16 handler+arg pairs)
    h.microtask_capacity = 16;
    h.microtask_queue = (TVal*)afn(udata, TVal::size * 32);
    if (h.microtask_queue != null) {
        libc::memset(h.microtask_queue, 0, TVal::size * 32);
    }
    h.microtask_count = 0;
    h.microtask_draining = false;

    return h;
}

/// Pre-intern frequently-used strings into Heap.strs[].
/// Called once during heap creation.  Each string is hashed, looked up in
/// the string table, and allocated only if not already present — so this
/// is safe to call multiple times.
fn void Heap.init_builtin_strs(&self) {
    // Each entry: (ZString literal, byte length)
    ZString[22] literals = {
        "undefined", "object", "boolean", "number", "string", "function",
        "true", "false", "null", "message", "prototype", "constructor",
        "length", "value", "done", "arguments", "symbol", "name", "",
        "NaN", "Infinity", "-Infinity"
    };
    uint[22] lengths = { 9, 6, 7, 6, 6, 8, 4, 5, 4, 7, 9, 11, 6, 5, 4, 9, 6, 4, 0, 3, 8, 9 };
    for (uint i = 0; i < 22; i++) {
        char* ptr = (char*)literals[i];
        char[] data = ptr[:lengths[i]];
        uint h = self.hash_string(data);
        HString* existing = self.str_table_lookup(data, h);
        if (existing != null) {
            self.strs[i] = existing;
        } else {
            HString*? ns = hstring::hstring_alloc(self, data, h);
            if (try s = ns) {
                self.str_table_insert(s);
                self.strs[i] = s;
            }
        }
        // Pin: builtin strings must never be freed by refcounting.
        if (self.strs[i] != null) {
            ((HeapHeader*)self.strs[i]).refcount = STRING_PINNED_REFCOUNT;
        }
    }
    // Cache the "length" pointer for HObject.put_prop array_length sync.
    hobject::builtin_length_key = self.strs[BuiltinStr.LENGTH];
}

// ============================================================================
// Shape (hidden class) system
// ============================================================================

const uint SHAPE_INITIAL_CAP   = 64;
const uint SHAPE_NONE          = 0xFFFF_FFFF;
const uint SHAPE_TRANS_INITIAL = 16;   // must be power of 2
const uint SHAPE_TRANS_LOAD    = 70;   // max load percentage before grow

struct TransitionEntry {
    uint parent_id;
    void* key;
    uint shape_id;
}

fn void Heap.init_transition_table(&self) {
    self.trans_mask = SHAPE_TRANS_INITIAL - 1;
    self.trans_count = 0;
    usz bytes = (usz)SHAPE_TRANS_INITIAL * TransitionEntry::size;
    self.trans_table = (TransitionEntry*)libc::malloc(bytes);
    libc::memset(self.trans_table, 0xFF, bytes);
}

fn uint hash_transition(uint parent_id, void* key) @inline {
    uint h = parent_id;
    h ^= (uint)((usz)key);
    h = ((h >> 16) ^ h) * 0x45D9_F3B;
    h = ((h >> 16) ^ h) * 0x45D9_F3B;
    h = (h >> 16) ^ h;
    return h;
}

fn uint Heap.lookup_transition(&self, uint parent_id, void* key) {
    uint h = hash_transition(parent_id, key);
    uint mask = self.trans_mask;
    uint slot = h & mask;
    TransitionEntry* table = self.trans_table;
    for (uint i = 0; i <= mask; i++) {
        TransitionEntry* e = &table[slot];
        if (e.parent_id == SHAPE_NONE) return SHAPE_NONE;
        if (e.parent_id == parent_id && e.key == key) return e.shape_id;
        slot = (slot + 1) & mask;
    }
    return SHAPE_NONE;
}

fn void Heap.transition_table_grow(&self) {
    uint old_mask = self.trans_mask;
    uint new_cap = (old_mask + 1) * 2;
    uint new_mask = new_cap - 1;
    usz bytes = (usz)new_cap * TransitionEntry::size;
    TransitionEntry* new_table = (TransitionEntry*)libc::malloc(bytes);
    libc::memset(new_table, 0xFF, bytes);
    TransitionEntry* old_table = self.trans_table;
    for (uint i = 0; i <= old_mask; i++) {
        TransitionEntry* e = &old_table[i];
        if (e.parent_id == SHAPE_NONE) continue;
        uint h = hash_transition(e.parent_id, e.key);
        uint slot = h & new_mask;
        while (new_table[slot].parent_id != SHAPE_NONE) slot = (slot + 1) & new_mask;
        new_table[slot] = *e;
    }
    libc::free(old_table);
    self.trans_table = new_table;
    self.trans_mask = new_mask;
}

fn void Heap.insert_transition(&self, uint parent_id, void* key, uint shape_id) {
    if ((self.trans_count + 1) * 100 > (self.trans_mask + 1) * SHAPE_TRANS_LOAD) {
        self.transition_table_grow();
    }
    uint h = hash_transition(parent_id, key);
    uint mask = self.trans_mask;
    uint slot = h & mask;
    TransitionEntry* table = self.trans_table;
    while (table[slot].parent_id != SHAPE_NONE) slot = (slot + 1) & mask;
    table[slot].parent_id = parent_id;
    table[slot].key = key;
    table[slot].shape_id = shape_id;
    self.trans_count++;
}

fn void Heap.init_shapes(&self) {
    self.shape_capacity = SHAPE_INITIAL_CAP;
    self.shape_count    = 1;  // slot 0 = root shape
    self.shape_gen      = 0;
    // Allocate pointer array
    usz bytes = (usz)SHAPE_INITIAL_CAP * (void*::size);
    self.shapes = (hobject::Shape**)libc::malloc(bytes);
    libc::memset(self.shapes, 0, bytes);
    // Allocate root shape: 0 properties, minimum hash (mask=0 → 2 slots)
    self.shapes[0] = hobject::shape_create(0, SHAPE_NONE);
    // Init transition dedup table
    self.init_transition_table();
}

/// Allocate a new shape slot in the shapes array. Returns the new shape ID.
/// Does NOT initialize the shape pointer (caller must set shapes[id]).
fn uint Heap.alloc_shape_slot(&self) {
    if (self.shape_count >= self.shape_capacity) {
        uint new_cap = self.shape_capacity * 2;
        void* new_raw = libc::realloc(self.shapes, (usz)new_cap * (void*::size));
        if (new_raw == null) return SHAPE_NONE;
        // Zero new slots
        usz old_bytes = (usz)self.shape_capacity * (void*::size);
        libc::memset((char*)new_raw + old_bytes, 0, (usz)new_cap * (void*::size) - old_bytes);
        self.shapes = (hobject::Shape**)new_raw;
        self.shape_capacity = new_cap;
    }
    uint id = self.shape_count;
    self.shape_count++;
    return id;
}

fn uint hash_key_ptr(void* key) @inline {
    uint h = (uint)((usz)key);
    h ^= h >> 16; h *= 0x85EB_CA6B;
    h ^= h >> 13; h *= 0xC2B2_AE35;
    h ^= h >> 16;
    return h;
}

/// Transition to a new shape that includes the given property key.
///
/// If the current shape already has this key, returns the current shape
/// (the caller should update the existing slot).
///
/// Otherwise, creates a new shape that extends the current one:
/// copies all existing ShapeProperties and appends the new one.
fn uint Heap.transition_shape(&self, uint cur_shape_id, void* key) {
    if (cur_shape_id >= self.shape_count || self.shapes[cur_shape_id] == null) {
        return cur_shape_id;
    }

    hobject::Shape* cur = self.shapes[cur_shape_id];

    // If the key already exists in the shape, no transition needed.
    if (cur.find_prop_idx(key) >= 0) {
        return cur_shape_id;
    }

    // Check transition table for existing child shape.
    uint existing = self.lookup_transition(cur_shape_id, key);
    if (existing != SHAPE_NONE) {
        return existing;
    }

    // Allocate a new shape that extends the current one.
    hobject::Shape* ns = hobject::shape_extend(cur, cur_shape_id, key);
    if (ns == null) return cur_shape_id;

    uint new_id = self.alloc_shape_slot();
    if (new_id == SHAPE_NONE) {
        hobject::shape_free(ns, (void*)self);
        return cur_shape_id;
    }

    self.shapes[new_id] = ns;
    // Register this transition for future deduplication.
    self.insert_transition(cur_shape_id, key, new_id);
    return new_id;
}

fn void Heap.bump_shape_gen(&self, uint shape_id) {
    if (shape_id < self.shape_count && self.shapes[shape_id] != null) {
        self.shapes[shape_id].generation++;
        self.shape_gen++;
    }
}

/// Get a shape pointer by ID. Returns null if invalid.
fn hobject::Shape* Heap.get_shape(&self, uint shape_id) {
    if (shape_id >= self.shape_count) return null;
    return self.shapes[shape_id];
}

/**
 * Destroy the heap: walk every managed object and release it, then free
 * the heap struct itself.
 */
fn void Heap.destroy(&self) {
    // Free all objects through the heap_allocated linked list
    HeapHeader* cur = self.heap_allocated;
    while (cur != null) {
        HeapHeader* next = cur.next;
        if (cur.is_object()) {
            hobject::hobject_free((HObject*)cur);
        }
        cur = next;
    }
    self.heap_allocated = null;

    // Free EnvRecord pool blocks
    {
        void* b = self.env_pool_blocks;
        while (b != null) {
            void* next = *(void**)b;  // next pointer is first field
            libc::free(b);
            b = next;
        }
        self.env_pool_blocks = null;
        self.env_freelist = null;
    }

    // Free all tracked CompiledFunction objects and their sub-arrays.
    if (self.compiled_funcs != null) {
        for (uint i = 0; i < self.compiled_func_count; i++) {
            bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[i];
            if (cf != null) {
                if (cf.code != null) { libc::free(cf.code); }
                if (cf.constants != null) {
                    // Decref string (and object/buffer) constants before freeing the pool.
                    for (uint ci = 0; ci < cf.const_count; ci++) {
                        self.decref_tval(&cf.constants[ci]);
                    }
                    libc::free(cf.constants);
                }
                if (cf.inner_funcs != null) { libc::free(cf.inner_funcs); }
                if (cf.line_table != null) { libc::free(cf.line_table); }
                if (cf.ic_entries != null) {
                    // Decref cached key strings.
                    hobject::ICEntry* ics = (hobject::ICEntry*)cf.ic_entries;
                    for (uint ii = 0; ii < cf.ic_count; ii++) {
                        if (ics[ii].key != null) {
                            self.decref((HeapHeader*)ics[ii].key);
                            ics[ii].key = null;
                        }
                    }
                    libc::free(cf.ic_entries);
                }
                if (cf.var_ic_entries != null) {
                    hobject::VarICEntry* vics = (hobject::VarICEntry*)cf.var_ic_entries;
                    for (uint vi = 0; vi < cf.var_ic_count; vi++) {
                        if (vics[vi].key != null) {
                            self.decref((HeapHeader*)vics[vi].key);
                            vics[vi].key = null;
                        }
                    }
                    libc::free(cf.var_ic_entries);
                }
                libc::free(cf);
            }
        }
        libc::free(self.compiled_funcs);
        self.compiled_funcs = null;
    }

    // Free all interned HStrings via the string table (RC-managed; teardown frees directly).
    if (self.str_table != null) {
        for (uint i = 0; i < self.str_table_size; i++) {
            hstring::HString* s = self.str_table[i];
            if (s != null) {
                self.free_string(s);
                self.str_table[i] = null;
            }
        }
        self.free_func(self.heap_udata, self.str_table);
        self.str_table = null;
    }

    // Free microtask queue
    if (self.microtask_queue != null) {
        libc::free(self.microtask_queue);
        self.microtask_queue = null;
    }

    // Free gray stack
    if (self.gray_objects != null) {
        libc::free(self.gray_objects);
        self.gray_objects = null;
    }

    // Free promise resolve stack
    if (self.promise_resolve_stack != null) {
        libc::free(self.promise_resolve_stack);
        self.promise_resolve_stack = null;
    }

    // Free shape system
    if (self.trans_table != null) {
        libc::free(self.trans_table);
        self.trans_table = null;
    }
    if (self.shapes != null) {
        for (uint i = 0; i < self.shape_count; i++) {
            if (self.shapes[i] != null) {
                hobject::shape_free(self.shapes[i], null);
            }
        }
        libc::free(self.shapes);
        self.shapes = null;
    }

    // Finally free the Heap struct itself
    FreeFunc    ffn   = self.free_func;
    void*       udata = self.heap_udata;
    ffn(udata, self);
}

/**
 * Reset the heap to a clean state without freeing the heap struct itself.
 * Frees all GC objects, compiled functions, interned strings, symbol registry,
 * and checkpoint data. Reinitialises the string table and builtin string cache
 * in-place, reusing existing backing arrays where possible.
 *
 * After this call the heap is ready to host a fresh VM, with no memory from
 * the previous test run retained — avoiding the create/destroy churn that
 * causes allocator fragmentation and RSS bloat.
 */
fn void Heap.reset(&self) {
    // Free all tracked HObjects via heap_allocated linked list
    HeapHeader* cur = self.heap_allocated;
    while (cur != null) {
        HeapHeader* next = cur.next;
        if (cur.is_object()) {
            hobject::hobject_free((HObject*)cur);
        }
        cur = next;
    }
    self.heap_allocated = null;

    // Free all tracked CompiledFunctions
    for (uint i = 0; i < self.compiled_func_count; i++) {
        bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[i];
        if (cf != null) {
            if (cf.code != null) { libc::free(cf.code); }
            if (cf.constants != null) {
                for (uint ci = 0; ci < cf.const_count; ci++) {
                    self.decref_tval(&cf.constants[ci]);
                }
                libc::free(cf.constants);
            }
            if (cf.inner_funcs != null) { libc::free(cf.inner_funcs); }
            if (cf.line_table != null) { libc::free(cf.line_table); }
            if (cf.ic_entries != null) {
                hobject::ICEntry* ics = (hobject::ICEntry*)cf.ic_entries;
                for (uint ii = 0; ii < cf.ic_count; ii++) {
                    if (ics[ii].key != null) {
                        self.decref((HeapHeader*)ics[ii].key);
                        ics[ii].key = null;
                    }
                }
                libc::free(cf.ic_entries);
            }
            if (cf.var_ic_entries != null) {
                hobject::VarICEntry* vics = (hobject::VarICEntry*)cf.var_ic_entries;
                for (uint vi = 0; vi < cf.var_ic_count; vi++) {
                    if (vics[vi].key != null) {
                        self.decref((HeapHeader*)vics[vi].key);
                        vics[vi].key = null;
                    }
                }
                libc::free(cf.var_ic_entries);
            }
            libc::free(cf);
        }
    }
    self.compiled_func_count = 0;
    // Keep compiled_funcs array allocated — just reset the count

    // Free all interned HStrings via str_table and reset (strings are RC-managed).
    if (self.str_table != null) {
        for (uint i = 0; i < self.str_table_size; i++) {
            hstring::HString* s = self.str_table[i];
            if (s != null) {
                self.free_string(s);
                self.str_table[i] = null;
            }
        }
        // Shrink if it grew very large
        if (self.str_table_size > INITIAL_STR_TABLE_SIZE * 8) {
            self.free_func(self.heap_udata, self.str_table);
            usz tbl_bytes = HString*::size * INITIAL_STR_TABLE_SIZE;
            void* new_tbl = self.alloc_func(self.heap_udata, tbl_bytes);
            if (new_tbl != null) {
                libc::memset(new_tbl, 0, tbl_bytes);
                self.str_table      = (HString**)new_tbl;
                self.str_table_size = INITIAL_STR_TABLE_SIZE;
            }
        }
        self.str_table_used = 0;
    }

    // Free symbol registry — decref all held string references first
    for (uint i = 0; i < self.symbol_registry_count; i++) {
        if (self.symbol_registry_keys[i] != null) {
            self.decref((HeapHeader*)self.symbol_registry_keys[i]);
        }
        if (self.symbol_registry_syms[i] != null) {
            self.decref((HeapHeader*)self.symbol_registry_syms[i]);
        }
    }
    if (self.symbol_registry_keys != null) {
        libc::free(self.symbol_registry_keys);
        self.symbol_registry_keys = null;
    }
    if (self.symbol_registry_syms != null) {
        libc::free(self.symbol_registry_syms);
        self.symbol_registry_syms = null;
    }
    self.symbol_registry_count = 0;
    self.symbol_registry_cap   = 0;

    // Free checkpoint state
    if (self.checkpoint_keys != null) {
        libc::free(self.checkpoint_keys);
        self.checkpoint_keys = null;
    }
    if (self.checkpoint_vals != null) {
        libc::free(self.checkpoint_vals);
        self.checkpoint_vals = null;
    }
    self.checkpoint_count = 0;
    self.checkpoint_cap   = 0;

    // Reset microtask queue (keep allocation, zero count)
    self.microtask_count    = 0;
    self.microtask_draining = false;

    // Clear all other heap state (prototypes, GC roots, execution state)
    self.heap_allocated   = null;
    self.finalize_list    = null;
    self.flags            = 0;
    self.curr_thread      = null;
    self.valstack_base    = null;
    self.valstack_top_ptr = null;
    self.resume_gen       = null;
    self.did_yield        = false;
    self.gc_root_count    = 0;
    self.gc_running       = false;
    self.gc_trigger_counter = GC_INITIAL_TRIGGER;
    self.gray_count       = 0;

    // Clear builtin prototype pointers
    self.err_proto        = null;
    self.type_err_proto   = null;
    self.range_err_proto  = null;
    self.ref_err_proto    = null;
    self.syntax_err_proto = null;
    self.eval_err_proto   = null;
    self.uri_err_proto    = null;
    self.aggregate_err_proto = null;
    self.object_proto     = null;
    self.bool_proto       = null;
    self.string_proto     = null;
    self.number_proto     = null;
    self.array_proto      = null;
    self.function_proto   = null;
    self.date_proto       = null;
    self.regexp_proto     = null;
    self.map_proto        = null;
    self.set_proto        = null;
    self.weakmap_proto    = null;
    self.weakset_proto    = null;
    self.symbol_proto     = null;
    self.promise_proto    = null;
    self.generator_proto  = null;
    self.iterator_proto   = null;

    // Clear builtin string cache
    for (usz i = 0; i < STRS_CACHE_SIZE; i++) {
        self.strs[i] = null;
    }

    // Clear longjmp state
    self.lj.lj_type = LjType.UNKNOWN;
    self.lj.iserror = false;

    // Reset shape system — free all shapes and transition table, then reinit
    if (self.trans_table != null) {
        libc::free(self.trans_table);
        self.trans_table = null;
    }
    if (self.shapes != null) {
        for (uint i = 0; i < self.shape_count; i++) {
            if (self.shapes[i] != null) {
                hobject::shape_free(self.shapes[i], null);
            }
        }
        // Reuse the pointer array, just zero it
        libc::memset(self.shapes, 0, (usz)self.shape_capacity * (void*::size));
    }
    self.shape_count = 1;
    self.shape_gen   = 0;
    self.shapes[0]   = hobject::shape_create(0, SHAPE_NONE);
    self.init_transition_table();

    // Reintern builtin strings into the now-empty string table
    self.init_builtin_strs();
}

// ============================================================================
// CompiledFunction tracking
// ============================================================================

/**
 * Register a CompiledFunction* for cleanup when the heap is destroyed.
 * The compiler allocates CompiledFunctions via libc::malloc and they are not
 * tracked by the GC object array, so we need a separate list.
 */
fn void Heap.track_compiled_func(&self, void* cf) {
    if (cf == null) { return; }
    if (self.compiled_func_count >= self.compiled_func_cap) {
        uint new_cap = self.compiled_func_cap == 0 ? 64 : self.compiled_func_cap * 2;
        usz new_bytes = (usz)new_cap * void*::size;
        void* new_arr = libc::realloc(self.compiled_funcs, new_bytes);
        if (new_arr == null) { return; }
        self.compiled_funcs = (void**)new_arr;
        self.compiled_func_cap = new_cap;
    }
    self.compiled_funcs[self.compiled_func_count] = cf;
    self.compiled_func_count++;
}

// ============================================================================
// Low-level allocation with GC trigger
// ============================================================================

/**
 * Allocate `size` bytes through the heap's allocator.  Decrements the GC
 * trigger counter and fires a collection when it reaches zero.
 */
fn void*? Heap.alloc(&self, usz size) {
    self.gc_trigger_counter--;
    if (self.gc_trigger_counter <= 0) {
        self.trigger_gc();
    }

    void* ptr = self.alloc_func(self.heap_udata, size);
    if (ptr == null && size > 0) {
        // Emergency GC then retry once
        self.trigger_gc();
        ptr = self.alloc_func(self.heap_udata, size);
        if (ptr == null) {
            return HEAP_ALLOC_FAULT~;
        }
    }
    return ptr;
}

/**
 * Allocate a new HObject and register it with the heap's GC tracking list.
 *
 * This is the preferred way to create objects — it replaces raw calls to
 * hobject::hobject_alloc() by also inserting the object into the
 * heap_allocated list so that the mark-and-sweep collector can find it.
 *
 * Returns the new HObject or a fault on allocation failure.
 */
fn HObject*? Heap.alloc_object(&self, hobject::ObjClass cls) {
    HObject*? result = hobject::hobject_alloc((void*)self, cls);
    if (try obj = result) {
        // Insert into the heap_allocated linked list (preserving flags
        // already set by hobject_alloc).
        self.insert_into_heap_allocated_preserve_flags((HeapHeader*)obj);
        self.live_obj_count++;
        if (self.live_obj_count > self.peak_live_obj_count) {
            self.peak_live_obj_count = self.live_obj_count;
        }
    }
    return result;
}

/**
 * Reallocate a block through the heap's allocator, with GC trigger.
 */
fn void*? Heap.realloc(&self, void* ptr, usz new_size) {
    self.gc_trigger_counter--;
    if (self.gc_trigger_counter <= 0) {
        self.trigger_gc();
    }

    void* new_ptr = self.realloc_func(self.heap_udata, ptr, new_size);
    if (new_ptr == null && new_size > 0) {
        self.trigger_gc();
        new_ptr = self.realloc_func(self.heap_udata, ptr, new_size);
        if (new_ptr == null) {
            return HEAP_ALLOC_FAULT~;
        }
    }
    return new_ptr;
}

/**
 * Free a block through the heap's allocator.
 */
fn void Heap.free(&self, void* ptr) {
    self.free_func(self.heap_udata, ptr);
}

/**
 * Free an HString through the heap's allocator (matches Heap.alloc).
 */
fn void Heap.free_string(&self, hstring::HString* s) {
    if (s == null) { return; }
    self.free_func(self.heap_udata, s);
}

// ============================================================================
// Reference counting — decref + free when count reaches zero
// ============================================================================

/**
 * Decrement the reference count of a heap-allocated object or buffer.
 * When the count reaches zero the object is unlinked from the
 * heap_allocated list and freed.
 *
 * Strings are reference-counted: when a string's refcount reaches zero it is
 * removed from the intern table and freed immediately.  Strings cannot form
 * cycles so no cycle collector is needed for them.
 *
 * Objects freed here are NOT visited by the subsequent mark-and-sweep
 * sweep phase — they are already gone from the linked list.  M&S only
 * needs to collect cycle garbage (objects with refcount > 0 but not
 * reachable from roots).
 */
fn void Heap.decref_free(&self, HeapHeader* hdr) {
    if (hdr.is_string()) {
        self.str_table_remove((hstring::HString*)hdr);
        self.free_string((hstring::HString*)hdr);
    } else if (hdr.is_object()) {
        hdr.unlink(&self.heap_allocated);
        hobject::hobject_free((HObject*)hdr);
    } else {
        hdr.unlink(&self.heap_allocated);
        self.free_func(self.heap_udata, hdr);
    }
}

fn void Heap.decref(&self, HeapHeader* hdr) @inline {
    if (--hdr.refcount == 0) {
        self.decref_free(hdr);
    }
}

/**
 * Decrement the reference count of the heap object or buffer held by
 * a TVal.  Strings are ignored (M&S-managed).
 * Safe to call on any TVal — non-heap values and strings are silently
 * ignored.  Typically called BEFORE overwriting a VM register or TVal
 * slot that holds a heap pointer.
 */
fn void Heap.decref_tval(&self, TVal* tv) @inline {
    if (tv.is_heap_allocated()) {
        void* ptr = tv.get_heapptr();
        if (ptr != null) {
            self.decref((HeapHeader*)ptr);
        }
    }
}

/// Copy a TVal from src to dst with proper refcounting.
/// - Decrements the old dst reference (may free the object if refcount reaches 0)
/// - Copies the bits verbatim
/// - Increments the new src reference if it holds a heap object or buffer
/// - Safe when dst == src (no-op in that case)
fn void Heap.tval_copy_ref(&self, TVal* dst, TVal* src) @inline {
    if (dst != src) {
        self.decref_tval(dst);
        *dst = *src;
        if (src.is_heap_allocated()) {
            void* ptr = src.get_heapptr();
            if (ptr != null) {
                ((HeapHeader*)ptr).incref();
            }
        }
    }
}

// ============================================================================
// Managed-object linked-list operations (doubly-linked via HeapHeader)
// ============================================================================

/**
 * Insert `hdr` at the head of the heap_allocated doubly-linked list.
 */
fn void Heap.insert_into_heap_allocated(&self, HeapHeader* hdr) {
    hdr.init(hdr.get_type(), &self.heap_allocated);
}

/**
 * Remove `hdr` from the heap_allocated doubly-linked list.
 * Uses HeapHeader.unlink() for O(1) removal.
 */
fn void Heap.remove_from_heap_allocated(&self, HeapHeader* hdr) {
    hdr.unlink(&self.heap_allocated);
}

/**
 * Insert `hdr` at the head of the heap_allocated list without calling
 * HeapHeader.init(), preserving any flags already set by the caller.
 *
 * This is the safe path for tracked objects where the subtype (HObject,
 * HString) has already set its flags and we only need the linked-list
 * wiring.  Use insert_into_heap_allocated() when a full header init is
 * desired (e.g. raw HeapHeader allocations).
 */
fn void Heap.insert_into_heap_allocated_preserve_flags(&self, HeapHeader* hdr) {
    hdr.prev = null;
    hdr.next = self.heap_allocated;
    if (self.heap_allocated != null) {
        self.heap_allocated.prev = hdr;
    }
    self.heap_allocated = hdr;
}

/**
 * Insert `hdr` at the head of the finalize_list doubly-linked list.
 */
fn void Heap.insert_into_finalize_list(&self, HeapHeader* hdr) {
    // Re-link into finalize_list — set the finalizable flag.
    hdr.set_finalizable();
    hdr.next = self.finalize_list;
    hdr.prev = null;
    if (self.finalize_list != null) {
        self.finalize_list.prev = hdr;
    }
    self.finalize_list = hdr;
}

/**
 * Remove `hdr` from the finalize_list doubly-linked list.
 */
fn void Heap.remove_from_finalize_list(&self, HeapHeader* hdr) {
    hdr.unlink(&self.finalize_list);
}

// ============================================================================
// GC root registration
// ============================================================================

/**
 * Register a heap object as a GC root.  Root objects are always treated as
 * reachable during mark-and-sweep, preventing them from being freed.
 */
fn void Heap.register_gc_root(&self, HeapHeader* hdr) {
    if (self.gc_root_count < GC_MAX_ROOTS) {
        self.gc_roots[self.gc_root_count] = (void*)hdr;
        self.gc_root_count++;
    }
}

// ============================================================================
// GC marking helpers — tri-color marking with explicit gray stack
// ============================================================================

/**
 * Push an object onto the gray stack for later child processing.
 * Grows the stack dynamically when full.
 */
fn void Heap.gray_push(&self, HObject* obj) {
    if (self.gray_count >= self.gray_capacity) {
        usz new_cap = self.gray_capacity > 0
                      ? (usz)self.gray_capacity * 2
                      : (usz)GRAY_STACK_INITIAL_CAP;
        void* new_arr = libc::realloc(self.gray_objects, void*::size * new_cap);
        if (new_arr == null) {
            self.fatal_func(self.heap_udata, "gray stack OOM during GC marking");
            return;
        }
        self.gray_objects  = (void**)new_arr;
        self.gray_capacity = (uint)new_cap;
    }
    self.gray_objects[self.gray_count++] = obj;
}

/**
 * Pop an object from the gray stack.  Returns null when the stack
 * is empty.
 */
fn HObject* Heap.gray_pop(&self) {
    if (self.gray_count == 0) { return null; }
    self.gray_count--;
    return (HObject*)self.gray_objects[self.gray_count];
}

/**
 * Mark a TVal value as reachable.
 *
 * If the value holds a heap-allocated object (OBJECT tag), marks the
 * object reachable and pushes it onto the gray stack for later child
 * processing.  Strings are marked directly (they have no outgoing edges).
 */
fn void Heap.mark_tval(&self, TVal* v) {
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (obj != null) {
            HeapHeader* hdr = (HeapHeader*)obj;
            if (!hdr.is_reachable()) {
                hdr.set_reachable();
                self.gray_push(obj);
            }
        }
    }
    // Strings are RC-managed — no marking needed.
}

/**
 * Mark an HObject pointer as reachable and schedule it for child
 * processing via the gray stack.  No-op when already reachable.
 */
fn void Heap.mark_hobject(&self, HObject* obj) {
    if (obj == null) { return; }
    HeapHeader* hdr = (HeapHeader*)obj;
    if (!hdr.is_reachable()) {
        hdr.set_reachable();
        self.gray_push(obj);
    }
}

/**
 * Drain the gray stack by popping objects and processing their
 * outgoing references (prototype, properties, array elements,
 * primitive wrapper value, environment bindings).
 *
 * Each newly discovered object is pushed onto the gray stack via
 * mark_tval / mark_hobject, so the loop eventually reaches
 * the transitive closure of all reachable objects.
 *
 * Iterative — no recursion, no depth cap, no C-stack overflow.
 */
fn void Heap.drain_gray(&self) {
    while (self.gray_count > 0) {
        HObject* obj = self.gray_pop();

        // --- Prototype chain ---
        if (obj.prototype != null) {
            self.mark_hobject(obj.prototype);
        }

        // --- Named properties ---
        PropValue* pv = obj.prop_values();
        for (uint i = 0; i < obj.prop_count; i++) {
            HString* key = (HString*)obj.shape.props()[i].key;
            if (key != null) {
                ((HeapHeader*)key).set_reachable();
            }
            self.mark_tval(&pv[i].data.value);
            self.mark_tval(&pv[i].data.getter);
            self.mark_tval(&pv[i].setter);
        }

        // --- Array part ---
        TVal* ap = obj.array_part();
        if (ap != null) {
            for (uint i = 0; i < obj.array_size; i++) {
                self.mark_tval(&ap[i]);
            }
        }

        // --- Subtype-specific fields ---
        switch (obj.flags.obj_class) {
            case ObjClass.FUNCTION:
            case ObjClass.THREAD:
                if (obj.extra.func.var_env != null && obj.extra.func.var_env.bindings != null) {
                    self.mark_hobject(obj.extra.func.var_env.bindings);
                }
                if (obj.extra.func.lex_env != null && obj.extra.func.lex_env.bindings != null) {
                    self.mark_hobject(obj.extra.func.lex_env.bindings);
                }
                break;
            case ObjClass.GENERATOR:
                if (obj.extra.gen.var_env != null && obj.extra.gen.var_env.bindings != null) {
                    self.mark_hobject(obj.extra.gen.var_env.bindings);
                }
                if (obj.extra.gen.lex_env != null && obj.extra.gen.lex_env.bindings != null) {
                    self.mark_hobject(obj.extra.gen.lex_env.bindings);
                }
                break;
            case ObjClass.BOOLEAN:
            case ObjClass.NUMBER:
            case ObjClass.STRING:
            case ObjClass.DATE:
                self.mark_tval(&obj.extra.prim.primitive_value);
                break;
            case ObjClass.ARRAY_ITERATOR:
            case ObjClass.MAP_ITERATOR:
            case ObjClass.SET_ITERATOR:
                // Mark the iterated object (target can be collected otherwise)
                if (obj.iterator_target != null) {
                    self.mark_hobject(obj.iterator_target);
                }
                break;
            case ObjClass.STRING_ITERATOR:
                self.mark_tval(&obj.extra.prim.primitive_value);
                break;
            default:
                break;
        }

        // TODO: mark CompiledFunction constants (bytecode.c3 helper)
    }
}

/**
 * Mark all GC roots: registered roots, built-in prototypes, the VM
 * value stack, and individual string references found during tracing.
 * Uses the gray stack for iterative transitive marking — no recursion,
 * no depth cap.
 */
fn void Heap.mark_roots(&self) {
    // Mark all registered roots
    for (uint i = 0; i < self.gc_root_count; i++) {
        HeapHeader* hdr = (HeapHeader*)self.gc_roots[i];
        if (hdr != null) {
            if (hdr.is_object()) {
                self.mark_hobject((HObject*)hdr);
            } else {
                hdr.set_reachable();
            }
        }
    }

    // Mark built-in error prototypes
    if (self.err_proto != null) { self.mark_hobject(self.err_proto); }
    if (self.type_err_proto != null) { self.mark_hobject(self.type_err_proto); }
    if (self.range_err_proto != null) { self.mark_hobject(self.range_err_proto); }
    if (self.ref_err_proto != null) { self.mark_hobject(self.ref_err_proto); }
    if (self.syntax_err_proto != null) { self.mark_hobject(self.syntax_err_proto); }
    if (self.eval_err_proto != null) { self.mark_hobject(self.eval_err_proto); }
    if (self.uri_err_proto != null) { self.mark_hobject(self.uri_err_proto); }
    if (self.aggregate_err_proto != null) { self.mark_hobject(self.aggregate_err_proto); }

    // Mark built-in constructor prototypes
    if (self.object_proto != null) { self.mark_hobject(self.object_proto); }
    if (self.array_proto != null) { self.mark_hobject(self.array_proto); }
    if (self.function_proto != null) { self.mark_hobject(self.function_proto); }
    if (self.string_proto != null) { self.mark_hobject(self.string_proto); }
    if (self.number_proto != null) { self.mark_hobject(self.number_proto); }
    if (self.bool_proto != null) { self.mark_hobject(self.bool_proto); }
    if (self.date_proto != null) { self.mark_hobject(self.date_proto); }
    if (self.regexp_proto != null) { self.mark_hobject(self.regexp_proto); }
    if (self.map_proto != null) { self.mark_hobject(self.map_proto); }
    if (self.set_proto != null) { self.mark_hobject(self.set_proto); }
    if (self.weakmap_proto != null) { self.mark_hobject(self.weakmap_proto); }
    if (self.weakset_proto != null) { self.mark_hobject(self.weakset_proto); }
    if (self.symbol_proto != null) { self.mark_hobject(self.symbol_proto); }
    if (self.promise_proto != null) { self.mark_hobject(self.promise_proto); }
    if (self.generator_proto != null) { self.mark_hobject(self.generator_proto); }
    if (self.iterator_proto != null) { self.mark_hobject(self.iterator_proto); }

    // Scan the VM value stack as a GC root — all live TVal slots
    // (from base to top) may reference heap objects or strings.
    if (self.valstack_base != null && self.valstack_top_ptr != null) {
        TVal* top = *self.valstack_top_ptr;
        TVal* scan = self.valstack_base;
        while (scan < top) {
            self.mark_tval(scan);
            scan++;
        }
    }

    // Strings are RC-managed — no string marking needed in M&S.
    // Symbol registry, builtin strs[], iterator/toprimitive symbols, and
    // CF constant string refs are all kept alive by their refcounts.

    // Mark HObject* protos cached in IC entries (strings are RC, objects need M&S)
    for (uint fi = 0; fi < self.compiled_func_count; fi++) {
        bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[fi];
        if (cf == null) { continue; }
        if (cf.ic_entries != null && cf.ic_count > 0) {
            hobject::ICEntry* ics = (hobject::ICEntry*)cf.ic_entries;
            for (uint ii = 0; ii < cf.ic_count; ii++) {
                if (ics[ii].proto != null) { self.mark_hobject((HObject*)ics[ii].proto); }
            }
        }
        if (cf.var_ic_entries != null && cf.var_ic_count > 0) {
            hobject::VarICEntry* vics = (hobject::VarICEntry*)cf.var_ic_entries;
            for (uint vi = 0; vi < cf.var_ic_count; vi++) {
                if (vics[vi].bindings != null) { self.mark_hobject((HObject*)vics[vi].bindings); }
            }
        }
    }

    // Mark global checkpoint keys
    for (uint i = 0; i < self.checkpoint_count; i++) {
        HString* key = (HString*)self.checkpoint_keys[i];
        if (key != null) { ((HeapHeader*)key).set_reachable(); }
    }

    // Mark activation-record env bindings (fresh per-call envs not otherwise rooted)
    if (self.mark_activations_fn != null && self.curr_thread != null) {
        self.mark_activations_fn(self.curr_thread, self);
    }

    // Drain the gray stack — transitively marks all reachable objects
    self.drain_gray();
}

// ============================================================================
// GC sweep
// ============================================================================

/**
 * Sweep phase: walk the heap_allocated list and free every object that
 * was NOT marked reachable during the mark phase.  Clears the reachable
 * flag on surviving objects for the next cycle.  Unlinks dead nodes
 * from the list.
 */
fn void Heap.sweep(&self) {
    HeapHeader* cur = self.heap_allocated;
    HeapHeader* prev = null;
    uint kept = 0;

    while (cur != null) {
        HeapHeader* next = cur.next;
        if (!cur.is_reachable()) {
            // Unlink from list
            if (prev != null) {
                prev.next = next;
            } else {
                self.heap_allocated = next;
            }
            if (next != null) {
                next.prev = prev;
            }
            // Free
            if (cur.is_object()) {
                hobject::hobject_free((HObject*)cur);
            } else if (cur.is_string()) {
                libc::free(cur);
            } else {
                self.free_func(self.heap_udata, cur);
            }
        } else {
            // Keep — clear mark bit for next cycle
            cur.clear_reachable();
            prev = cur;
            kept++;
        }
        cur = next;
    }
    self.live_obj_count = kept;
}

/**
 * Run a full mark-and-sweep garbage collection.
 *
 * 1. Clear all reachable flags.
 * 2. Mark all reachable objects starting from roots (built-in prototypes,
 *    registered GC roots, and the string table).
 * 3. Sweep unmarked (unreachable) objects, freeing their memory.
 * 4. Reset the GC trigger counter based on the new live-object count.
 *
 * Re-entrancy is prevented by the gc_running guard.
 */
fn void Heap.mark_and_sweep(&self) {
    if (self.gc_running) { return; }
    self.gc_running = true;

    // --- Phase 1: Clear all reachable flags ---
    {
        HeapHeader* cur = self.heap_allocated;
        while (cur != null) {
            cur.clear_reachable();
            cur = cur.next;
        }
    }

    // --- Phase 2: Mark from roots ---
    self.mark_roots();

    // --- Phase 3: Sweep objects (strings are RC-managed, not swept here) ---
    self.sweep();

    // --- Phase 4: Reset trigger counter (capped) ---
    long new_trigger = (long)self.live_obj_count * GC_TRIGGER_GROW_FACTOR;
    if (new_trigger < GC_INITIAL_TRIGGER) {
        new_trigger = GC_INITIAL_TRIGGER;
    }
    if (new_trigger > GC_MAX_TRIGGER) {
        new_trigger = GC_MAX_TRIGGER;
    }
    self.gc_trigger_counter = new_trigger;
    self.gc_running = false;
}

/**
 * Trigger a mark-and-sweep GC pass.  Called automatically when the
 * allocation counter reaches zero.
 */
fn void Heap.trigger_gc(&self) {
    self.mark_and_sweep();
}

// ============================================================================
// String hashing (FNV-1a, 32-bit)
// ============================================================================

const uint FNV1A_OFFSET_BASIS = 0x811C_9DC5;
const uint FNV1A_PRIME        = 0x0100_0193;

/**
 * Compute a 32-bit FNV-1a hash of `data`.  Mixes in the heap's random
 * state for HashDoS mitigation.
 */
fn uint Heap.hash_string(&self, char[] data) {
    uint h = FNV1A_OFFSET_BASIS ^ self.hash_seed;
    foreach (b : data) {
        h ^= (uint)b;
        h *= FNV1A_PRIME;
    }
    return h;
}

// ============================================================================
// String table (open-addressing, linear probing)
// ============================================================================

/**
 * Grow the string table when the load factor exceeds the threshold.
 * Rehashes every live entry into the new table.
 */
fn void*? Heap.str_table_grow(&self) {
    uint new_size = self.str_table_size * 2;
    if (new_size < INITIAL_STR_TABLE_SIZE) {
        new_size = INITIAL_STR_TABLE_SIZE;
    }

    usz new_bytes = HString*::size * new_size;
    void* raw = self.alloc_func(self.heap_udata, new_bytes);
    if (raw == null) {
        return HEAP_ALLOC_FAULT~;
    }
    libc::memset(raw, 0, new_bytes);

    HString** new_table = (HString**)raw;

    // Rehash existing entries
    for (uint i = 0; i < self.str_table_size; i++) {
        HString* entry = self.str_table[i];
        if (entry == null) { continue; }

        uint idx = entry.hash & (new_size - 1);
        while (new_table[idx] != null) {
            idx = (idx + 1) & (new_size - 1);
        }
        new_table[idx] = entry;
    }

    // Free old table, swap in the new one
    self.free_func(self.heap_udata, self.str_table);
    self.str_table      = new_table;
    self.str_table_size = new_size;

    return raw;  // non-null signals success
}

/**
 * Look up an interned string by raw byte content and precomputed hash.
 * Returns the existing HString or `null` if not found.
 */
fn HString* Heap.str_table_lookup(&self, char[] data, uint hash) {
    if (self.str_table_size == 0) { return null; }

    uint idx = hash & (self.str_table_size - 1);

    for (uint probes = 0; probes < self.str_table_size; probes++) {
        HString* entry = self.str_table[idx];
        if (entry == null) {
            return null;  // empty slot — not present
        }

        if (entry.hash == hash && entry.blen == (uint)data.len) {
            if (entry.equals(data)) {
                return entry;
            }
        }

        idx = (idx + 1) & (self.str_table_size - 1);
    }
    return null;
}

/**
 * Insert a fully initialised HString (with .hash set) into the string
 * table.  Grows the table first if the load factor is too high.
 */
fn void Heap.str_table_insert(&self, HString* hstr) {
    // Grow if necessary
    float load = (float)(self.str_table_used + 1) / (float)self.str_table_size;
    if (load > STR_TABLE_LOAD_FACTOR) {
        // Best-effort grow; if it fails we still insert into the
        // existing table (it will just be slower).
        void* ignored = self.str_table_grow() ?? null;
    }

    uint idx = hstr.hash & (self.str_table_size - 1);
    while (self.str_table[idx] != null) {
        idx = (idx + 1) & (self.str_table_size - 1);
    }
    self.str_table[idx] = hstr;
    self.str_table_used++;
}

/**
 * Remove hstr from the string table using backshift deletion (Knuth R).
 * Must only be called when hstr is confirmed to be in the table.
 * Preserves the linear-probe invariant so str_table_lookup remains correct.
 */
fn void Heap.str_table_remove(&self, HString* hstr) {
    if (self.str_table_size == 0) { return; }

    uint mask = self.str_table_size - 1;

    // Find the slot holding hstr
    uint i = hstr.hash & mask;
    while (self.str_table[i] != hstr) {
        i = (i + 1) & mask;
    }

    // Backshift: repeatedly pull forward the best candidate to fill the hole
    for (;;) {
        uint hole = i;
        uint k = i;
        for (;;) {
            k = (k + 1) & mask;
            if (self.str_table[k] == null) {
                // No candidate needed — just clear the hole
                self.str_table[hole] = null;
                self.str_table_used--;
                return;
            }
            // Natural slot of the candidate at k
            uint nat = self.str_table[k].hash & mask;
            // Candidate can fill hole if its natural slot is not strictly
            // between hole and k (cyclically).
            bool can_move;
            if (hole <= k) {
                can_move = (nat <= hole || nat > k);
            } else {
                can_move = (nat <= hole && nat > k);
            }
            if (can_move) { break; }
        }
        self.str_table[hole] = self.str_table[k];
        i = k;
    }
}

/**
 * Intern a string: return the existing copy if one exists, otherwise
 * allocate, insert, and return the new copy.  Returns null on alloc failure.
 */
fn HString* Heap.str_intern(&self, char[] data) {
    uint hash = self.hash_string(data);
    HString* existing = self.str_table_lookup(data, hash);
    if (existing != null) {
        return existing;
    }
    HString*? new_s = hstring::hstring_alloc(self, data, hash);
    if (try s = new_s) {
        self.str_table_insert(s);
        return s;
    }
    return null;
}

// ============================================================================
// PRNG (xorshift32)
// ============================================================================

/**
 * Advance the heap's xorshift32 PRNG and return the new state.
 */
fn uint Heap.xorshift32(&self) {
    uint x = self.rnd_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    self.rnd_state = x;
    return x;
}

// ============================================================================
// Internal helpers
// ============================================================================

/**
 * Walk a doubly-linked HeapHeader list and free every node through the
 * heap's allocator.  The caller must null the list head afterwards.
 */
fn void Heap.free_header_list(&self, HeapHeader* list) {
    HeapHeader* cur = list;
    while (cur != null) {
        HeapHeader* nxt = cur.next;
        // In a full implementation this would dispatch on h_type to
        // free type-specific payloads first.
        self.free_func(self.heap_udata, cur);
        cur = nxt;
    }
}

// ============================================================================
// Microtask queue — PromiseJobs job queue
// ============================================================================

/// Enqueue a microtask (Promise reaction job).  Each entry stores a
/// (handler, argument, downstream) triple.  The queue is drained after each
/// top-level script execution and after vm_call_fn_impl returns for compiled
/// functions.
fn void Heap.enqueue_microtask(&self, TVal handler, TVal arg, TVal downstream) {
    // Grow if needed (each entry = 3 TVal slots)
    uint needed = self.microtask_count + 1;
    if (needed > self.microtask_capacity) {
        uint new_cap = self.microtask_capacity == 0 ? 16 : self.microtask_capacity * 2;
        usz new_bytes = (usz)new_cap * TVal::size * 3;
        TVal* new_q = (TVal*)libc::realloc(self.microtask_queue, new_bytes);
        if (new_q == null) { return; }
        // Zero the new slots
        libc::memset(new_q + self.microtask_capacity * 3, 0,
                     (long)(new_cap - self.microtask_capacity) * TVal::size * 3);
        self.microtask_queue = new_q;
        self.microtask_capacity = new_cap;
    }
    uint idx = self.microtask_count * 3;
    self.microtask_queue[idx]     = handler;
    self.microtask_queue[idx + 1] = arg;
    self.microtask_queue[idx + 2] = downstream;
    self.microtask_count++;
}

/// Drain the microtask queue.  Processes all currently-enqueued entries,
/// and continues draining if new entries are added during execution
/// (e.g. a handler resolves another promise).  Uses a re-entrancy guard
/// to prevent infinite loops.
fn void Heap.drain_microtasks(&self, void* vm) {
    if (self.microtask_draining) return;
    if (self.microtask_count == 0) return;
    self.microtask_draining = true;
    defer self.microtask_draining = false;

    for (;;) {
        uint count = self.microtask_count;
        if (count == 0) break;

        // Snapshot current count — new entries may be added during processing
        self.microtask_count = 0;

        for (uint i = 0; i < count; i++) {
            uint base = i * 3;
            TVal handler    = self.microtask_queue[base];
            TVal arg        = self.microtask_queue[base + 1];
            TVal downstream = self.microtask_queue[base + 2];

            // Call handler(arg) through the VM
            TVal result;
            if (self.call_handler_fn != null && vm != null) {
                result = self.call_handler_fn(vm, handler, &arg);
            } else {
                result = arg;
            }

            // Resolve downstream promise with handler's return value
            if (downstream.is_object() && downstream.get_heapptr() != null &&
                self.microtask_after_fn != null && vm != null) {
                self.microtask_after_fn((void*)self, vm, result, downstream);
            }
        }
        // Loop continues if new microtasks were enqueued during processing
    }
}
