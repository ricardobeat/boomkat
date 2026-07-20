/// Core types for the Duktape JavaScript engine.
///
/// This module defines the fundamental value representation (TVal),
/// garbage-collected heap object headers (HeapHeader), portable type
/// aliases, numeric constants, and engine fault codes.
module duktape::types;

// ============================================================================
// Portable type aliases
// ============================================================================

/// 32-bit signed integer used throughout the API.
alias DukInt       = int;
/// 32-bit unsigned integer.
alias DukUint      = uint;
/// Platform-native size type.
alias DukSize      = usz;
/// Value-stack index (signed so negative indices work).
alias DukIdx       = int;
/// Compact signed integer for space-sensitive structures.
alias DukSmallInt  = short;
/// Compact unsigned integer.
alias DukSmallUint = ushort;
/// Boolean (mirrors the built-in bool).
alias DukBool      = bool;
/// IEEE 754 double precision float.
alias DukDouble    = double;
/// Unicode codepoint (U+0000 .. U+10FFFF).
alias DukCodepoint = uint;

// ============================================================================
// Common constants
// ============================================================================

/// IEEE 754 Not-a-Number.
const double DUK_DOUBLE_NAN      = double::nan;
/// IEEE 754 positive infinity.
const double DUK_DOUBLE_INFINITY = double::inf;
/// Sentinel returned when a stack index is invalid.
const int    DUK_INVALID_INDEX   = int::min;
/// Maximum safe integer representable in a double (2^53 - 1).
const long   DUK_MAX_SAFE_INT    = 9007199254740991;
/// Minimum safe integer representable in a double -(2^53 - 1).
const long   DUK_MIN_SAFE_INT    = -9007199254740991;

// ============================================================================
// Fault codes (used with C3's faultdef / optional error handling)
// ============================================================================

/// Memory allocation failure.
faultdef ALLOC_ERROR;
/// ECMAScript TypeError.
faultdef TYPE_ERROR;
/// ECMAScript RangeError.
faultdef RANGE_ERROR;
/// ECMAScript SyntaxError.
faultdef SYNTAX_ERROR;
/// ECMAScript ReferenceError.
faultdef REFERENCE_ERROR;
/// ECMAScript URIError.
faultdef URI_ERROR;
/// ECMAScript EvalError.
faultdef EVAL_ERROR;
/// Internal engine error (bug or unrecoverable condition).
faultdef INTERNAL_ERROR;
/// Public C API misuse.
faultdef API_ERROR;

// ============================================================================
// TVal — Tagged value (the core JS value representation)
// ============================================================================

/// Discriminator for the payload stored inside a TVal.
enum TValTag : char {
    /// ECMAScript undefined.
    UNDEFINED,
    /// ECMAScript null.
    NULL_VAL,
    /// ECMAScript boolean (true / false).
    BOOLEAN,
    /// IEEE 754 double – the general ECMAScript number type.
    NUMBER,
    /// 48-bit fast integer optimisation path.
    FASTINT,
    /// Pointer to a heap-allocated HString.
    STRING,
    /// Pointer to a heap-allocated HObject.
    OBJECT,
    /// Pointer to a heap-allocated HBuffer.
    BUFFER,
    /// Raw void* exposed to user code.
    POINTER,
    /// Lightweight function pointer (no heap allocation).
    LIGHTFUNC,
    /// Pointer to a heap-allocated BigInt (interned HString digit string).
    BIGINT,
    /// Internal deletion sentinel for Set/Map entry tracking.
    /// Not a valid ECMAScript value — used to mark array_part slots
    /// that have been deleted, distinct from stored undefined values.
    DELETED,
}


/// FASTINT uses 48-bit signed integer range (fits in NaN-box payload).
const long FASTINT_MIN = -140737488355328L;  // -2^47
const long FASTINT_MAX =  140737488355327L;  //  2^47 - 1

/// Toggle for NaN-boxing representation. When true, TVal is an 8-byte
/// NaN-boxed ulong. When false, TVal is the 16-byte tagged union.
/// Default is true. Pass `-D NONANBOX` to c3c to disable.
const bool USE_NANBOX = !$feature(NONANBOX);

