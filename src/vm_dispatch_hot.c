/// C hot-path dispatch for the Duktape VM.
///
/// Handles runs of simple opcodes (loads, arithmetic, bitwise, comparisons,
/// jumps) in a tight C loop using a plain switch (compiled by Clang/GCC).
/// Complex opcodes (property access, calls, allocation, etc.) return control
/// to the C3 dispatch loop, which handles them and then calls back into this
/// function for the next hot run.
///
/// Opcode and Instruction encoding must match bytecode.c3 exactly:
///   op : bits 0-7, a : bits 8-15, b : bits 16-23, c : bits 24-31
///   get_bc  = bits 16-31 (unsigned 16-bit)
///   get_sbc = ((c << 8) | b) - BC_BIAS  (signed 16-bit, bias = 0x8000)
///   get_sabc = ((c << 16) | (b << 8) | a) - ABC_BIAS  (signed 24-bit)

#include <stdint.h>
#include <string.h>
#include <math.h>

// ============================================================================
// NaN-boxing constants (must match types.c3)
// ============================================================================
#define NANBOX_PAYLOAD_MASK 0x0000FFFFFFFFFFFFULL
#define TAG_FASTINT   0xFFF1ULL
#define TAG_UNDEFINED 0xFFF3ULL
#define TAG_NULL_VAL  0xFFF4ULL
#define TAG_BOOLEAN   0xFFF5ULL
#define TAG_STRING    0xFFF8ULL
#define TAG_OBJECT    0xFFF9ULL

#define FASTINT_MIN (-140737488355328LL)
#define FASTINT_MAX (140737488355327LL)

#define CANONICAL_NAN 0x7FF8000000000000ULL

// ============================================================================
// Bias constants (must match bytecode.c3)
// ============================================================================
#define BC_BIAS  0x8000
#define ABC_BIAS 0x800000

// ============================================================================
// Opcode constants (must match bytecode.c3 Opcode enum)
// ============================================================================
enum {
    OP_LDREG     = 0,
    OP_LDCONST   = 1,
    OP_LDINT     = 2,
    OP_LDINTX    = 3,
    OP_LDUNDEF   = 4,
    OP_LDNULL    = 5,
    OP_LDTRUE    = 6,
    OP_LDFALSE   = 7,
    OP_LDTHIS    = 8,
    OP_ADD       = 9,
    OP_SUB       = 10,
    OP_MUL       = 11,
    OP_DIV       = 12,
    OP_MOD       = 13,
    OP_EXP       = 14,
    OP_UNP       = 15,
    OP_UNM       = 16,
    OP_BNOT      = 17,
    OP_LNOT      = 18,
    OP_TYPEOF    = 19,
    OP_VOID      = 20,
    OP_BAND      = 21,
    OP_BOR       = 22,
    OP_BXOR      = 23,
    OP_SHL       = 24,
    OP_SHR       = 25,
    OP_USHR      = 26,
    OP_EQ        = 27,
    OP_NEQ       = 28,
    OP_SEQ       = 29,
    OP_SNEQ      = 30,
    OP_LT        = 31,
    OP_LE        = 32,
    OP_GT        = 33,
    OP_GE        = 34,
    OP_INSTANCEOF = 35,
    OP_IN        = 36,
    OP_JUMP      = 37,
    OP_IF_TRUE   = 38,
    OP_IF_FALSE  = 39,
    OP_NOP       = 66,
};

// ============================================================================
// Instruction field extraction
// ============================================================================
#define INS_OP(i)    ((uint8_t)((i) & 0xFF))
#define INS_A(i)     (((i) >> 8) & 0xFF)
#define INS_B(i)     (((i) >> 16) & 0xFF)
#define INS_C(i)     ((i) >> 24)
#define INS_BC(i)    ((i) >> 16)                              // unsigned 16-bit combined BC
#define INS_SBC(i)   ((int32_t)((i) >> 16) - BC_BIAS)          // signed 16-bit with bias
#define INS_SABC(i)  ((int32_t)((i) >> 8) - ABC_BIAS)          // signed 24-bit with bias

// ============================================================================
// NaN-boxing helpers
// ============================================================================

static inline uint64_t encode_tagged(uint64_t tag, uint64_t payload) {
    return (tag << 48) | (payload & NANBOX_PAYLOAD_MASK);
}

