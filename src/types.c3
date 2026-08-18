/// Core engine types: the tagged value representation (TVal), the heap object
/// header every collected allocation starts with (HeapHeader), portable type
/// aliases, numeric constants, and fault codes.
module boomkat::types;

// ============================================================================
// Portable type aliases
// ============================================================================

/// 32-bit signed integer used throughout the API.
alias BkInt       = int;
/// 32-bit unsigned integer.
alias BkUint      = uint;
/// Platform-native size type.
alias BkSize      = usz;
/// Value-stack index (signed so negative indices work).
alias BkIdx       = int;
/// Compact signed integer for space-sensitive structures.
alias BkSmallInt  = short;
/// Compact unsigned integer.
alias BkSmallUint = ushort;
/// Boolean (mirrors the built-in bool).
alias BkBool      = bool;
/// IEEE 754 double precision float.
alias BkDouble    = double;
/// Unicode codepoint (U+0000 .. U+10FFFF).
alias BkCodepoint = uint;

// ============================================================================
// Common constants
// ============================================================================

/// Maximum safe integer representable in a double (2^53 - 1).
const long   MAX_SAFE_INT    = 9007199254740991;
/// Minimum safe integer representable in a double -(2^53 - 1).
const long   MIN_SAFE_INT    = -9007199254740991;

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
// TVal, the tagged value representation
// ============================================================================

/// Discriminator for the payload stored inside a TVal.
enum TValTag : char {
    /// ECMAScript undefined.
    UNDEFINED,
    /// ECMAScript null.
    NULL_VAL,
    /// ECMAScript boolean (true / false).
    BOOLEAN,
    /// IEEE 754 double, the general ECMAScript number type.
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
    /// Internal sentinel marking a deleted array_part slot, which a stored
    /// undefined must not be confused with. Never a valid ECMAScript value.
    DELETED,
}


/// FASTINT uses 48-bit signed integer range (fits in NaN-box payload).
const long FASTINT_MIN = -140737488355328L;  // -2^47
const long FASTINT_MAX =  140737488355327L;  //  2^47 - 1

/// Toggle for NaN-boxing representation. When true, TVal is an 8-byte
/// NaN-boxed ulong. When false, TVal is the 16-byte tagged union.
/// Default is true. Pass `-D NONANBOX` to c3c to disable.
const bool USE_NANBOX = !$feature(NONANBOX);

/// When true, the VM traps if a function with needs_env=false touches its own
/// environment bindings, which catches bugs in the register-local optimization.
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

/// A tagged value. Every register, property, and stack slot holds one.
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
// TVal: tag query
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
// TVal: raw bits, for hashing and constant-pool dedup
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
// TVal: type predicates
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
    // UNDEFINED (0xFFF3) and NULL_VAL (0xFFF4) are consecutive tags, and both
    // carry a zero payload, so one range check covers them.
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

macro void TVal.set_temproot(&self) {
    if (self.is_heap_allocated()) {
        HeapHeader* hdr = (HeapHeader*)self.get_heapptr();
        if (hdr != null) {
            hdr.set_temproot();
        }
    }
}

// ---------------------------------------------------------------------------
// TVal: getters
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

/// True when both values are FASTINTs, in one branch.
/// In the NaN-box build, XORing a value's top 16 bits with TAG_FASTINT gives
/// zero exactly when it is a FASTINT, so ORing the two results is zero only
/// when both are, with no sequential dependency between them. The non-NaN-box
/// build falls back to two is_fastint() calls.
macro bool both_fastint(TVal* b, TVal* c) {
$if USE_NANBOX:
    return (((b.bits ^ (TAG_FASTINT << 48)) | (c.bits ^ (TAG_FASTINT << 48))) >> 48) == 0;
$else
    return b.is_fastint() && c.is_fastint();
$endif
}

/// True when either value is heap-allocated, in one branch.
/// Overwriting a property or array slot with a number or boolean, which is the
/// common case, needs neither an incref nor a decref. One test covers both
/// sides. The two tag extractions still happen, but they feed a single branch.
macro bool either_heap_allocated(TVal* b, TVal* c) {
    return b.is_heap_allocated() || c.is_heap_allocated();
}

// ---------------------------------------------------------------------------
// TVal: mutating setters
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

/// Store an integer result as a fastint when it fits that range, and as a double
/// otherwise. Integer arithmetic opcodes such as ADD, SUB, ADDI and SUBI write
/// their results through here rather than open-coding the range check.
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
// TVal: static constructors
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
// HeapHeader, the common header on every collected allocation
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
/// Bits 7-31: available for subtype-specific flags (see HObject's ObjFlags
///            and HString's HStringFlags, which reinterpret this same word)
bitstruct HeapFlags : uint {
    HType htype        : 0..1;
    bool  reachable    : 2;
    bool  temproot     : 3;
    bool  finalizable  : 4;
    bool  finalized    : 5;
    bool  readonly     : 6;
}

/// Sentinel refcount marking a pinned string, on which incref and decref do
/// nothing (see HeapHeader.incref and Heap.decref). It marks interned strings
/// that live as long as the heap, meaning builtin strings, well-known symbols,
/// and the small-integer cache, so a transient borrow into a register or TVal
/// needs no matching release. Always test it together with is_string(): an
/// object, buffer, or bigint can legitimately reach this refcount.
const uint STRING_PINNED_REFCOUNT = 0x7FFF_FFFF;

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
// HeapHeader: type queries
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

/// Take a reference to this heap object. Pinned strings keep their sentinel
/// refcount, so this does nothing for them. See STRING_PINNED_REFCOUNT.
fn void HeapHeader.incref(&self) @inline {
    // The refcount is tested first because it is the field about to be written
    // and so is already in hand. Every non-pinned value fails the compare and
    // skips the flags load.
    if (self.refcount == STRING_PINNED_REFCOUNT && self.is_string()) return;
    self.refcount++;
}

// ---------------------------------------------------------------------------
// HeapHeader: flag accessors
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

/// Pin a string's refcount, so incref and decref do nothing and no sweep ever
/// frees it. Strings only; see STRING_PINNED_REFCOUNT for which ones and why.
fn void HeapHeader.set_pinned(&self)        { self.refcount = STRING_PINNED_REFCOUNT; }
/// Returns true when this is a string with a pinned refcount.
fn bool HeapHeader.is_pinned(&self)         { return self.refcount == STRING_PINNED_REFCOUNT && self.is_string(); }

// ---------------------------------------------------------------------------
// HeapHeader: linked-list helpers
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