/// Toggle for strict environment access checking. When true, the VM will trap
/// (via unreachable) if a function with needs_env=false tries to touch its own
/// environment bindings. This helps catch bugs before register-local optimization.
/// Default is false. Pass `-D ENV_STRICT` to c3c to enable.
const bool ENV_STRICT = $feature(ENV_STRICT);

/// Maximum length of a formatted error-message string (160 bytes).
const int ERROR_MSG_BUF = 160;
/// Maximum length of a number/date-to-string temporary buffer (32 bytes).
const int FORMAT_BUF = 32;

// ============================================================================
// NaN-boxing constants and helpers (used when USE_NANBOX = true)
// ============================================================================

const ulong NANBOX_PAYLOAD_MASK = 0x0000FFFFFFFFFFFF;  // bits 47-0

/// Tag values for NaN-boxed representation. These are full 16-bit values
/// stored in bits 63-48, matching Duktape's encoding. All doubles must
/// have bits 63-48 <= 0xFFF0 (achieved by NaN normalization in set_number).
const ulong TAG_FASTINT    = 0xFFF1;  // embed: 48-bit signed integer
const ulong TAG_BIGINT     = 0xFFF2;  // embed: HBigInt* ptr (int128 box)
const ulong TAG_UNDEFINED  = 0xFFF3;  // embed: nothing
const ulong TAG_NULL_VAL   = 0xFFF4;  // embed: nothing
const ulong TAG_BOOLEAN    = 0xFFF5;  // embed: 0 or 1
const ulong TAG_POINTER    = 0xFFF6;  // embed: void* ptr
const ulong TAG_LIGHTFUNC  = 0xFFF7;  // embed: func ptr
const ulong TAG_STRING     = 0xFFF8;  // embed: HString* ptr
const ulong TAG_OBJECT     = 0xFFF9;  // embed: HObject* ptr
const ulong TAG_BUFFER     = 0xFFFA;  // embed: buffer ptr
const ulong TAG_DELETED    = 0xFFFF;  // embed: nothing (Set/Map deletion sentinel)

macro ulong nanbox_encode_tagged(ulong tag, ulong payload) {
    return (tag << 48) | (payload & NANBOX_PAYLOAD_MASK);
}

/// True if the value is a regular double (not a tagged NaN).
/// Doubles have bits 63-48 <= 0xFFF0; tagged values >= 0xFFF1.
macro bool nanbox_is_double(ulong v) {
    return (v >> 48) <= 0xFFF0;
}

macro ulong nanbox_get_tag(ulong v) {
    return v >> 48;
}

macro ulong nanbox_get_payload(ulong v) {
    return v & NANBOX_PAYLOAD_MASK;
}

/// A tagged value – the universal currency of the value stack.
struct TVal @if(USE_NANBOX) {
    /// NaN-boxed: 8-byte representation.
    ulong bits;
}

struct TVal @if(!USE_NANBOX) {
    /// Explicit tag + union: 16-byte representation.
    TValTag tag;
    union {
        bool    boolean;
        double  number;
        long    fastint;
        void*   pointer;
    }
}

// ---------------------------------------------------------------------------
// TVal — tag query (for switch statements)
// ---------------------------------------------------------------------------

/// Returns the TValTag discriminator. In the NaN-box path, this decodes
/// from the NaN-box tag bits.
macro TValTag TVal.get_tag(&self) {
$if USE_NANBOX:
    if (nanbox_is_double(self.bits)) return NUMBER;
    switch (nanbox_get_tag(self.bits)) {
        case TAG_UNDEFINED:  return UNDEFINED;
        case TAG_NULL_VAL:   return NULL_VAL;
        case TAG_BOOLEAN:    return BOOLEAN;
        case TAG_FASTINT:    return FASTINT;
        case TAG_STRING:     return STRING;
        case TAG_OBJECT:     return OBJECT;
        case TAG_BUFFER:     return BUFFER;
        case TAG_POINTER:    return POINTER;
        case TAG_LIGHTFUNC:  return LIGHTFUNC;
        case TAG_BIGINT:     return BIGINT;
        case TAG_DELETED:    return DELETED;
        default:             return UNDEFINED;
    }
$else
    return self.tag;
$endif
}

// ---------------------------------------------------------------------------
// TVal — raw bits (for hashing / constant-pool dedup)
// ---------------------------------------------------------------------------