static inline int64_t get_fastint(uint64_t val) {
    return (int64_t)(val << 16) >> 16;
}

static inline uint64_t set_fastint(int64_t val) {
    return encode_tagged(TAG_FASTINT, (uint64_t)val);
}

static inline uint64_t set_boolean(int val) {
    return encode_tagged(TAG_BOOLEAN, val ? 1 : 0);
}

static inline double get_number(uint64_t val) {
    double d;
    memcpy(&d, &val, 8);
    return d;
}

static inline uint64_t set_number(double val) {
    uint64_t bits;
    memcpy(&bits, &val, 8);
    // NaN normalization: negative NaNs (bits 63-48 >= 0xFFF8) collide
    // with tagged values. Normalize to canonical positive NaN.
    if ((bits >> 48) >= TAG_FASTINT) {
        bits = CANONICAL_NAN;
    }
    return bits;
}

// ============================================================================
// Truthiness (matches vm.c3 is_truthy macro)
// ============================================================================

static inline int is_truthy_c(uint64_t val) {
    uint64_t tag = val >> 48;

    // undefined → falsy, null → falsy, false → falsy
    if (tag == TAG_UNDEFINED || tag == TAG_NULL_VAL)
        return 0;
    if (val == (TAG_BOOLEAN << 48))
        return 0;

    // fastint: 0 → falsy
    if (tag == TAG_FASTINT)
        return get_fastint(val) != 0;

    // double: 0.0 and NaN → falsy
    if ((val >> 48) <= 0xFFF0) {
        double d = get_number(val);
        return d != 0.0 && !isnan(d);
    }

    // string: empty → falsy (blen == 0)
    if (tag == TAG_STRING) {
        void* ptr = (void*)(uintptr_t)(val & NANBOX_PAYLOAD_MASK);
        if (!ptr) return 0;
        // HString layout: flags(4) + refcount(4) + next(8) + hash(4) + blen(4) = offset 20
        uint32_t blen = *(const uint32_t*)((const char*)ptr + 20);
        return blen > 0;
    }

    // objects, lightfuncs → truthy
    return 1;
}

// ============================================================================
// Strict equality (matches vm.c3 strict_eq for same-tag / fastint+number)
// ============================================================================

static inline int strict_eq_c(uint64_t a, uint64_t b) {
    uint64_t tag_a = a >> 48;
    uint64_t tag_b = b >> 48;

    // Different tags
    if (tag_a != tag_b) {
        // fastint ↔ number: compare as double
        if ((tag_a == TAG_FASTINT && (tag_b <= 0xFFF0)) ||
            (tag_b == TAG_FASTINT && (tag_a <= 0xFFF0))) {
            double da = (tag_a == TAG_FASTINT) ? (double)get_fastint(a) : get_number(a);
            double db = (tag_b == TAG_FASTINT) ? (double)get_fastint(b) : get_number(b);
            return da == db;
        }
        return 0;
    }

    switch (tag_a) {
    case TAG_UNDEFINED:
    case TAG_NULL_VAL:
        return 1;
    case TAG_BOOLEAN:
        return (a & NANBOX_PAYLOAD_MASK) == (b & NANBOX_PAYLOAD_MASK);
    case TAG_FASTINT:
        return get_fastint(a) == get_fastint(b);
    case TAG_STRING:
    case TAG_OBJECT:
        return (a & NANBOX_PAYLOAD_MASK) == (b & NANBOX_PAYLOAD_MASK);
    default:
        // double (regular IEEE double, tag <= 0xFFF0)
        if ((a >> 48) <= 0xFFF0) {
            double da = get_number(a);
            double db = get_number(b);
            if (isnan(da) || isnan(db)) return 0;
            return da == db;
        }
        return 0;
    }
}

// ============================================================================
// Abstract equality for hot-path types
// Returns -1 if the comparison needs C3 (boolean/string/object coercion)
// ============================================================================