/// Returns a 64-bit representation of the TVal suitable for hashing.
/// In NaN-box mode this is the raw bits field. In tagged-union mode we
/// pack the tag into the high byte and reinterpret the payload as ulong.
macro ulong TVal.get_raw_bits(&self) {
$if USE_NANBOX:
    return self.bits;
$else
    // Pack tag in the high byte, payload in the low 56 bits.
    // For doubles, bitcast to ulong; for pointers/fastints, reinterpret.
    TValTag t = self.tag;
    switch (t) {
        case NUMBER:
            return ((ulong)t << 56) | (ulong)(bitcast(self.number, ulong));
        case FASTINT:
            return ((ulong)t << 56) | ((ulong)(self.fastint) & 0x00FFFFFFFFFFFFFF);
        default:
            return ((ulong)t << 56) | (ulong)(self.pointer);
    }
$endif
}

// ---------------------------------------------------------------------------
// TVal — type predicates
// ---------------------------------------------------------------------------

macro bool TVal.is_undefined(&self) {
$if USE_NANBOX:
    return self.bits == (TAG_UNDEFINED << 48);
$else
    return self.tag == UNDEFINED;
$endif
}

macro bool TVal.is_null(&self) {
$if USE_NANBOX:
    return self.bits == (TAG_NULL_VAL << 48);
$else
    return self.tag == NULL_VAL;
$endif
}

macro bool TVal.is_deleted(&self) {
$if USE_NANBOX:
    return self.bits == (TAG_DELETED << 48);
$else
    return self.tag == DELETED;
$endif
}


macro bool TVal.is_boolean(&self) {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_BOOLEAN;
$else
    return self.tag == BOOLEAN;
$endif
}

macro bool TVal.is_number(&self) {
$if USE_NANBOX:
    return nanbox_is_double(self.bits);
$else
    return self.tag == NUMBER;
$endif
}

macro bool TVal.is_fastint(&self) {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_FASTINT;
$else
    return self.tag == FASTINT;
$endif
}

macro bool TVal.is_string(&self) {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_STRING;
$else
    return self.tag == STRING;
$endif
}

macro bool TVal.is_object(&self) {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_OBJECT;
$else
    return self.tag == OBJECT;
$endif
}

macro bool TVal.is_buffer(&self) {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_BUFFER;
$else
    return self.tag == BUFFER;
$endif
}

macro bool TVal.is_bigint(&self) {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_BIGINT;
$else
    return self.tag == BIGINT;
$endif
}

macro bool TVal.is_pointer(&self) {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_POINTER;
$else
    return self.tag == POINTER;
$endif
}

macro bool TVal.is_lightfunc(&self) {
$if USE_NANBOX:
    return nanbox_get_tag(self.bits) == TAG_LIGHTFUNC;
$else
    return self.tag == LIGHTFUNC;
$endif
}

macro bool TVal.is_nullish(&self) {
$if USE_NANBOX:
    // undefined=0xFFF3..., null=0xFFF4... — consecutive tags, both zero payload
    ulong tag = self.bits >> 48;
    return tag >= TAG_UNDEFINED && tag <= TAG_NULL_VAL && (self.bits & NANBOX_PAYLOAD_MASK) == 0;
$else
    return self.tag == UNDEFINED || self.tag == NULL_VAL;
$endif
}

macro bool TVal.is_numeric(&self) {
$if USE_NANBOX:
    return (self.bits >> 48) <= TAG_FASTINT;
$else
    return self.tag == NUMBER || self.tag == FASTINT;
$endif
}

macro bool TVal.is_heap_allocated(&self) {
$if USE_NANBOX:
    ulong tag = self.bits >> 48;
    return (tag >= TAG_STRING && tag <= TAG_BUFFER) || tag == TAG_BIGINT;
$else
    return self.tag == STRING || self.tag == OBJECT || self.tag == BUFFER || self.tag == BIGINT;
$endif
}

// ---------------------------------------------------------------------------
// TVal — getters
// ---------------------------------------------------------------------------

macro bool TVal.get_boolean(&self) {
$if USE_NANBOX:
    return nanbox_get_payload(self.bits) != 0;
$else
    return self.boolean;
$endif
}

macro double TVal.get_number(&self) {
$if USE_NANBOX:
    return bitcast(self.bits, double);
$else
    return self.number;
$endif
}

macro long TVal.get_fastint(&self) {
$if USE_NANBOX:
    // Branchless sign extension from 48-bit two's complement.
    // Shift left 16 to put sign bit at bit 63, then arithmetic right shift.
    long payload = (long)nanbox_get_payload(self.bits);
    return (payload << 16) >> 16;
$else
    return self.fastint;
$endif
}

macro void* TVal.get_heapptr(&self) {
$if USE_NANBOX:
    return (void*)nanbox_get_payload(self.bits);
$else
    return self.pointer;
$endif
}

macro double TVal.get_number_or_fastint(&self) {
$if USE_NANBOX:
    if (self.is_fastint()) {
        return (double)self.get_fastint();
    }
    return bitcast(self.bits, double);
$else
    if (self.tag == FASTINT) {
        return (double)self.fastint;
    }
    return self.number;
$endif
}

/// Single-branch combined FASTINT check for two TVal pointers.
/// In the NaN-box build: XORing each value's top 16 bits with TAG_FASTINT
/// yields zero iff that value IS a FASTINT; ORing the two results means the
/// OR is zero iff BOTH are FASTINTs — one branch, no sequential dependency.
/// Falls back to two is_fastint() calls in the non-NaN-box build.
macro bool both_fastint(TVal* b, TVal* c) {
$if USE_NANBOX:
    return (((b.bits ^ (TAG_FASTINT << 48)) | (c.bits ^ (TAG_FASTINT << 48))) >> 48) == 0;
$else
    return b.is_fastint() && c.is_fastint();
$endif
}

// ---------------------------------------------------------------------------
// TVal — mutating setters
// ---------------------------------------------------------------------------

macro void TVal.set_undefined(&self) {
$if USE_NANBOX:
    self.bits = TAG_UNDEFINED << 48;
$else
    self.tag     = UNDEFINED;
    self.pointer = null;
$endif
}

macro void TVal.set_deleted(&self) {
$if USE_NANBOX:
    self.bits = TAG_DELETED << 48;
$else
    self.tag     = DELETED;
    self.pointer = null;
$endif
}

macro void TVal.set_null(&self) {
$if USE_NANBOX:
    self.bits = TAG_NULL_VAL << 48;
$else
    self.tag     = NULL_VAL;
    self.pointer = null;
$endif
}

macro void TVal.set_boolean(&self, bool val) {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_BOOLEAN, val ? 1 : 0);
$else
    self.tag     = BOOLEAN;
    self.boolean = val;
$endif
}

macro void TVal.set_number(&self, double val) {
$if USE_NANBOX:
    ulong bits = bitcast(val, ulong);
    // NaN normalization: negative NaNs have bits 63-48 >= 0xFFF8, which
    // would collide with tagged values. Normalize to canonical positive NaN.
    if (bits >> 48 >= TAG_FASTINT) {
        bits = 0x7FF8000000000000;
    }
    self.bits = bits;
$else
    self.tag    = NUMBER;
    self.number = val;
$endif
}

macro void TVal.set_fastint(&self, long val) {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_FASTINT, (ulong)val);
$else
    self.tag     = FASTINT;
    self.fastint = val;
$endif
}

/// Store an integer result, boxing as a fastint when it fits the fastint range
/// and falling back to a double otherwise.  This is the canonical way to write
/// the result of integer arithmetic (ADD/SUB/ADDI/SUBI/...) — do not open-code
/// the range check at call sites.
macro void TVal.set_fastint_or_number(&self, long val) {
    if (val >= FASTINT_MIN && val <= FASTINT_MAX) {
        self.set_fastint(val);
    } else {
        self.set_number((double)val);
    }
}

macro void TVal.set_string(&self, void* ptr) {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_STRING, (usz)ptr);
$else
    self.tag     = STRING;
    self.pointer = ptr;
$endif
    if (ptr != null) { ((HeapHeader*)ptr).incref(); }
}

macro void TVal.set_object(&self, void* ptr) {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_OBJECT, (usz)ptr);
$else
    self.tag     = OBJECT;
    self.pointer = ptr;
$endif
    if (ptr != null) { ((HeapHeader*)ptr).incref(); }
}

macro void TVal.set_buffer(&self, void* ptr) {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_BUFFER, (usz)ptr);
$else
    self.tag     = BUFFER;
    self.pointer = ptr;
$endif
    if (ptr != null) { ((HeapHeader*)ptr).incref(); }
}