static inline int abstract_eq_hot_c(uint64_t a, uint64_t b) {
    uint64_t tag_a = a >> 48;
    uint64_t tag_b = b >> 48;

    // Same type → strict equality
    if (tag_a == tag_b)
        return strict_eq_c(a, b);

    // null ↔ undefined
    if ((tag_a == TAG_NULL_VAL && tag_b == TAG_UNDEFINED) ||
        (tag_a == TAG_UNDEFINED && tag_b == TAG_NULL_VAL))
        return 1;

    // number ↔ fastint (both numeric)
    if ((tag_a <= 0xFFF0 || tag_a == TAG_FASTINT) &&
        (tag_b <= 0xFFF0 || tag_b == TAG_FASTINT)) {
        double da = (tag_a == TAG_FASTINT) ? (double)get_fastint(a) : get_number(a);
        double db = (tag_b == TAG_FASTINT) ? (double)get_fastint(b) : get_number(b);
        return da == db;
    }

    // boolean, string, object coercion → need C3
    return -1;
}

// ============================================================================
// Main hot-path dispatch
// ============================================================================
//
// Processes a run of consecutive hot opcodes.  Returns when it encounters a
// cold opcode, end of code, or an instruction that hits a slow path (e.g.
// string concatenation in ADD).
//
// Arguments:
//   regs         - register file (TVal[] as uint64_t*)
//   code         - bytecode array
//   code_len     - instruction count
//   pc           - in/out: current instruction index
//   consts       - constant pool (TVal[] as uint64_t*)
//   const_count  - number of constants
//   this_val     - current `this` binding (TVal.bits as uint64_t)
//
// Returns:
//   0  - processed at least one opcode (continue VM loop)
//   1  - current instruction at *pc is not hot (handle in C3 switch)
//  -1  - end of code reached (caller should handle normally)
//