macro void TVal.set_pointer(&self, void* ptr) {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_POINTER, (usz)ptr);
$else
    self.tag     = POINTER;
    self.pointer = ptr;
$endif
}

macro void TVal.set_lightfunc(&self, void* ptr) {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_LIGHTFUNC, (usz)ptr);
$else
    self.tag     = LIGHTFUNC;
    self.pointer = ptr;
$endif
}

macro void TVal.set_bigint(&self, void* ptr) {
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_BIGINT, (usz)ptr);
$else
    self.tag     = BIGINT;
    self.pointer = ptr;
$endif
    if (ptr != null) { ((HeapHeader*)ptr).incref(); }
}

// ---------------------------------------------------------------------------
// TVal — static constructors
// ---------------------------------------------------------------------------

macro TVal make_undefined() {
$if USE_NANBOX:
    TVal tv;
    tv.bits = TAG_UNDEFINED << 48;
    return tv;
$else
    return (TVal){ .tag = UNDEFINED };
$endif
}

macro TVal make_null() {
$if USE_NANBOX:
    TVal tv;
    tv.bits = nanbox_encode_tagged(TAG_NULL_VAL, 0);
    return tv;
$else
    return (TVal){ .tag = NULL_VAL };
$endif
}

macro TVal make_boolean(bool val) {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_BOOLEAN, val ? 1 : 0);
$else
    tv.tag     = BOOLEAN;
    tv.boolean = val;
$endif
    return tv;
}

macro TVal make_number(double val) {
    TVal tv;
$if USE_NANBOX:
    ulong bits = bitcast(val, ulong);
    if (bits >> 48 >= TAG_FASTINT) {
        bits = 0x7FF8000000000000;
    }
    tv.bits = bits;
$else
    tv.tag    = NUMBER;
    tv.number = val;
$endif
    return tv;
}

macro TVal make_fastint(long val) {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_FASTINT, (ulong)val);
$else
    tv.tag     = FASTINT;
    tv.fastint = val;
$endif
    return tv;
}

macro TVal make_string(void* ptr) {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_STRING, (usz)ptr);
$else
    tv.tag     = STRING;
    tv.pointer = ptr;
$endif
    if (ptr != null) { ((HeapHeader*)ptr).incref(); }
    return tv;
}

macro TVal make_object(void* ptr) {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_OBJECT, (usz)ptr);
$else
    tv.tag     = OBJECT;
    tv.pointer = ptr;
$endif
    if (ptr != null) { ((HeapHeader*)ptr).incref(); }
    return tv;
}

macro TVal make_buffer(void* ptr) {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_BUFFER, (usz)ptr);
$else
    tv.tag     = BUFFER;
    tv.pointer = ptr;
$endif
    if (ptr != null) { ((HeapHeader*)ptr).incref(); }
    return tv;
}

macro TVal make_pointer(void* ptr) {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_POINTER, (usz)ptr);
$else
    tv.tag     = POINTER;
    tv.pointer = ptr;
$endif
    return tv;
}

macro TVal make_lightfunc(void* ptr) {
    TVal tv;
$if USE_NANBOX:
    tv.bits = nanbox_encode_tagged(TAG_LIGHTFUNC, (usz)ptr);
$else
    tv.tag     = LIGHTFUNC;
    tv.pointer = ptr;
$endif
    return tv;
}

// ============================================================================
// HeapHeader — common header for all GC-managed objects
// ============================================================================

/// Discriminator for the heap-allocated object families.
/// Stored in a 2-bit field (see HeapFlags.htype), so at most 4 values.
enum HType : char {
    STRING,
    OBJECT,
    BUFFER,
    BIGINT,
}

/// Bit-packed flags stored at the front of every heap header.
///
/// Bits 0-1:  heap type (HType)
/// Bit  2:    reachable by the mark phase
/// Bit  3:    temporary root during incremental GC
/// Bit  4:    has a C finalizer attached
/// Bit  5:    the finalizer has already run
/// Bit  6:    the object is read-only
/// Bits 7-31: available for subtype-specific flags
bitstruct HeapFlags : uint {
    HType htype        : 0..1;
    bool  reachable    : 2;
    bool  temproot     : 3;
    bool  finalizable  : 4;
    bool  finalized    : 5;
    bool  readonly     : 6;
}

/// Every GC-managed object begins with this header.  The doubly-linked
/// list (next / prev) threads all live heap objects together so the
/// sweep phase can walk them.
struct HeapHeader {
    HeapFlags    flags;
    uint         refcount;
    HeapHeader*  next;
    HeapHeader*  prev;
}

// ---------------------------------------------------------------------------
// HeapHeader — type queries
// ---------------------------------------------------------------------------

/// Returns the HType stored in the flags word.
fn HType HeapHeader.get_type(&self)  { return self.flags.htype; }
/// Returns true when this header belongs to an object.
fn bool  HeapHeader.is_object(&self) { return self.flags.htype == HType.OBJECT; }
/// Returns true when this header belongs to a string.
fn bool  HeapHeader.is_string(&self) { return self.flags.htype == HType.STRING; }
/// Returns true when this header belongs to a buffer.
fn bool  HeapHeader.is_buffer(&self) { return self.flags.htype == HType.BUFFER; }
/// Returns true when this header belongs to a BigInt box.
fn bool  HeapHeader.is_bigint(&self) { return self.flags.htype == HType.BIGINT; }

/// Increments the reference count of this heap object.
/// Safe to call on null pointers (no-op).
fn void HeapHeader.incref(&self) @inline {
    self.refcount++;
}

// ---------------------------------------------------------------------------
// HeapHeader — flag accessors
// ---------------------------------------------------------------------------

/// Marks the object as reachable (used by the mark phase).
fn void HeapHeader.set_reachable(&self)     { self.flags.reachable = true; }
/// Clears the reachable flag (used before a new mark pass).
fn void HeapHeader.clear_reachable(&self)   { self.flags.reachable = false; }
/// Returns true when the object has been marked reachable.
fn bool HeapHeader.is_reachable(&self)      { return self.flags.reachable; }

/// Marks the object as a temporary root for incremental GC.
fn void HeapHeader.set_temproot(&self)      { self.flags.temproot = true; }
/// Clears the temporary-root flag.
fn void HeapHeader.clear_temproot(&self)    { self.flags.temproot = false; }
/// Returns true when the object is a temporary root.
fn bool HeapHeader.is_temproot(&self)       { return self.flags.temproot; }

/// Marks the object as having a C finalizer.
fn void HeapHeader.set_finalizable(&self)   { self.flags.finalizable = true; }
/// Clears the finalizable flag.
fn void HeapHeader.clear_finalizable(&self) { self.flags.finalizable = false; }
/// Returns true when the object has a finalizer.
fn bool HeapHeader.is_finalizable(&self)    { return self.flags.finalizable; }

/// Marks the object's finalizer as having already run.
fn void HeapHeader.set_finalized(&self)     { self.flags.finalized = true; }
/// Clears the finalized flag (re-arms the finalizer).
fn void HeapHeader.clear_finalized(&self)   { self.flags.finalized = false; }
/// Returns true when the finalizer has already executed.
fn bool HeapHeader.is_finalized(&self)      { return self.flags.finalized; }

/// Marks the object as read-only.
fn void HeapHeader.set_readonly(&self)      { self.flags.readonly = true; }
/// Clears the read-only flag.
fn void HeapHeader.clear_readonly(&self)    { self.flags.readonly = false; }
/// Returns true when the object is read-only.
fn bool HeapHeader.is_readonly(&self)       { return self.flags.readonly; }

// ---------------------------------------------------------------------------
// HeapHeader — linked-list helpers
// ---------------------------------------------------------------------------

/// Initialises the header for a freshly allocated heap object of the
/// given htype.  Links it at the head of the heap list whose current
/// head is *list_head.
fn void HeapHeader.init(&self, HType htype, HeapHeader** list_head) {
    self.flags       = {};
    self.flags.htype = htype;
    self.refcount    = 1;
    self.prev        = null;
    self.next        = *list_head;
    if (*list_head != null) {
        (*list_head).prev = self;
    }
    *list_head = self;
}

/// Unlinks this header from its doubly-linked heap list.  Callers must
/// still free the underlying memory.
fn void HeapHeader.unlink(&self, HeapHeader** list_head) {
    if (self.prev != null) {
        self.prev.next = self.next;
    } else {
        *list_head = self.next;
    }
    if (self.next != null) {
        self.next.prev = self.prev;
    }
    self.next = null;
    self.prev = null;
}