int vm_dispatch_hot_run(
    uint64_t* restrict regs,
    const uint32_t* restrict code,
    uint32_t code_len,
    uint32_t* restrict pc,
    const uint64_t* restrict consts,
    uint32_t const_count,
    uint64_t this_val)
{
    uint32_t max_ops = 4096;
    while (*pc < code_len && max_ops-- > 0) {
        uint32_t insn = code[*pc];
        uint8_t op = INS_OP(insn);
        uint32_t a = INS_A(insn);
        uint32_t b = INS_B(insn);
        uint32_t c = INS_C(insn);

        switch (op) {

        // ---- Load / Store --------------------------------------------------

        case OP_LDREG:
            regs[a] = regs[b];
            (*pc)++;
            break;

        case OP_LDCONST: {
            uint32_t bc = INS_BC(insn);
            regs[a] = (bc < const_count) ? consts[bc] : (TAG_UNDEFINED << 48);
            (*pc)++;
            break;
        }

        case OP_LDINT: {
            // get_sbc() = raw_BC - BC_BIAS, range [-32768, 32767]
            int32_t sbc = INS_SBC(insn);
            regs[a] = set_fastint((int64_t)sbc);
            (*pc)++;
            break;
        }

        case OP_LDINTX: {
            uint32_t bc = INS_BC(insn);
            // ra = (ra.get_fastint() << 16) | BC (unsigned 16-bit OR)
            int64_t cur_fi = get_fastint(regs[a]);
            regs[a] = set_fastint((cur_fi << 16) | (int64_t)bc);
            (*pc)++;
            break;
        }

        case OP_LDUNDEF:
            regs[a] = TAG_UNDEFINED << 48;
            (*pc)++;
            break;

        case OP_LDNULL:
            regs[a] = TAG_NULL_VAL << 48;
            (*pc)++;
            break;

        case OP_LDTRUE:
            regs[a] = encode_tagged(TAG_BOOLEAN, 1);
            (*pc)++;
            break;

        case OP_LDFALSE:
            regs[a] = encode_tagged(TAG_BOOLEAN, 0);
            (*pc)++;
            break;

        case OP_LDTHIS:
            regs[a] = this_val;
            (*pc)++;
            break;

        // ---- Arithmetic ----------------------------------------------------

        case OP_ADD: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            uint64_t tag_b = vb >> 48;
            uint64_t tag_c = vc >> 48;

            if (tag_b == TAG_FASTINT && tag_c == TAG_FASTINT) {
                int64_t sum = get_fastint(vb) + get_fastint(vc);
                regs[a] = (sum >= FASTINT_MIN && sum <= FASTINT_MAX)
                    ? set_fastint(sum)
                    : set_number((double)sum);
                (*pc)++;
                break;
            }
            // Both numeric (no string) → double addition
            if ((tag_b <= 0xFFF0 || tag_b == TAG_FASTINT) &&
                (tag_c <= 0xFFF0 || tag_c == TAG_FASTINT)) {
                double db = (tag_b == TAG_FASTINT) ? (double)get_fastint(vb) : get_number(vb);
                double dc = (tag_c == TAG_FASTINT) ? (double)get_fastint(vc) : get_number(vc);
                regs[a] = set_number(db + dc);
                (*pc)++;
                break;
            }
            // String concat or other — let C3 handle
            return 1;
        }

        case OP_SUB: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            uint64_t tag_b = vb >> 48;
            uint64_t tag_c = vc >> 48;

            if (tag_b == TAG_FASTINT && tag_c == TAG_FASTINT) {
                int64_t diff = get_fastint(vb) - get_fastint(vc);
                regs[a] = (diff >= FASTINT_MIN && diff <= FASTINT_MAX)
                    ? set_fastint(diff)
                    : set_number((double)diff);
            } else {
                double db = (tag_b == TAG_FASTINT) ? (double)get_fastint(vb) : get_number(vb);
                double dc = (tag_c == TAG_FASTINT) ? (double)get_fastint(vc) : get_number(vc);
                regs[a] = set_number(db - dc);
            }
            (*pc)++;
            break;
        }

        case OP_MUL: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            uint64_t tag_b = vb >> 48;
            uint64_t tag_c = vc >> 48;

            if (tag_b == TAG_FASTINT && tag_c == TAG_FASTINT) {
                int64_t prod = get_fastint(vb) * get_fastint(vc);
                regs[a] = (prod >= FASTINT_MIN && prod <= FASTINT_MAX)
                    ? set_fastint(prod)
                    : set_number((double)prod);
            } else {
                double db = (tag_b == TAG_FASTINT) ? (double)get_fastint(vb) : get_number(vb);
                double dc = (tag_c == TAG_FASTINT) ? (double)get_fastint(vc) : get_number(vc);
                regs[a] = set_number(db * dc);
            }
            (*pc)++;
            break;
        }

        case OP_DIV: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            double db = ((vb >> 48) == TAG_FASTINT) ? (double)get_fastint(vb) : get_number(vb);
            double dc = ((vc >> 48) == TAG_FASTINT) ? (double)get_fastint(vc) : get_number(vc);
            regs[a] = set_number(db / dc);
            (*pc)++;
            break;
        }

        case OP_MOD: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            uint64_t tag_b = vb >> 48;
            uint64_t tag_c = vc >> 48;

            if (tag_b == TAG_FASTINT && tag_c == TAG_FASTINT) {
                int64_t divisor = get_fastint(vc);
                if (divisor != 0) {
                    regs[a] = set_fastint(get_fastint(vb) % divisor);
                    (*pc)++;
                    break;
                }
            }
            double db = (tag_b == TAG_FASTINT) ? (double)get_fastint(vb) : get_number(vb);
            double dc = (tag_c == TAG_FASTINT) ? (double)get_fastint(vc) : get_number(vc);
            regs[a] = set_number(fmod(db, dc));
            (*pc)++;
            break;
        }

        case OP_EXP: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            double db = ((vb >> 48) == TAG_FASTINT) ? (double)get_fastint(vb) : get_number(vb);
            double dc = ((vc >> 48) == TAG_FASTINT) ? (double)get_fastint(vc) : get_number(vc);
            regs[a] = set_number(pow(db, dc));
            (*pc)++;
            break;
        }

        // ---- Unary ---------------------------------------------------------

        case OP_UNP: {
            uint64_t vb = regs[b];
            regs[a] = ((vb >> 48) == TAG_FASTINT) ? vb : set_number(get_number(vb));
            (*pc)++;
            break;
        }

        case OP_UNM: {
            uint64_t vb = regs[b];
            if ((vb >> 48) == TAG_FASTINT) {
                regs[a] = set_fastint(-get_fastint(vb));
            } else {
                regs[a] = set_number(-get_number(vb));
            }
            (*pc)++;
            break;
        }

        case OP_BNOT: {
            uint64_t vb = regs[b];
            int32_t val = ((vb >> 48) == TAG_FASTINT)
                ? (int32_t)get_fastint(vb)
                : (int32_t)get_number(vb);
            regs[a] = set_fastint((int64_t)(~val));
            (*pc)++;
            break;
        }

        case OP_LNOT:
            regs[a] = set_boolean(!is_truthy_c(regs[b]));
            (*pc)++;
            break;

        case OP_VOID:
            regs[a] = TAG_UNDEFINED << 48;
            (*pc)++;
            break;

        // ---- Bitwise -------------------------------------------------------

        case OP_BAND: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            int32_t bv = ((vb >> 48) == TAG_FASTINT) ? (int32_t)get_fastint(vb) : (int32_t)get_number(vb);
            int32_t cv = ((vc >> 48) == TAG_FASTINT) ? (int32_t)get_fastint(vc) : (int32_t)get_number(vc);
            regs[a] = set_fastint((int64_t)(bv & cv));
            (*pc)++;
            break;
        }

        case OP_BOR: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            int32_t bv = ((vb >> 48) == TAG_FASTINT) ? (int32_t)get_fastint(vb) : (int32_t)get_number(vb);
            int32_t cv = ((vc >> 48) == TAG_FASTINT) ? (int32_t)get_fastint(vc) : (int32_t)get_number(vc);
            regs[a] = set_fastint((int64_t)(bv | cv));
            (*pc)++;
            break;
        }

        case OP_BXOR: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            int32_t bv = ((vb >> 48) == TAG_FASTINT) ? (int32_t)get_fastint(vb) : (int32_t)get_number(vb);
            int32_t cv = ((vc >> 48) == TAG_FASTINT) ? (int32_t)get_fastint(vc) : (int32_t)get_number(vc);
            regs[a] = set_fastint((int64_t)(bv ^ cv));
            (*pc)++;
            break;
        }

        case OP_SHL: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            int32_t bv = ((vb >> 48) == TAG_FASTINT) ? (int32_t)get_fastint(vb) : (int32_t)get_number(vb);
            int32_t cv = ((vc >> 48) == TAG_FASTINT) ? (int32_t)get_fastint(vc) : (int32_t)get_number(vc);
            regs[a] = set_fastint((int64_t)(bv << (cv & 0x1F)));
            (*pc)++;
            break;
        }

        case OP_SHR: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            int32_t bv = ((vb >> 48) == TAG_FASTINT) ? (int32_t)get_fastint(vb) : (int32_t)get_number(vb);
            int32_t cv = ((vc >> 48) == TAG_FASTINT) ? (int32_t)get_fastint(vc) : (int32_t)get_number(vc);
            regs[a] = set_fastint((int64_t)(bv >> (cv & 0x1F)));
            (*pc)++;
            break;
        }

        case OP_USHR: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            uint32_t bv = ((vb >> 48) == TAG_FASTINT)
                ? (uint32_t)get_fastint(vb)
                : (uint32_t)(int32_t)get_number(vb);
            int32_t cv = ((vc >> 48) == TAG_FASTINT) ? (int32_t)get_fastint(vc) : (int32_t)get_number(vc);
            regs[a] = set_fastint((int64_t)(bv >> (cv & 0x1F)));
            (*pc)++;
            break;
        }

        // ---- Comparison ----------------------------------------------------

        case OP_EQ: {
            int result = abstract_eq_hot_c(regs[b], regs[c]);
            if (result < 0) return 1;  // needs C3 for type coercion
            regs[a] = set_boolean(result);
            (*pc)++;
            break;
        }

        case OP_NEQ: {
            int result = abstract_eq_hot_c(regs[b], regs[c]);
            if (result < 0) return 1;
            regs[a] = set_boolean(!result);
            (*pc)++;
            break;
        }

        case OP_SEQ:
            regs[a] = set_boolean(strict_eq_c(regs[b], regs[c]));
            (*pc)++;
            break;

        case OP_SNEQ:
            regs[a] = set_boolean(!strict_eq_c(regs[b], regs[c]));
            (*pc)++;
            break;

        case OP_LT: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            uint64_t tag_b = vb >> 48;
            uint64_t tag_c = vc >> 48;

            if (tag_b == TAG_STRING || tag_c == TAG_STRING)
                return 1;  // string comparison needs C3

            if (tag_b == TAG_FASTINT && tag_c == TAG_FASTINT) {
                regs[a] = set_boolean(get_fastint(vb) < get_fastint(vc));
            } else {
                double db = (tag_b == TAG_FASTINT) ? (double)get_fastint(vb) : get_number(vb);
                double dc = (tag_c == TAG_FASTINT) ? (double)get_fastint(vc) : get_number(vc);
                regs[a] = set_boolean(db < dc);
            }
            (*pc)++;
            break;
        }

        case OP_LE: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            uint64_t tag_b = vb >> 48;
            uint64_t tag_c = vc >> 48;

            if (tag_b == TAG_STRING || tag_c == TAG_STRING)
                return 1;

            if (tag_b == TAG_FASTINT && tag_c == TAG_FASTINT) {
                regs[a] = set_boolean(get_fastint(vb) <= get_fastint(vc));
            } else {
                double db = (tag_b == TAG_FASTINT) ? (double)get_fastint(vb) : get_number(vb);
                double dc = (tag_c == TAG_FASTINT) ? (double)get_fastint(vc) : get_number(vc);
                regs[a] = set_boolean(db <= dc);
            }
            (*pc)++;
            break;
        }

        case OP_GT: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            uint64_t tag_b = vb >> 48;
            uint64_t tag_c = vc >> 48;

            if (tag_b == TAG_STRING || tag_c == TAG_STRING)
                return 1;

            if (tag_b == TAG_FASTINT && tag_c == TAG_FASTINT) {
                regs[a] = set_boolean(get_fastint(vb) > get_fastint(vc));
            } else {
                double db = (tag_b == TAG_FASTINT) ? (double)get_fastint(vb) : get_number(vb);
                double dc = (tag_c == TAG_FASTINT) ? (double)get_fastint(vc) : get_number(vc);
                regs[a] = set_boolean(db > dc);
            }
            (*pc)++;
            break;
        }

        case OP_GE: {
            uint64_t vb = regs[b];
            uint64_t vc = regs[c];
            uint64_t tag_b = vb >> 48;
            uint64_t tag_c = vc >> 48;

            if (tag_b == TAG_STRING || tag_c == TAG_STRING)
                return 1;

            if (tag_b == TAG_FASTINT && tag_c == TAG_FASTINT) {
                regs[a] = set_boolean(get_fastint(vb) >= get_fastint(vc));
            } else {
                double db = (tag_b == TAG_FASTINT) ? (double)get_fastint(vb) : get_number(vb);
                double dc = (tag_c == TAG_FASTINT) ? (double)get_fastint(vc) : get_number(vc);
                regs[a] = set_boolean(db >= dc);
            }
            (*pc)++;
            break;
        }

        // ---- Control flow --------------------------------------------------

        case OP_JUMP: {
            int32_t sabc = INS_SABC(insn);
            // sabc is relative to the NEXT instruction (after current)
            int32_t offset = (int32_t)*pc;          // current index
            int32_t target = offset + 1 + sabc;      // +1 for "next instruction" base
            if (target < 0 || target >= (int32_t)code_len)
                return 1;  // bounds check — let C3 handle error
            *pc = (uint32_t)target;
            break;  // continue processing from target
        }

        case OP_IF_TRUE: {
            uint64_t cond = regs[a];
            if (is_truthy_c(cond)) {
                int32_t sbx = INS_SBC(insn);
                int32_t offset = (int32_t)*pc;
                int32_t target = offset + 1 + sbx;
                if (target < 0 || target >= (int32_t)code_len)
                    return 1;
                *pc = (uint32_t)target;
            } else {
                (*pc)++;
            }
            break;
        }

        case OP_IF_FALSE: {
            uint64_t cond = regs[a];
            if (!is_truthy_c(cond)) {
                int32_t sbx = INS_SBC(insn);
                int32_t offset = (int32_t)*pc;
                int32_t target = offset + 1 + sbx;
                if (target < 0 || target >= (int32_t)code_len)
                    return 1;
                *pc = (uint32_t)target;
            } else {
                (*pc)++;
            }
            break;
        }

        // ---- Misc ----------------------------------------------------------

        case OP_NOP:
            (*pc)++;
            break;

        default:
            return 1;  // not a hot opcode
        }
    }
    return -1;  // end of code or max_ops hit
}
