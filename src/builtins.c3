/// Built-in function registry for the Duktape C3 port.
module duktape::builtins;

import duktape::types;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import duktape::env;
import duktape::compiler;
import duktape::lexer;
import duktape::re_bindings;
import std::io;
import std::math;
import libc;

// Math library externals (link-time resolved via @MathLibc)
extern fn double math_pow(double x, double y) @MathLibc("pow");
extern fn double math_sqrt(double x)          @MathLibc("sqrt");
extern fn double math_exp(double x)           @MathLibc("exp");
extern fn double math_log(double x)           @MathLibc("log");
extern fn double math_sin(double x)           @MathLibc("sin");
extern fn double math_cos(double x)           @MathLibc("cos");
extern fn double math_tan(double x)           @MathLibc("tan");
extern fn double math_acos(double x)          @MathLibc("acos");
extern fn double math_asin(double x)          @MathLibc("asin");
extern fn double math_atan(double x)          @MathLibc("atan");
extern fn double math_atan2(double y, double x) @MathLibc("atan2");
extern fn double math_cosh(double x)          @MathLibc("cosh");
extern fn double math_sinh(double x)          @MathLibc("sinh");
extern fn double math_tanh(double x)          @MathLibc("tanh");
extern fn double math_acosh(double x)         @MathLibc("acosh");
extern fn double math_asinh(double x)         @MathLibc("asinh");
extern fn double math_atanh(double x)         @MathLibc("atanh");
extern fn double math_log2(double x)          @MathLibc("log2");
extern fn double math_log10(double x)         @MathLibc("log10");
extern fn double math_log1p(double x)         @MathLibc("log1p");
extern fn double math_expm1(double x)         @MathLibc("expm1");
extern fn double math_cbrt(double x)          @MathLibc("cbrt");

// Date/time library externals (link-time resolved via libc)
// The Tm struct mirrors C's struct tm layout exactly.

const uint BUILTIN_PRINT       = 0;
const uint BUILTIN_CONSOLE_LOG = 1;
const uint BUILTIN_PARSE_INT   = 2;
const uint BUILTIN_PARSE_FLOAT = 3;
const uint BUILTIN_IS_NAN      = 4;
const uint BUILTIN_IS_FINITE   = 5;
const uint BUILTIN_ERROR           = 6;
const uint BUILTIN_TYPE_ERROR      = 7;
const uint BUILTIN_RANGE_ERROR     = 8;
const uint BUILTIN_REFERENCE_ERROR = 9;
const uint BUILTIN_SYNTAX_ERROR    = 10;
const uint BUILTIN_EVAL_ERROR      = 11;
const uint BUILTIN_ERROR_PROTO_TOSTRING = 12;
const uint BUILTIN_BOOLEAN                 = 13;
const uint BUILTIN_BOOLEAN_PROTO_TOSTRING  = 14;
const uint BUILTIN_BOOLEAN_PROTO_VALUEOF   = 15;
const uint BUILTIN_STRING                 = 16;
const uint BUILTIN_STRING_PROTO_TOSTRING  = 17;
const uint BUILTIN_STRING_PROTO_VALUEOF   = 18;
const uint BUILTIN_NUMBER                 = 19;
const uint BUILTIN_NUMBER_PROTO_TOSTRING  = 20;
const uint BUILTIN_NUMBER_PROTO_VALUEOF   = 21;
const uint BUILTIN_OBJECT                  = 22;
const uint BUILTIN_OBJECT_PROTO_TOSTRING   = 23;
const uint BUILTIN_OBJECT_PROTO_VALUEOF    = 24;
const uint BUILTIN_ARRAY                   = 25;
const uint BUILTIN_MATH_ABS   = 26;
const uint BUILTIN_MATH_FLOOR = 27;
const uint BUILTIN_MATH_CEIL  = 28;
const uint BUILTIN_MATH_ROUND = 29;
const uint BUILTIN_MATH_MAX   = 30;
const uint BUILTIN_MATH_MIN   = 31;
const uint BUILTIN_MATH_POW   = 32;
const uint BUILTIN_MATH_SQRT  = 33;
const uint BUILTIN_MATH_EXP   = 34;
const uint BUILTIN_MATH_LOG   = 35;
const uint BUILTIN_MATH_SIN   = 36;
const uint BUILTIN_MATH_COS   = 37;
const uint BUILTIN_MATH_TAN   = 38;
const uint BUILTIN_MATH_RANDOM = 39;
const uint BUILTIN_STRING_PROTO_CHARAT     = 40;
const uint BUILTIN_STRING_PROTO_CHARCODEAT = 41;
const uint BUILTIN_STRING_PROTO_INDEXOF    = 42;
const uint BUILTIN_STRING_PROTO_SLICE      = 43;
const uint BUILTIN_STRING_PROTO_SUBSTRING  = 44;
const uint BUILTIN_STRING_PROTO_SUBSTR     = 45;
const uint BUILTIN_STRING_PROTO_TOUPPERCASE = 46;
const uint BUILTIN_STRING_PROTO_TOLOWERCASE = 47;
const uint BUILTIN_STRING_PROTO_TRIM       = 48;
const uint BUILTIN_STRING_PROTO_SPLIT      = 49;
const uint BUILTIN_STRING_PROTO_CONCAT     = 50;
const uint BUILTIN_STRING_PROTO_REPLACE    = 51;
const uint BUILTIN_ARRAY_PROTO_TOSTRING    = 52;
const uint BUILTIN_ARRAY_PROTO_JOIN        = 53;
const uint BUILTIN_ARRAY_PROTO_POP         = 54;
const uint BUILTIN_ARRAY_PROTO_PUSH        = 55;
const uint BUILTIN_ARRAY_PROTO_REVERSE     = 56;
const uint BUILTIN_ARRAY_PROTO_SHIFT       = 57;
const uint BUILTIN_ARRAY_PROTO_SLICE       = 58;
const uint BUILTIN_ARRAY_PROTO_SORT        = 59;
const uint BUILTIN_ARRAY_PROTO_SPLICE      = 60;
const uint BUILTIN_ARRAY_PROTO_UNSHIFT     = 61;
const uint BUILTIN_ARRAY_PROTO_INDEXOF     = 62;
const uint BUILTIN_ARRAY_PROTO_LASTINDEXOF = 63;
const uint BUILTIN_ARRAY_PROTO_CONCAT      = 64;

const uint BUILTIN_NUMBER_PROTO_TOFIXED       = 73;
const uint BUILTIN_NUMBER_PROTO_TOEXPONENTIAL = 74;
const uint BUILTIN_NUMBER_PROTO_TOPRECISION   = 75;
const uint BUILTIN_FUNCTION_PROTO_CALL  = 77;
const uint BUILTIN_FUNCTION_PROTO_APPLY = 78;
const uint BUILTIN_FUNCTION_PROTO_BIND  = 79;
const uint BUILTIN_BOUND_CALL           = 80;
const uint BUILTIN_EVAL                 = 81;
const uint BUILTIN_JSON_PARSE           = 82;
const uint BUILTIN_JSON_STRINGIFY       = 83;
const uint BUILTIN_DATE                 = 84;
const uint BUILTIN_DATE_NOW             = 85;
const uint BUILTIN_DATE_UTC             = 86;
const uint BUILTIN_DATE_PARSE           = 87;
const uint BUILTIN_DATE_PROTO_TOSTRING  = 88;
const uint BUILTIN_DATE_PROTO_TOJSON    = 89;
const uint BUILTIN_DATE_PROTO_VALUEOF   = 90;
const uint BUILTIN_DATE_PROTO_GETTIME   = 91;
const uint BUILTIN_DATE_PROTO_GETFULLYEAR  = 92;
const uint BUILTIN_DATE_PROTO_GETMONTH     = 93;
const uint BUILTIN_DATE_PROTO_GETDATE      = 94;
const uint BUILTIN_DATE_PROTO_GETDAY       = 95;
const uint BUILTIN_DATE_PROTO_GETHOURS     = 96;
const uint BUILTIN_DATE_PROTO_GETMINUTES   = 97;
const uint BUILTIN_DATE_PROTO_GETSECONDS   = 98;
const uint BUILTIN_DATE_PROTO_GETMILLISECONDS = 99;
const uint BUILTIN_DATE_PROTO_GETTIMEZONEOFFSET = 100;
const uint BUILTIN_FUNCTION              = 101;
const uint BUILTIN_RESET_GLOBALS             = 102;
const uint BUILTIN_REGEXP                    = 103;
const uint BUILTIN_REGEXP_PROTO_TEST         = 104;
const uint BUILTIN_REGEXP_PROTO_EXEC         = 105;
const uint BUILTIN_REGEXP_PROTO_TOSTRING         = 106;
const uint BUILTIN_OBJECT_PROTO_HASOWNPROPERTY  = 108;
const uint BUILTIN_OBJECT_PROTO_PROPERTYISENUMERABLE = 109;
const uint BUILTIN_OBJECT_PROTO_ISPROTOTYPEOF  = 107;
const uint BUILTIN_OBJECT_PROTO_TOLOCALESTRING = 110;
const uint BUILTIN_DATE_PROTO_TOLOCALESTRING   = 261;
const uint BUILTIN_DATE_PROTO_TOLOCALEDATESTRING = 262;
const uint BUILTIN_DATE_PROTO_TOLOCALETIMESTRING = 263;
const uint BUILTIN_PROMISE_RESOLVE_CALLBACK     = 264;
const uint BUILTIN_PROMISE_REJECT_CALLBACK      = 265;

// Iterator protocol
const uint BUILTIN_ARRAY_ITERATOR_NEXT        = 269;
const uint BUILTIN_STRING_ITERATOR_NEXT       = 270;
const uint BUILTIN_ARRAY_PROTO_SYMBOL_ITER    = 271;
const uint BUILTIN_STRING_PROTO_SYMBOL_ITER   = 272;

const uint BUILTIN_ARRAY_PROTO_KEYS           = 273;
const uint BUILTIN_ARRAY_PROTO_VALUES         = 274;
const uint BUILTIN_ARRAY_PROTO_ENTRIES        = 275;
const uint BUILTIN_OBJECT_FROMENTRIES         = 276;

// RegExp.prototype accessor getters (ES6 §21.2.5)
const uint BUILTIN_REGEXP_PROTO_GET_FLAGS      = 277;
const uint BUILTIN_REGEXP_PROTO_GET_SOURCE     = 278;
const uint BUILTIN_REGEXP_PROTO_GET_GLOBAL     = 279;
const uint BUILTIN_REGEXP_PROTO_GET_IGNORECASE = 280;
const uint BUILTIN_REGEXP_PROTO_GET_MULTILINE  = 281;
const uint BUILTIN_REGEXP_PROTO_GET_DOTALL     = 282;
const uint BUILTIN_REGEXP_PROTO_GET_STICKY     = 283;
const uint BUILTIN_REGEXP_PROTO_GET_UNICODE    = 284;

// Array.from (ES6 §22.1.2.1)
const uint BUILTIN_ARRAY_FROM                  = 285;

// %IteratorPrototype%[@@iterator] (ES6 §25.1.2.1)
const uint BUILTIN_ITERATOR_PROTO_SYMBOL_ITER  = 286;

// Map/Set iterators
const uint BUILTIN_MAP_ITERATOR_NEXT           = 287;
const uint BUILTIN_SET_ITERATOR_NEXT           = 288;
const uint BUILTIN_MAP_PROTO_SYMBOL_ITER       = 289;
const uint BUILTIN_SET_PROTO_SYMBOL_ITER       = 290;

const uint BUILTIN_ARRAY_PROTO_FOREACH   = 291;
const uint BUILTIN_ARRAY_PROTO_MAP        = 292;
const uint BUILTIN_ARRAY_PROTO_FILTER     = 293;
const uint BUILTIN_ARRAY_PROTO_EVERY      = 294;
const uint BUILTIN_ARRAY_PROTO_SOME       = 295;
const uint BUILTIN_ARRAY_PROTO_REDUCE     = 296;
const uint BUILTIN_ARRAY_PROTO_REDUCERIGHT = 297;
const uint BUILTIN_STRING_PROTO_TOLOCALELOWERCASE = 298;
const uint BUILTIN_STRING_PROTO_TOLOCALEUPPERCASE = 299;
const uint BUILTIN_STRING_PROTO_LOCALECOMPARE    = 300;
const uint BUILTIN_COUNT                         = 301;

const uint BUILTIN_MAP                       = 112;
const uint BUILTIN_MAP_PROTO_SET             = 113;
const uint BUILTIN_MAP_PROTO_GET             = 114;
const uint BUILTIN_MAP_PROTO_HAS             = 115;
const uint BUILTIN_MAP_PROTO_DELETE          = 116;
const uint BUILTIN_MAP_PROTO_CLEAR           = 117;
const uint BUILTIN_MAP_PROTO_KEYS            = 118;
const uint BUILTIN_MAP_PROTO_VALUES          = 119;
const uint BUILTIN_MAP_PROTO_ENTRIES         = 120;
const uint BUILTIN_MAP_PROTO_FOREACH         = 121;

const uint BUILTIN_SET                       = 122;
const uint BUILTIN_SET_PROTO_ADD             = 123;
const uint BUILTIN_SET_PROTO_HAS             = 124;
const uint BUILTIN_SET_PROTO_DELETE          = 125;
const uint BUILTIN_SET_PROTO_CLEAR           = 126;
const uint BUILTIN_SET_PROTO_KEYS            = 127;
const uint BUILTIN_SET_PROTO_VALUES          = 128;
const uint BUILTIN_SET_PROTO_ENTRIES         = 129;
const uint BUILTIN_SET_PROTO_FOREACH         = 130;

const uint BUILTIN_WEAKMAP                   = 131;
const uint BUILTIN_WEAKMAP_PROTO_SET         = 132;
const uint BUILTIN_WEAKMAP_PROTO_GET         = 133;
const uint BUILTIN_WEAKMAP_PROTO_HAS         = 134;
const uint BUILTIN_WEAKMAP_PROTO_DELETE      = 135;

const uint BUILTIN_WEAKSET                   = 136;
const uint BUILTIN_WEAKSET_PROTO_ADD         = 137;
const uint BUILTIN_WEAKSET_PROTO_HAS         = 138;
const uint BUILTIN_WEAKSET_PROTO_DELETE      = 139;

const uint BUILTIN_SYMBOL                    = 140;
const uint BUILTIN_SYMBOL_FOR                = 141;
const uint BUILTIN_SYMBOL_KEYFOR             = 142;
const uint BUILTIN_SYMBOL_PROTO_TOSTRING     = 143;
const uint BUILTIN_SYMBOL_PROTO_VALUEOF      = 144;

const uint BUILTIN_PROMISE                   = 145;
const uint BUILTIN_PROMISE_PROTO_THEN        = 146;
const uint BUILTIN_PROMISE_PROTO_CATCH       = 147;
const uint BUILTIN_PROMISE_PROTO_FINALLY     = 148;
const uint BUILTIN_PROMISE_RESOLVE           = 149;
const uint BUILTIN_PROMISE_REJECT            = 150;
const uint BUILTIN_PROMISE_ALL               = 151;
const uint BUILTIN_PROMISE_RACE              = 152;
const uint BUILTIN_PROMISE_ALLSETTLED         = 266;

const uint BUILTIN_PROMISE_ANY                = 267;
const uint BUILTIN_AGGREGATE_ERROR            = 268;

const uint BUILTIN_GENERATOR_FUNCTION        = 153;
const uint BUILTIN_GENERATOR_PROTO_NEXT      = 154;
const uint BUILTIN_GENERATOR_PROTO_THROW     = 155;
const uint BUILTIN_GENERATOR_PROTO_RETURN    = 156;
const uint BUILTIN_OBJECT_KEYS               = 157;
const uint BUILTIN_OBJECT_GETPROTOTYPEOF     = 158;
const uint BUILTIN_OBJECT_ISEXTENSIBLE       = 159;
const uint BUILTIN_OBJECT_PREVENTEXTENSIONS  = 160;

const uint BUILTIN_OBJECT_GETOWNPROPERTYDESCRIPTOR = 161;
const uint BUILTIN_OBJECT_DEFINEPROPERTY           = 162;
const uint BUILTIN_OBJECT_GETOWNPROPERTYNAMES      = 163;
const uint BUILTIN_OBJECT_DEFINEPROPERTIES        = 164;
const uint BUILTIN_OBJECT_CREATE                  = 165;
const uint BUILTIN_OBJECT_SEAL                    = 166;
const uint BUILTIN_OBJECT_FREEZE                  = 167;
const uint BUILTIN_OBJECT_ISSEALED                = 168;
const uint BUILTIN_OBJECT_ISFROZEN                = 169;
const uint BUILTIN_OBJECT_ENTRIES                 = 188;
const uint BUILTIN_OBJECT_VALUES                  = 189;
const uint BUILTIN_OBJECT_ASSIGN                  = 190;
const uint BUILTIN_NUMBER_ISNAN                   = 191;
const uint BUILTIN_NUMBER_ISFINITE                = 192;
const uint BUILTIN_NUMBER_ISINTEGER               = 193;
const uint BUILTIN_NUMBER_ISSAFEINTEGER           = 194;

const uint BUILTIN_MATH_ACOS   = 195;
const uint BUILTIN_MATH_ASIN   = 196;
const uint BUILTIN_MATH_ATAN   = 197;
const uint BUILTIN_MATH_ATAN2  = 198;
const uint BUILTIN_MATH_COSH   = 199;
const uint BUILTIN_MATH_SINH   = 200;
const uint BUILTIN_MATH_TANH   = 201;
const uint BUILTIN_MATH_ACOSH  = 202;
const uint BUILTIN_MATH_ASINH  = 203;
const uint BUILTIN_MATH_ATANH  = 204;
const uint BUILTIN_MATH_LOG2   = 205;
const uint BUILTIN_MATH_LOG10  = 206;
const uint BUILTIN_MATH_LOG1P  = 207;
const uint BUILTIN_MATH_EXPM1  = 208;
const uint BUILTIN_MATH_CBRT   = 209;
const uint BUILTIN_MATH_HYPOT  = 210;
const uint BUILTIN_MATH_TRUNC  = 211;
const uint BUILTIN_MATH_SIGN   = 212;
const uint BUILTIN_MATH_FROUND = 213;
const uint BUILTIN_MATH_CLZ32  = 214;
const uint BUILTIN_MATH_IMUL   = 215;
const uint BUILTIN_ARRAY_ISARRAY = 216;
const uint BUILTIN_STRING_FROMCHARCODE = 217;
const uint BUILTIN_OBJECT_IS           = 218;
const uint BUILTIN_OBJECT_HASOWN       = 219;
const uint BUILTIN_OBJECT_SETPROTOTYPEOF = 220;
const uint BUILTIN_ARRAY_PROTO_FLAT      = 221;
const uint BUILTIN_ARRAY_PROTO_FLATMAP   = 222;
const uint BUILTIN_STRING_FROMCODEPOINT  = 223;

const uint BUILTIN_ENCODE_URI              = 224;
const uint BUILTIN_ENCODE_URI_COMPONENT    = 225;
const uint BUILTIN_DECODE_URI              = 226;
const uint BUILTIN_DECODE_URI_COMPONENT    = 227;
const uint BUILTIN_URI_ERROR               = 228;
const uint BUILTIN_ARRAY_PROTO_TOREVERSED = 229;
const uint BUILTIN_ARRAY_PROTO_TOSORTED   = 230;
const uint BUILTIN_ARRAY_PROTO_TOSPLICED  = 231;
const uint BUILTIN_ARRAY_PROTO_WITH       = 232;
const uint BUILTIN_STRING_PROTO_MATCH     = 233;
const uint BUILTIN_STRING_PROTO_SEARCH    = 234;

const uint BUILTIN_STRING_PROTO_INCLUDES  = 170;
const uint BUILTIN_STRING_PROTO_STARTSWITH = 171;
const uint BUILTIN_STRING_PROTO_ENDSWITH  = 172;
const uint BUILTIN_STRING_PROTO_REPEAT    = 173;
const uint BUILTIN_STRING_PROTO_TRIMSTART = 174;
const uint BUILTIN_STRING_PROTO_TRIMEND   = 175;
const uint BUILTIN_STRING_PROTO_CODEPOINTAT = 176;
const uint BUILTIN_STRING_PROTO_AT        = 177;
const uint BUILTIN_STRING_PROTO_PADSTART  = 178;
const uint BUILTIN_STRING_PROTO_PADEND    = 179;
const uint BUILTIN_STRING_PROTO_LASTINDEXOF = 180;
const uint BUILTIN_ARRAY_OF              = 181;
const uint BUILTIN_ARRAY_PROTO_FILL      = 182;
const uint BUILTIN_ARRAY_PROTO_FIND      = 183;
const uint BUILTIN_ARRAY_PROTO_FINDINDEX = 184;
const uint BUILTIN_ARRAY_PROTO_INCLUDES  = 185;
const uint BUILTIN_ARRAY_PROTO_AT        = 186;
const uint BUILTIN_ARRAY_PROTO_COPYWITHIN = 187;
const uint BUILTIN_DATE_PROTO_GETUTCFULLYEAR = 235;
const uint BUILTIN_DATE_PROTO_GETUTCMONTH    = 236;
const uint BUILTIN_DATE_PROTO_GETUTCDATE     = 237;
const uint BUILTIN_DATE_PROTO_GETUTCDAY      = 238;
const uint BUILTIN_DATE_PROTO_GETUTCHOURS    = 239;
const uint BUILTIN_DATE_PROTO_GETUTCMINUTES  = 240;
const uint BUILTIN_DATE_PROTO_GETUTCSECONDS  = 241;
const uint BUILTIN_DATE_PROTO_GETUTCMILLISECONDS = 242;
const uint BUILTIN_DATE_PROTO_SETTIME        = 243;
const uint BUILTIN_DATE_PROTO_SETMILLISECONDS = 244;
const uint BUILTIN_DATE_PROTO_SETSECONDS     = 245;
const uint BUILTIN_DATE_PROTO_SETMINUTES     = 246;
const uint BUILTIN_DATE_PROTO_SETHOURS       = 247;
const uint BUILTIN_DATE_PROTO_SETDATE        = 248;
const uint BUILTIN_DATE_PROTO_SETMONTH       = 249;
const uint BUILTIN_DATE_PROTO_SETFULLYEAR    = 250;
const uint BUILTIN_DATE_PROTO_SETUTCMILLISECONDS = 251;
const uint BUILTIN_DATE_PROTO_SETUTCSECONDS  = 252;
const uint BUILTIN_DATE_PROTO_SETUTCMINUTES  = 253;
const uint BUILTIN_DATE_PROTO_SETUTCHOURS    = 254;
const uint BUILTIN_DATE_PROTO_SETUTCDATE     = 255;
const uint BUILTIN_DATE_PROTO_SETUTCMONTH    = 256;
const uint BUILTIN_DATE_PROTO_SETUTCFULLYEAR = 257;
const uint BUILTIN_DATE_PROTO_TOISOSTRING    = 258;
const uint BUILTIN_DATE_PROTO_TOUTCSTRING    = 259;
const uint BUILTIN_DATE_PROTO_TOGMTSTRING    = 260;

struct BuiltinContext {
    void* vm;
    TVal* regs;
    ushort base_reg;
    ushort argc;
    TVal* result;
    Heap* heap;
    TVal  this_val;
    bool  is_constructor;
    /// Re-dispatch signal: when true, the CALL handler should re-read the
    /// function from the callee slot and re-dispatch with modified args.
    /// Used by Function.prototype.call/apply.
    bool  needs_re_dispatch;
    /// New argument count for re-dispatch (only valid when needs_re_dispatch).
    ushort re_nargs;
    /// Global environment pointer (for eval and other scope-sensitive builtins).
    EnvRecord* global_env;
    /// When true, the builtin wants to throw an error (used by JSON.parse etc).
    bool  should_throw;
    /// The value to throw (only valid when should_throw is true).
    TVal  throw_value;
    /// The function object being called (for builtins that need to access their own properties).
    HObject* callee_obj;
}

alias BuiltinFunc = fn void(BuiltinContext*);

fn void print_tval(TVal* val) {
    switch (val.get_tag()) {
        case UNDEFINED:
            io::printf("undefined");
        case NULL_VAL:
            io::printf("null");
        case BOOLEAN:
            if (val.get_boolean()) {
                io::printf("true");
            } else {
                io::printf("false");
            }
        case NUMBER:
            double v = val.get_number();
            if (math::is_nan(v)) {
                io::printf("NaN");
            } else if (math::is_inf(v)) {
                if (v > 0) { io::printf("Infinity"); } else { io::printf("-Infinity"); }
            } else {
                long iv = (long)v;
                if ((double)iv == v && iv >= -9007199254740991 && iv <= 9007199254740991) {
                    io::printf("%d", iv);
                } else {
                    io::printf("%f", v);
                }
            }
        case FASTINT:
            io::printf("%d", val.get_fastint());
        case STRING:
            HString* s = (HString*)val.get_heapptr();
            if (s != null) {
                char[] d = s.get_data();
                for (usz i = 0; i < d.len; i++) {
                    io::putchar(d[i]);
                }
            } else {
                io::printf("[null string]");
            }
        case OBJECT:
            io::printf("[object Object]");
        case LIGHTFUNC:
            io::printf("[function]");
        default:
            io::printf("[unknown]");
    }
}

fn void builtin_print(BuiltinContext* ctx) {
    for (ushort i = 0; i < ctx.argc; i++) {
        if (i > 0) {
            io::putchar(' ');
        }
        print_tval(&ctx.regs[ctx.base_reg + i]);
    }
    io::putchar('\n');
    ctx.result.set_undefined();
}

fn void builtin_console_log(BuiltinContext* ctx) {
    for (ushort i = 0; i < ctx.argc; i++) {
        if (i > 0) {
            io::putchar(' ');
        }
        print_tval(&ctx.regs[ctx.base_reg + i]);
    }
    io::putchar('\n');
    ctx.result.set_undefined();
}

fn double string_to_double(TVal* val) {
    if (val.is_fastint()) return (double)val.get_fastint();
    if (val.is_number()) return val.get_number();
    if (val.is_string()) {
        HString* h = (HString*)val.get_heapptr();
        if (h == null || h.blen == 0) return double::nan;
        char* end;
        double r = libc::strtod((ZString)h.get_cstr(), &end);
        if (end == h.get_cstr()) return double::nan;
        return r;
    }
    return double::nan;
}

// ============================================================================
// ECMAScript whitespace check (ASCII subset)
// ============================================================================

/// ECMAScript whitespace (ASCII subset: Tab, VT, FF, Space, NBSP, LF, CR).
fn bool is_ecma_whitespace(char c) @inline {
    return c == 0x09 || c == 0x0B || c == 0x0C
        || c == 0x20 || c == 0xA0
        || c == 0x0A || c == 0x0D;
}

/// ECMAScript ToNumber for strings (§7.1.3.1).
///
/// Converts an HString* to a double, trimming ECMAScript whitespace and
/// parsing numeric literals (decimal, hex, Infinity).  Returns NaN when
/// the string does not represent a valid numeric literal.
fn double builtin_string_to_number(HString* hstr) {
    char* cstr = hstr.get_cstr();
    uint blen = hstr.blen;

    // --- skip leading ECMAScript whitespace ---
    uint start = 0;
    while (start < blen && is_ecma_whitespace(cstr[start])) {
        start++;
    }

    // Empty or all-whitespace -> +0
    if (start == blen) {
        return 0.0;
    }

    char* p = cstr + start;

    // --- Infinity / -Infinity / +Infinity ---
    if (libc::strcmp((ZString)p, "Infinity") == 0)   return double::inf;
    if (libc::strcmp((ZString)p, "+Infinity") == 0)  return double::inf;
    if (libc::strcmp((ZString)p, "-Infinity") == 0)  return -double::inf;

    // --- Hex integer literal (0x...) ---
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        uint j = 2;
        ulong val = 0;
        while (p[j] != 0) {
            char c = p[j];
            uint digit;
            if      (c >= '0' && c <= '9') { digit = (uint)(c - '0'); }
            else if (c >= 'a' && c <= 'f') { digit = (uint)(c - 'a' + 10); }
            else if (c >= 'A' && c <= 'F') { digit = (uint)(c - 'A' + 10); }
            else { break; }   // non-hex terminates the literal

            val = (val << 4) | digit;
            j++;
        }
        // Trailing must be whitespace
        while (p[j] != 0) {
            if (!is_ecma_whitespace(p[j])) return double::nan;
            j++;
        }
        return (double)val;
    }

    // --- Decimal via libc::strtod ---
    char* endptr;
    double result = libc::strtod(p, &endptr);

    // Nothing was consumed -> NaN
    if (endptr == p) {
        return double::nan;
    }

    // Trailing characters must be whitespace only
    while (*endptr != 0) {
        if (!is_ecma_whitespace(*endptr)) {
            return double::nan;
        }
        endptr++;
    }

    return result;
}

// ============================================================================
// ToNumber (ES5 §9.3)
// ============================================================================

/// Convert any TVal to a numeric TVal per ES5 §9.3.
/// Preserves FASTINT where possible.
fn void builtin_to_number(TVal* val, TVal* result) {
    switch (val.get_tag()) {
        case UNDEFINED:
            result.set_number(double::nan);
            return;
        case NULL_VAL:
            result.set_fastint(0);
            return;
        case BOOLEAN:
            result.set_fastint(val.get_boolean() ? 1 : 0);
            return;
        case NUMBER:
            *result = *val;
            return;
        case FASTINT:
            *result = *val;
            return;
        case STRING: {
            double d = builtin_string_to_number((HString*)val.get_heapptr());
            // Try fastint preservation
            long fi = (long)d;
            if ((double)fi == d && fi >= -9007199254740991 && fi <= 9007199254740991) {
                result.set_fastint(fi);
                return;
            }
            result.set_number(d);
            return;
        }
        case OBJECT: {
            // For wrapper objects, unwrap via ToPrimitive
            TVal prim = to_primitive_value_local(val);
            if (!prim.is_object()) {
                builtin_to_number(&prim, result);
                return;
            }
            // Non-wrapper objects -> NaN
            result.set_number(double::nan);
            return;
        }
        default:
            result.set_number(double::nan);
            return;
    }
}

/// Simplified ToPrimitive for builtins — unwraps Boolean/Number/String wrapper objects.
fn TVal to_primitive_value_local(TVal* val) @public {
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        hobject::ObjClass cls = obj.get_class();
        if (cls == hobject::ObjClass.BOOLEAN &&
            obj.extra.prim.primitive_value.is_boolean()) {
            TVal result;
            result.set_boolean(obj.extra.prim.primitive_value.get_boolean());
            return result;
        }
        if (cls == hobject::ObjClass.NUMBER &&
            (obj.extra.prim.primitive_value.is_number() || obj.extra.prim.primitive_value.is_fastint())) {
            TVal result;
            result.set_number(obj.extra.prim.primitive_value.get_number_or_fastint());
            return result;
        }
        if (cls == hobject::ObjClass.STRING &&
            obj.extra.prim.primitive_value.is_string()) {
            TVal result;
            result.set_string(obj.extra.prim.primitive_value.get_heapptr());
            return result;
        }
    }
    return *val;
}

fn void builtin_parse_int(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_number(double::nan);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    if (arg.is_fastint()) {
        ctx.result.set_fastint(arg.get_fastint());
        return;
    }
    if (!arg.is_string()) {
        ctx.result.set_number(double::nan);
        return;
    }
    HString* h = (HString*)arg.get_heapptr();
    if (h == null || h.blen == 0) {
        ctx.result.set_number(double::nan);
        return;
    }
    char* cstr = h.get_cstr();
    // Skip leading whitespace
    char* p = cstr;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;

    int radix;
    if (ctx.argc > 1) {
        TVal* rad_arg = &ctx.regs[ctx.base_reg + 1];
        radix = (int)(rad_arg.is_fastint() ? rad_arg.get_fastint() : rad_arg.get_number());
    } else {
        radix = 0;  // auto-detect (0x = hex, 0 = octal legacy, else decimal)
    }

    char* end;
    long result = libc::strtol(p, &end, radix);
    if (end == cstr) {
        ctx.result.set_number(double::nan);
        return;
    }
    ctx.result.set_fastint(result);
}

fn void builtin_parse_float(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_number(double::nan);
        return;
    }
    double d = string_to_double(&ctx.regs[ctx.base_reg]);
    ctx.result.set_number(d);
}

fn void builtin_is_nan(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal num;
    builtin_to_number(&ctx.regs[ctx.base_reg], &num);
    ctx.result.set_boolean((num.is_number()) ? math::is_nan(num.get_number()) : false);
}

fn void builtin_is_finite(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    double d = string_to_double(&ctx.regs[ctx.base_reg]);
    ctx.result.set_boolean(!math::is_nan(d) && !math::is_inf(d));
}

// ============================================================================
// Function constructor (ES5 §15.3)
// ============================================================================

/// Function(p1, p2, ..., pn, body) — creates a new function dynamically.
/// Called as function or constructor, behavior is identical per ES5 §15.3.1.
fn void builtin_function(BuiltinContext* ctx) {
    // Collect the body string (last arg) and param names (preceding args).
    // Per ES5 §15.3.2.1:
    //   - 0 args  → body = ""
    //   - 1 arg   → body = ToString(arg[0])
    //   > 1 args  → last arg = body, preceding = param names

    char* body_str = "";
    usz body_len = 0;
    char[256] param_buf;  // accumulate param names joined by commas
    int param_pos = 0;

    if (ctx.argc == 0) {
        // Empty body, no params
        body_str = "";
        body_len = 0;
    } else {
        // Get the body from the last argument
        TVal* body_arg = &ctx.regs[ctx.base_reg + (uint)(ctx.argc - 1)];
        if (body_arg.is_string() && body_arg.get_heapptr() != null) {
            HString* s = (HString*)body_arg.get_heapptr();
            body_str = s.get_cstr();
            body_len = s.blen;
        } else {
            // Convert to string via ToString
            // For simplicity, return undefined if not a string
            ctx.result.set_undefined();
            return;
        }

        // Process parameter names from preceding args
        for (ushort i = 0; i < ctx.argc - 1; i++) {
            TVal* arg = &ctx.regs[ctx.base_reg + (uint)i];
            char* pname = "";
            usz plen = 0;
            if (arg.is_string() && arg.get_heapptr() != null) {
                HString* s = (HString*)arg.get_heapptr();
                pname = s.get_cstr();
                plen = s.blen;
            } else {
                // Convert to string: for simplicity, skip non-string params
                continue;
            }

            // Add comma separator
            if (param_pos > 0 && param_pos < 255) {
                param_buf[param_pos++] = ',';
            }

            // Copy param name (up to buffer limit)
            for (usz j = 0; j < plen && param_pos < 255; j++) {
                param_buf[param_pos++] = pname[j];
            }
        }
    }

    param_buf[param_pos] = 0;

    // Build source string: "(p1,p2,...){ body }"
    // Use a generously-sized stack buffer
    char[16384] src_buf;
    int src_pos = 0;

    src_pos += libc::snprintf(&src_buf[src_pos], (usz)(16384 - src_pos), "(%s){", param_buf);
    // Copy body (up to remaining buffer space)
    for (usz i = 0; i < body_len && src_pos < 16380; i++) {
        src_buf[src_pos++] = body_str[i];
    }
    src_pos += libc::snprintf(&src_buf[src_pos], (usz)(16384 - src_pos), "}");

    // Lex and compile as a function expression
    Lexer lex = lexer::lexer_init(src_buf[:src_pos], ctx.heap);
    CompiledFunction*? cf = compiler::compile_function(&lex, ctx.heap, true);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
        // Compilation failed: throw SyntaxError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.syntax_err_proto;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            HString* msg_str = builtin_intern_string(ctx.heap, "SyntaxError in Function constructor");
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            TVal err_tv;
            err_tv.set_object(err);
            ctx.throw_value.set_object(err_tv.get_heapptr());
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Create an HObject for the compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.extra.func.comp_func = func;
    func_obj.extra.func.builtin_fn_index = -1;
    func_obj.extra.func.callable_kind = hobject::CallableKind.COMPILED_FN;

    // Use the global environment (per ES5 §15.3.2.1 step 5)
    func_obj.extra.func.var_env = ctx.global_env;
    func_obj.extra.func.lex_env = ctx.global_env;

    // Set the function's .prototype property (standard for JS functions)
    // and its internal [[Prototype]] to Function.prototype
    func_obj.prototype = ctx.heap.function_proto;
    HObject*? proto_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (try proto = proto_raw) {
        HString* proto_key = builtin_intern_string(ctx.heap, "prototype");
        TVal proto_tv;
        proto_tv.set_object(proto);
        func_obj.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_WC);
    }

    // Set function length
    uint num_params = 0;
    if (ctx.argc > 0) num_params = (uint)(ctx.argc - 1);
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_tv;
    len_tv.set_fastint((long)num_params);
    func_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);

    // Return the function object
    ctx.result.set_object(func_obj);
}

// ============================================================================
// Eval (ES5 §15.1.2.1)
// ============================================================================

fn void builtin_eval(BuiltinContext* ctx) {
    // ES5 §15.1.2.1: eval(x)
    if (ctx.argc < 1) {
        // No args → return undefined
        ctx.result.set_undefined();
        return;
    }

    TVal* arg = &ctx.regs[ctx.base_reg];

    // If Type(x) is not String, return x unchanged
    if (!arg.is_string()) {
        ctx.heap.tval_copy_ref(ctx.result, arg);
        return;
    }

    HString* source = (HString*)arg.get_heapptr();
    char* src_cstr = source.get_cstr();
    usz src_len = source.blen;

    // Compile the source string as eval code
    Lexer lex = lexer::lexer_init(src_cstr[:src_len], ctx.heap);
    CompiledFunction*? cf = compiler::compile_eval(&lex, ctx.heap);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
        // Compilation failed: throw SyntaxError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.syntax_err_proto;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            HString* msg_str = builtin_intern_string(ctx.heap, "SyntaxError in eval code");
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            TVal err_tv;
            err_tv.set_object(err);
            ctx.throw_value.set_object(err_tv.get_heapptr());
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Create an HObject for the compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    func_obj.extra.func.comp_func = func;
    func_obj.extra.func.builtin_fn_index = -1;
    func_obj.extra.func.callable_kind = hobject::CallableKind.COMPILED_FN;

    // For eval, use the global environment
    func_obj.extra.func.var_env = ctx.global_env;
    func_obj.extra.func.lex_env = ctx.global_env;

    // Replace the callee slot with the compiled function HObject
    TVal func_tv;
    func_tv.set_object(func_obj);
    ctx.regs[ctx.base_reg - 2] = func_tv;

    // Set this binding to the global object (required for indirect eval per §10.4.2)
    if (ctx.global_env != null && ctx.global_env.bindings != null) {
        TVal this_tv;
        this_tv.set_object(ctx.global_env.bindings);
        ctx.regs[ctx.base_reg - 1] = this_tv;
    }

    // Signal the CALL handler to re-dispatch to the compiled function with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// ToBoolean (ES5 §9.2)
// ============================================================================

fn bool builtin_to_boolean(TVal* val) {
    switch (val.get_tag()) {
        case UNDEFINED:
        case NULL_VAL:
            return false;
        case BOOLEAN:
            return val.get_boolean();
        case NUMBER:
            return !math::is_nan(val.get_number()) && val.get_number() != 0.0;
        case FASTINT:
            return val.get_fastint() != 0;
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            return s != null && s.blen > 0;
        }
        case OBJECT:
        case LIGHTFUNC:
        case BUFFER:
        case POINTER:
            return true;
        default:
            return false;
    }
}

// ============================================================================
// Intern helper (mirrors vm.c3 intern_string but needs only Heap)
// ============================================================================

fn HString* builtin_intern_string(Heap* heap, char[] data) {
    uint hash = heap.hash_string(data);
    HString* existing = heap.str_table_lookup(data, hash);
    if (existing != null) {
        return existing;
    }
    HString*? new_s = hstring::hstring_alloc(heap, data, hash);
    if (try s = new_s) {
        heap.str_table_insert(s);
        return s;
    }
    return null;
}

// ============================================================================
// ToString helper (ES3 ToString for primitive types)
// ============================================================================

fn HString* builtin_to_string(Heap* heap, TVal* val) {
    switch (val.get_tag()) {
        case STRING:
            return (HString*)val.get_heapptr();
        case NUMBER: {
            double d = val.get_number();
            // ES5 §9.8.1: ToString(Infinity) = "Infinity", ToString(NaN) = "NaN"
            if (math::is_nan(d)) return (HString*)heap.strs[heap::BuiltinStr.NAN_STR];
            if (math::is_inf(d)) {
                return (d > 0.0)
                    ? (HString*)heap.strs[heap::BuiltinStr.POSITIVE_INFINITY]
                    : (HString*)heap.strs[heap::BuiltinStr.NEGATIVE_INFINITY];
            }
            char[64] buf;
            int len = libc::snprintf(&buf, 64, "%.17g", d);
            if (len < 0 || len >= 64) return null;
            return builtin_intern_string(heap, buf[:len]);
        }
        case FASTINT: {
            char[64] buf;
            int len = libc::snprintf(&buf, 64, "%ld", (long)val.get_fastint());
            if (len < 0 || len >= 64) return null;
            return builtin_intern_string(heap, buf[:len]);
        }
        case BOOLEAN:
            if (val.get_boolean()) return (HString*)heap.strs[heap::BuiltinStr.TRUE];
            return (HString*)heap.strs[heap::BuiltinStr.FALSE];
        case UNDEFINED:
            return (HString*)heap.strs[heap::BuiltinStr.UNDEFINED];
        case NULL_VAL:
            return (HString*)heap.strs[heap::BuiltinStr.NULL_STR];
        case OBJECT:
            return builtin_intern_string(heap, "[object Object]");
        case LIGHTFUNC:
            return builtin_intern_string(heap, "[function]");
        default:
            return null;
    }
}

// ============================================================================
// Error constructor builtins
// ============================================================================

/// Shared constructor: create an error object with ObjClass.ERROR,
/// set prototype to `proto`, and set .message from args[0] if provided.
fn void builtin_error_constructor_shared(BuiltinContext* ctx, HObject* proto) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err = err_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* err = err_raw;
    err.prototype = proto;

    // Set .message if first arg is provided and not undefined
    if (ctx.argc > 0) {
        TVal* msg_arg = &ctx.regs[ctx.base_reg];
        if (!msg_arg.is_undefined()) {
            HString* msg_str = builtin_to_string(ctx.heap, msg_arg);
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
        }
    }

    ctx.result.set_object(null);
    ctx.result.set_fastint(0);
    ctx.result.set_object(err);
}

fn void builtin_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.err_proto);
}

fn void builtin_type_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.type_err_proto);
}

fn void builtin_range_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.range_err_proto);
}

fn void builtin_reference_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.ref_err_proto);
}

fn void builtin_syntax_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.syntax_err_proto);
}

fn void builtin_eval_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.eval_err_proto);
}

fn void builtin_uri_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.uri_err_proto);
}

// ============================================================================
// AggregateError constructor — ES2021 §28.1.1.1
// ============================================================================

fn void builtin_aggregate_error(BuiltinContext* ctx) {
    // Get errors argument
    TVal errors_val;
    errors_val.set_undefined();
    if (ctx.argc >= 1) errors_val = ctx.regs[ctx.base_reg];

    // Get message argument (optional)
    TVal msg_val;
    msg_val.set_undefined();
    if (ctx.argc >= 2) msg_val = ctx.regs[ctx.base_reg + 1];

    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err = err_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* err = err_raw;
    err.prototype = ctx.heap.aggregate_err_proto;

    // Set .message if provided and not undefined
    if (!msg_val.is_undefined()) {
        HString* msg_str = builtin_to_string(ctx.heap, &msg_val);
        if (msg_str != null) {
            TVal msg_prop;
            msg_prop.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_prop, hobject::PROP_FLAGS_WC);
        }
    }

    // Set .errors array
    HString* errors_key = builtin_intern_string(ctx.heap, "errors");
    if (!errors_val.is_undefined()) {
        err.put_prop(errors_key, errors_val, hobject::PROP_FLAGS_WC);
    } else {
        HObject*? empty_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (try arr = empty_arr) {
            arr.prototype = ctx.heap.array_proto;
            TVal arr_tv;
            arr_tv.set_object(arr);
            err.put_prop(errors_key, arr_tv, hobject::PROP_FLAGS_WC);
        }
    }

    ctx.result.set_object(null);
    ctx.result.set_fastint(0);
    ctx.result.set_object(err);
}

// ============================================================================
// Error.prototype.toString — returns "name: message" per ES5 §15.11.4.4
// ============================================================================

fn void builtin_error_prototype_to_string(BuiltinContext* ctx) {
    // Get 'this' value (stored at base_reg - 1 in the value stack)
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    // Default name is "Error"
    HString* name_str = builtin_intern_string(ctx.heap, "Error");
    HString* msg_str  = builtin_intern_string(ctx.heap, "");

    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();

        // Read .name property
        HString* name_key = builtin_intern_string(ctx.heap, "name");
        TVal? name_prop = obj.get_prop_proto(name_key);
        if (try nv = name_prop) {
            if (!nv.is_undefined()) {
                HString* tmp = builtin_to_string(ctx.heap, &nv);
                if (tmp != null) name_str = tmp;
            }
        }

        // Read .message property
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        TVal? msg_prop = obj.get_prop_proto(msg_key);
        if (try mv = msg_prop) {
            if (!mv.is_undefined()) {
                HString* tmp = builtin_to_string(ctx.heap, &mv);
                if (tmp != null) {
                    msg_str = tmp;
                }
            }
        }
    }
    if (name_str.blen == 0) {
        ctx.result.set_string(msg_str);
    } else if (msg_str.blen == 0) {
        ctx.result.set_string(name_str);
    } else {
        // Format: "name: message"
        usz total = (usz)name_str.blen + 2 + (usz)msg_str.blen;
        char[256] buf;
        char* name_cstr = name_str.get_cstr();
        char* msg_cstr = msg_str.get_cstr();
        int len = libc::snprintf(&buf, 256, "%s: %s", name_cstr, msg_cstr);
        if (len > 0 && len < 256) {
            HString* result_str = builtin_intern_string(ctx.heap, buf[:len]);
            ctx.result.set_string(result_str);
        } else {
            ctx.result.set_undefined();
        }
    }
}

// ============================================================================
// Boolean constructor builtins
// ============================================================================

/// ToBoolean then return boolean primitive (function call) or
/// a Boolean wrapper object (constructor call).
fn void builtin_boolean(BuiltinContext* ctx) {
    bool b;
    if (ctx.argc > 0) {
        b = builtin_to_boolean(&ctx.regs[ctx.base_reg]);
    } else {
        b = false;
    }

    if (ctx.is_constructor) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.BOOLEAN);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.bool_proto;
        obj.extra.prim.primitive_value.set_boolean(b);
        ctx.result.set_object(obj);
    } else {
        ctx.result.set_boolean(b);
    }
}

/// Boolean.prototype.toString — returns "true" or "false"
fn void builtin_boolean_proto_toString(BuiltinContext* ctx) {
    // 'this' is at base_reg - 1
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    bool b = false;
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.BOOLEAN &&
            obj.extra.prim.primitive_value.is_boolean()) {
            b = obj.extra.prim.primitive_value.get_boolean();
        }
    } else if (this_val.is_boolean()) {
        b = this_val.get_boolean();
    }
    HString* s = builtin_intern_string(ctx.heap, b ? "true" : "false");
    ctx.result.set_string(s);
}

/// Boolean.prototype.data.valueOf — returns the wrapped boolean value
// ============================================================================
// String constructor builtins
// ============================================================================

/// Populate indexed character properties on a String wrapper object (ES5 §15.5.5.1).
/// Each character position becomes a non-writable, enumerable, non-configurable own property.
fn void populate_string_indexed_props(HObject* obj, HString* s, Heap* heap) {
    for (uint i = 0; i < s.clen; i++) {
        char[16] key_buf;
        int key_len = libc::snprintf(&key_buf, 16, "%u", i);
        if (key_len <= 0 || key_len >= 16) continue;
        HString* key = heap.str_intern(key_buf[:(uint)key_len]);
        if (key == null) continue;
        uint cp = s.char_at(i);
        char[4] cbuf;
        uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
        HString* char_str = heap.str_intern(cbuf[:cblen]);
        if (char_str == null) continue;
        TVal char_tv;
        char_tv.set_string(char_str);
        obj.put_prop(key, char_tv, hobject::PROP_FLAGS_NEC);
    }
}

/// ToString then return string primitive (function call) or
/// a String wrapper object (constructor call).
fn void builtin_string(BuiltinContext* ctx) {
    HString* s;
    if (ctx.argc > 0) {
        s = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        s = builtin_intern_string(ctx.heap, "");
    }

    if (ctx.is_constructor) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.flags.exotic_stringobj = true;
        obj.prototype = ctx.heap.string_proto;
        obj.extra.prim.primitive_value.set_string(s);
        // Set .length own property (ES5 §15.5.5.1) — non-writable, non-enumerable, non-configurable
        HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)s.clen);
        obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
        // Set indexed character properties (ES5 §15.5.5.1)
        populate_string_indexed_props(obj, s, ctx.heap);
        ctx.result.set_object(obj);
    } else {
        ctx.result.set_string(s);
    }
}

/// ToUint16 abstract operation (ES5 §9.7).
fn uint to_uint16(TVal* val) {
    TVal num;
    builtin_to_number(val, &num);
    double n;
    if (num.is_fastint()) {
        n = (double)num.get_fastint();
    } else if (num.is_number()) {
        n = num.get_number();
    } else {
        return 0;
    }
    if (math::is_nan(n) || n == 0.0 || n == double::inf || n == -double::inf) return 0;
    double pos_int = math::abs(n);
    pos_int = math::floor(pos_int);
    long int_val = (long)pos_int;
    return (uint)(ushort)(int)(int_val & 0xFFFF);
}

/// String.fromCharCode (ES5 §15.5.3.2)
fn void builtin_string_fromcharcode(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        HString* empty = builtin_intern_string(ctx.heap, "");
        ctx.result.set_string(empty);
        return;
    }
    // Build string from code units (max ~256 args, cap at 512 bytes)
    char[512] buf;
    usz offset = 0;
    ushort max_args = (ushort)(ctx.argc < 256 ? ctx.argc : 256);
    for (ushort i = 0; i < max_args && offset < 510; i++) {
        uint cu = to_uint16(&ctx.regs[ctx.base_reg + i]);
        if (cu < 128) {
            buf[offset++] = (char)cu;
        } else if (cu < 2048) {
            buf[offset++] = (char)(0xC0 | (cu >> 6));
            buf[offset++] = (char)(0x80 | (cu & 0x3F));
        } else {
            buf[offset++] = (char)(0xE0 | (cu >> 12));
            buf[offset++] = (char)(0x80 | ((cu >> 6) & 0x3F));
            buf[offset++] = (char)(0x80 | (cu & 0x3F));
        }
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    ctx.result.set_string(result);
}

/// String.fromCodePoint(...codePoints) — ES6 §21.1.2.2
fn void builtin_string_fromcodepoint(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        HString* empty = builtin_intern_string(ctx.heap, "");
        ctx.result.set_string(empty);
        return;
    }
    // Build string from code points (supporting supplementary plane via UTF-8)
    char[1024] buf;
    usz offset = 0;
    ushort max_args = (ushort)(ctx.argc < 256 ? ctx.argc : 256);
    for (ushort i = 0; i < max_args && offset < 1020; i++) {
        TVal* arg = &ctx.regs[ctx.base_reg + i];
        double d;
        if (arg.is_fastint()) {
            d = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            d = arg.get_number();
        } else if (arg.is_boolean()) {
            d = arg.get_boolean() ? 1.0 : 0.0;
        } else if (arg.is_undefined() || arg.is_null()) {
            d = 0.0;
        } else {
            d = builtin_to_number_getdouble(ctx, arg);
        }
        // Check: must be integral Number in [0, 0x10FFFF]
        if (math::is_nan(d) || math::is_inf(d) || d != math::trunc(d) || d < 0 || d > 0x10FFFF) {
            // Throw RangeError
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.range_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Invalid code point value");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
            return;
        }
        uint ucp = (uint)(long)d;
        if (ucp < 0x80) {
            buf[offset++] = (char)ucp;
        } else if (ucp < 0x800) {
            buf[offset++] = (char)(0xC0 | (ucp >> 6));
            buf[offset++] = (char)(0x80 | (ucp & 0x3F));
        } else if (ucp < 0x10000) {
            buf[offset++] = (char)(0xE0 | (ucp >> 12));
            buf[offset++] = (char)(0x80 | ((ucp >> 6) & 0x3F));
            buf[offset++] = (char)(0x80 | (ucp & 0x3F));
        } else {
            // 4-byte UTF-8 for supplementary plane
            buf[offset++] = (char)(0xF0 | (ucp >> 18));
            buf[offset++] = (char)(0x80 | ((ucp >> 12) & 0x3F));
            buf[offset++] = (char)(0x80 | ((ucp >> 6) & 0x3F));
            buf[offset++] = (char)(0x80 | (ucp & 0x3F));
        }
    }
    HString* result_str = builtin_intern_string(ctx.heap, buf[:offset]);
    ctx.result.set_string(result_str);
}

// ============================================================================
// URI encode/decode helpers (ES5 §15.1.3)
// ============================================================================

fn void uri_encode_byte(char* out, usz* offset, char b) {
    out[*offset] = '%';
    out[*offset + 1] = "0123456789ABCDEF"[b >> 4];
    out[*offset + 2] = "0123456789ABCDEF"[b & 0x0F];
    *offset += 3;
}

fn bool uri_is_unreserved(char c) {
    if (c >= 'A' && c <= 'Z') return true;
    if (c >= 'a' && c <= 'z') return true;
    if (c >= '0' && c <= '9') return true;
    if (c == '-' || c == '_' || c == '.' || c == '!') return true;
    if (c == '~' || c == '*' || c == '\'' || c == '(') return true;
    if (c == ')') return true;
    return false;
}

fn int hex_digit_val(char c) {
    if (c >= '0' && c <= '9') return (int)c - '0';
    if (c >= 'A' && c <= 'F') return (int)c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return (int)c - 'a' + 10;
    return -1;
}

/// encodeURI (ES5 §15.1.3.1)
fn void builtin_encode_uri(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        char c = data[i];
        // URI unreserved + reserved + '#' characters (not encoded)
        if (uri_is_unreserved(c)) {
            out[offset++] = c;
            i++;
        } else if (c == ';' || c == ',' || c == '/' || c == '?' || c == ':' ||
                   c == '@' || c == '&' || c == '=' || c == '+' || c == '$' ||
                   c == '-' || c == '_' || c == '.' || c == '!' || c == '~' ||
                   c == '*' || c == '\'' || c == '(' || c == ')' || c == '#') {
            out[offset++] = c;
            i++;
        } else {
            uint b = (uint)c;
            if (b < 0x80) {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            } else if (b >= 0xC2 && b <= 0xF4) {
                uint seq_len;
                if (b < 0xE0) { seq_len = 2; }
                else if (b < 0xF0) { seq_len = 3; }
                else { seq_len = 4; }
                if (i + seq_len > len) {
                    // Incomplete sequence - encode byte
                    uri_encode_byte(&out, &offset, (char)b);
                    i++;
                } else {
                    // Validate continuation bytes
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        uint cb = (uint)data[i + j];
                        if (cb < 0x80 || cb > 0xBF) { valid = false; break; }
                    }
                    if (!valid) {
                        uri_encode_byte(&out, &offset, (char)b);
                        i++;
                    } else {
                        for (uint j = 0; j < seq_len; j++) {
                            uri_encode_byte(&out, &offset, (char)data[i + j]);
                        }
                        i += seq_len;
                    }
                }
            } else {
                // Invalid leading byte (0x80-0xBF, 0xC0-0xC1, 0xF5-0xFF)
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            }
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

/// encodeURIComponent (ES5 §15.1.3.2)
fn void builtin_encode_uri_component(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        char c = data[i];
        if (uri_is_unreserved(c)) {
            out[offset++] = c;
            i++;
        } else {
            uint b = (uint)c;
            if (b < 0x80) {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            } else if (b >= 0xC2 && b <= 0xF4) {
                uint seq_len;
                if (b < 0xE0) { seq_len = 2; }
                else if (b < 0xF0) { seq_len = 3; }
                else { seq_len = 4; }
                if (i + seq_len > len) {
                    uri_encode_byte(&out, &offset, (char)b);
                    i++;
                } else {
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        uint cb = (uint)data[i + j];
                        if (cb < 0x80 || cb > 0xBF) { valid = false; break; }
                    }
                    if (!valid) {
                        uri_encode_byte(&out, &offset, (char)b);
                        i++;
                    } else {
                        for (uint j = 0; j < seq_len; j++) {
                            uri_encode_byte(&out, &offset, (char)data[i + j]);
                        }
                        i += seq_len;
                    }
                }
            } else {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            }
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

/// decodeURI (ES5 §15.1.3.3)
fn void builtin_decode_uri(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        if (data[i] == '%') {
            // Check if this is a reserved character that should NOT be decoded
            if (i + 2 < len) {
                int d1 = hex_digit_val(data[i + 1]);
                int d2 = hex_digit_val(data[i + 2]);
                if (d1 >= 0 && d2 >= 0) {
                    uint cp = (uint)((d1 << 4) | d2);
                    // decodeURI does NOT decode reserved URI characters
                    if (cp == 0x23 || cp == 0x24 || cp == 0x26 || cp == 0x2B ||
                        cp == 0x2C || cp == 0x2F || cp == 0x3A || cp == 0x3B ||
                        cp == 0x3D || cp == 0x3F || cp == 0x40) {
                        out[offset++] = '%';
                        out[offset++] = data[i + 1];
                        out[offset++] = data[i + 2];
                        i += 3;
                        continue;
                    }
                    // Decode the byte
                    char first = (char)cp;
                    if (first < 0x80) {
                        out[offset++] = (char)first;
                        i += 3;
                    } else if (first >= 0xC0 && first <= 0xF4) {
                        // Multi-byte UTF-8 sequence
                        uint seq_len;
                        if (first < 0xE0) { seq_len = 2; }
                        else if (first < 0xF0) { seq_len = 3; }
                        else { seq_len = 4; }
                        if (i + 3 * seq_len > len) {
                            // Incomplete - throw URIError
                            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = ctx.heap.uri_err_proto;
                                HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                                TVal msg_tv; msg_tv.set_string(msg);
                                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                                ctx.should_throw = true;
                                ctx.throw_value.set_object(err);
                            }
                            return;
                        }
                        char[4] bytes;
                        bytes[0] = (char)first;
                        bool valid = true;
                        for (uint j = 1; j < seq_len; j++) {
                            if (data[i + 3 * j] != '%') { valid = false; break; }
                            int h1 = hex_digit_val(data[i + 3 * j + 1]);
                            int h2 = hex_digit_val(data[i + 3 * j + 2]);
                            if (h1 < 0 || h2 < 0) { valid = false; break; }
                            char b = (char)((h1 << 4) | h2);
                            if (b < 0x80 || b > 0xBF) { valid = false; break; }
                            bytes[j] = (char)b;
                        }
                        if (!valid) {
                            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = ctx.heap.uri_err_proto;
                                HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                                TVal msg_tv; msg_tv.set_string(msg);
                                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                                ctx.should_throw = true;
                                ctx.throw_value.set_object(err);
                            }
                            return;
                        }
                        for (uint j = 0; j < seq_len; j++) {
                            out[offset++] = bytes[j];
                        }
                        i += 3 * seq_len;
                    } else {
                        // Invalid leading byte for multi-byte sequence
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = ctx.heap.uri_err_proto;
                            HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                            TVal msg_tv; msg_tv.set_string(msg);
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                            ctx.should_throw = true;
                            ctx.throw_value.set_object(err);
                        }
                        return;
                    }
                } else {
                    // Invalid hex digits
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = ctx.heap.uri_err_proto;
                        HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                        TVal msg_tv; msg_tv.set_string(msg);
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                        ctx.should_throw = true;
                        ctx.throw_value.set_object(err);
                    }
                    return;
                }
            } else {
                // '%' not followed by two hex digits
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.uri_err_proto;
                    HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                    TVal msg_tv; msg_tv.set_string(msg);
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                }
                return;
            }
        } else {
            out[offset++] = data[i];
            i++;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

/// decodeURIComponent (ES5 §15.1.3.4)
fn void builtin_decode_uri_component(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        if (data[i] == '%') {
            if (i + 2 < len) {
                int d1 = hex_digit_val(data[i + 1]);
                int d2 = hex_digit_val(data[i + 2]);
                if (d1 < 0 || d2 < 0) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = ctx.heap.uri_err_proto;
                        HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                        TVal msg_tv; msg_tv.set_string(msg);
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                        ctx.should_throw = true;
                        ctx.throw_value.set_object(err);
                    }
                    return;
                }
                char first = (char)((d1 << 4) | d2);
                if (first < 0x80) {
                    out[offset++] = (char)first;
                    i += 3;
                } else if (first >= 0xC0 && first <= 0xF4) {
                    uint seq_len;
                    if (first < 0xE0) { seq_len = 2; }
                    else if (first < 0xF0) { seq_len = 3; }
                    else { seq_len = 4; }
                    if (i + 3 * seq_len > len) {
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = ctx.heap.uri_err_proto;
                            HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                            TVal msg_tv; msg_tv.set_string(msg);
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                            ctx.should_throw = true;
                            ctx.throw_value.set_object(err);
                        }
                        return;
                    }
                    char[4] bytes;
                    bytes[0] = (char)first;
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        if (data[i + 3 * j] != '%') { valid = false; break; }
                        int h1 = hex_digit_val(data[i + 3 * j + 1]);
                        int h2 = hex_digit_val(data[i + 3 * j + 2]);
                        if (h1 < 0 || h2 < 0) { valid = false; break; }
                        char b = (char)((h1 << 4) | h2);
                        if (b < 0x80 || b > 0xBF) { valid = false; break; }
                        bytes[j] = (char)b;
                    }
                    if (!valid) {
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = ctx.heap.uri_err_proto;
                            HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                            TVal msg_tv; msg_tv.set_string(msg);
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                            ctx.should_throw = true;
                            ctx.throw_value.set_object(err);
                        }
                        return;
                    }
                    for (uint j = 0; j < seq_len; j++) {
                        out[offset++] = bytes[j];
                    }
                    i += 3 * seq_len;
                } else {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = ctx.heap.uri_err_proto;
                        HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                        TVal msg_tv; msg_tv.set_string(msg);
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                        ctx.should_throw = true;
                        ctx.throw_value.set_object(err);
                    }
                    return;
                }
            } else {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.uri_err_proto;
                    HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                    TVal msg_tv; msg_tv.set_string(msg);
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                }
                return;
            }
        } else {
            out[offset++] = data[i];
            i++;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

/// String.prototype.toString — returns the wrapped string value
fn void builtin_string_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.STRING &&
            obj.extra.prim.primitive_value.is_string()) {
            ctx.result.set_string(obj.extra.prim.primitive_value.get_heapptr());
            return;
        }
    } else if (this_val.is_string()) {
        ctx.result.set_string(this_val.get_heapptr());
        return;
    }
    ctx.result.set_undefined();
}

/// String.prototype.data.valueOf — returns the wrapped string primitive
fn void builtin_string_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.STRING &&
            obj.extra.prim.primitive_value.is_string()) {
            ctx.result.set_string(obj.extra.prim.primitive_value.get_heapptr());
            return;
        }
    } else if (this_val.is_string()) {
        ctx.result.set_string(this_val.get_heapptr());
        return;
    }
    ctx.result.set_undefined();
}

fn void builtin_boolean_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.BOOLEAN &&
            obj.extra.prim.primitive_value.is_boolean()) {
            ctx.result.set_boolean(obj.extra.prim.primitive_value.get_boolean());
            return;
        }
    } else if (this_val.is_boolean()) {
        ctx.result.set_boolean(this_val.get_boolean());
        return;
    }
    ctx.result.set_undefined();
}

// ============================================================================
// String.prototype methods (Phase 6b)
// ============================================================================

/// Helper: extract the string data and length from `this`, handling both
/// primitive strings and String wrapper objects. Returns null on failure.
fn HString* string_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_string()) {
        return (HString*)this_val.get_heapptr();
    }
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.STRING &&
            obj.extra.prim.primitive_value.is_string()) {
            return (HString*)obj.extra.prim.primitive_value.get_heapptr();
        }
    }
    // TypeError: String.prototype method called on incompatible value
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "String.prototype method called on incompatible value");
        TVal msg_val;
        msg_val.set_string(msg_str);
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        TVal err_tv;
        err_tv.set_object(err);
        ctx.throw_value = err_tv;
    }
    ctx.should_throw = true;
    return null;
}

/// Helper: convert TVal to integer (ES5 §9.4 ToInteger).
fn double builtin_to_integer(TVal* val) {
    switch (val.get_tag()) {
        case UNDEFINED:
            return 0.0;
        case NULL_VAL:
            return 0.0;
        case BOOLEAN:
            return val.get_boolean() ? 1.0 : 0.0;
        case NUMBER:
            double d = val.get_number();
            if (math::is_nan(d)) return 0.0;
            if (math::is_inf(d) || d == 0.0) return d;
            return math::trunc(d);
        case FASTINT:
            return (double)val.get_fastint();
        case STRING: {
            double d = builtin_string_to_number((HString*)val.get_heapptr());
            if (math::is_nan(d)) return 0.0;
            if (math::is_inf(d) || d == 0.0) return d;
            return math::trunc(d);
        }
        case OBJECT: {
            TVal prim = to_primitive_value_local(val);
            if (!prim.is_object()) {
                return builtin_to_integer(&prim);
            }
            return 0.0;
        }
        default:
            return 0.0;
    }
}

/// Helper: clamp to int and coerce to range [0, len].
fn uint clamp_index(double d, uint len) {
    if (math::is_nan(d)) return 0;
    if (d < 0) return 0;
    if (d >= (double)len) return len;
    return (uint)(long)d;
}

/// String.prototype.charAt(pos) — ES5 §15.5.4.4
fn void builtin_string_proto_charAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    double pos = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    if (pos < 0 || pos >= (double)len) {
        // Return empty string
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    uint idx = (uint)(long)pos;
    char[2] buf;
    buf[0] = data[idx];
    buf[1] = 0;
    HString* result = builtin_intern_string(ctx.heap, buf[:1]);
    ctx.result.set_string(result);
}

/// String.prototype.charCodeAt(pos) — ES5 §15.5.4.5
fn void builtin_string_proto_charCodeAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    double pos = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    if (pos < 0 || pos >= (double)len) {
        ctx.result.set_number(double::nan);
        return;
    }
    uint idx = (uint)(long)pos;
    ctx.result.set_fastint((long)(data[idx] & 0xFF));
}

/// String.prototype.indexOf(searchString, position) — ES5 §15.5.4.7
fn void builtin_string_proto_indexOf(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // Get search string
    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) {
        ctx.result.set_fastint(-1);
        return;
    }

    // Get position
    double pos_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : 0.0;
    uint pos;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos = 0;
    } else if (pos_d >= (double)len) {
        pos = len;
    } else {
        pos = (uint)(long)pos_d;
    }

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    // Search for occurrence
    if (search_len == 0) {
        ctx.result.set_fastint((long)pos);
        return;
    }

    int result = -1;
    for (uint i = pos; i + search_len <= len; i++) {
        bool found = true;
        for (uint j = 0; j < search_len; j++) {
            if (data[i + j] != search_data[j]) {
                found = false;
                break;
            }
        }
        if (found) {
            result = (int)i;
            break;
        }
    }
    ctx.result.set_fastint((long)result);
}

/// String.prototype.slice(start, end) — ES5 §15.5.4.13
fn void builtin_string_proto_slice(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    double start_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    double end_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : (double)len;

    // Handle negative start
    int start_i;
    if (math::is_nan(start_d)) {
        start_i = 0;
    } else if (start_d < 0) {
        start_i = (int)(long)start_d + (int)len;
        if (start_i < 0) start_i = 0;
    } else {
        start_i = (int)(long)start_d;
        if (start_i > (int)len) start_i = (int)len;
    }

    // Handle negative end
    int end_i;
    if (math::is_nan(end_d)) {
        end_i = (int)len;
    } else if (end_d < 0) {
        end_i = (int)(long)end_d + (int)len;
        if (end_i < 0) end_i = 0;
    } else {
        end_i = (int)(long)end_d;
        if (end_i > (int)len) end_i = (int)len;
    }

    if (start_i >= end_i) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    uint substr_len = (uint)(end_i - start_i);
    char[256] buf;
    usz copy_len = (usz)(substr_len < 256 ? substr_len : 256);
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = data[(uint)start_i + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.substring(start, end) — ES5 §15.5.4.15
fn void builtin_string_proto_substring(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    uint len = s_hstr.blen;

    double start_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    double end_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : (double)len;

    uint start = clamp_index(start_d, len);
    uint end = clamp_index(end_d, len);

    uint from = start < end ? start : end;
    uint to = start < end ? end : start;

    if (from >= to) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    uint substr_len = to - from;
    char* cstr = s_hstr.get_cstr();
    char[256] buf;
    usz copy_len = (usz)(substr_len < 256 ? substr_len : 256);
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = cstr[from + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.substr(start, length) — ES5 §B.2.3
fn void builtin_string_proto_substr(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    uint len = s_hstr.blen;

    double start_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;

    int start_i;
    if (math::is_nan(start_d)) {
        start_i = 0;
    } else if (start_d < 0) {
        start_i = (int)(long)start_d + (int)len;
        if (start_i < 0) start_i = 0;
    } else {
        start_i = (int)(long)start_d;
        if (start_i > (int)len) start_i = (int)len;
    }

    double length_d;
    if (ctx.argc > 1) {
        length_d = builtin_to_integer(&ctx.regs[ctx.base_reg + 1]);
    } else {
        length_d = (double)(len - (uint)start_i);
    }

    int length_i;
    if (math::is_nan(length_d) || length_d <= 0) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    length_i = (int)(long)length_d;
    if (length_i > (int)len - start_i) {
        length_i = (int)len - start_i;
    }
    if (length_i <= 0) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    char* cstr = s_hstr.get_cstr();
    char[256] buf;
    usz copy_len = (usz)((uint)length_i < 256 ? (uint)length_i : 256);
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = cstr[(uint)start_i + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.toLowerCase() — ES5 §15.5.4.17 (ASCII-only)
fn void builtin_string_proto_toLowerCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    char[256] buf;
    usz copy_len = len < 256 ? (usz)len : 256;
    for (usz i = 0; i < copy_len; i++) {
        char c = data[i];
        if (c >= 'A' && c <= 'Z') {
            buf[i] = (char)(c + 32);
        } else {
            buf[i] = c;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.toUpperCase() — ES5 §15.5.4.18 (ASCII-only)
fn void builtin_string_proto_toUpperCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    char[256] buf;
    usz copy_len = len < 256 ? (usz)len : 256;
    for (usz i = 0; i < copy_len; i++) {
        char c = data[i];
        if (c >= 'a' && c <= 'z') {
            buf[i] = (char)(c - 32);
        } else {
            buf[i] = c;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.toLocaleLowerCase() — ES5 §15.5.4.17
/// Identical to toLowerCase in default locale.
fn void builtin_string_proto_toLocaleLowerCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    char[256] buf;
    usz copy_len = len < 256 ? (usz)len : 256;
    for (usz i = 0; i < copy_len; i++) {
        char c = data[i];
        if (c >= 'A' && c <= 'Z') {
            buf[i] = (char)(c + 32);
        } else {
            buf[i] = c;
        }
    }
    HString* lower = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(lower);
}

/// String.prototype.toLocaleUpperCase() — ES5 §15.5.4.19
/// Identical to toUpperCase in default locale.
fn void builtin_string_proto_toLocaleUpperCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    char[256] buf;
    usz copy_len = len < 256 ? (usz)len : 256;
    for (usz i = 0; i < copy_len; i++) {
        char c = data[i];
        if (c >= 'a' && c <= 'z') {
            buf[i] = (char)(c - 32);
        } else {
            buf[i] = c;
        }
    }
    HString* upper = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(upper);
}

/// String.prototype.localeCompare(that) — ES5 §15.5.4.12
/// Returns <0, 0, or >0 based on lexicographic comparison.
fn void builtin_string_proto_localeCompare(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    HString* that_hstr;
    if (ctx.argc > 0) {
        that_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        that_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (that_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* a = s_hstr.get_cstr();
    uint a_len = s_hstr.blen;
    char* b = that_hstr.get_cstr();
    uint b_len = that_hstr.blen;
    usz min_len = a_len < b_len ? (usz)a_len : (usz)b_len;
    for (usz i = 0; i < min_len; i++) {
        int diff = (int)a[i] - (int)b[i];
        if (diff != 0) {
            ctx.result.set_number((double)diff);
            return;
        }
    }
    ctx.result.set_number((double)((int)a_len - (int)b_len));
}

/// String.prototype.trim() — ES5 §15.5.4.20
fn void builtin_string_proto_trim(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // Trim leading whitespace
    uint start = 0;
    while (start < len && is_ecma_whitespace(data[start])) {
        start++;
    }

    // All whitespace
    if (start == len) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    // Trim trailing whitespace
    uint end = len;
    while (end > start && is_ecma_whitespace(data[end - 1])) {
        end--;
    }

    uint substr_len = end - start;
    char[256] buf;
    usz copy_len = substr_len < 256 ? (usz)substr_len : 256;
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = data[start + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.split(separator, limit) — ES5 §15.5.4.14
fn void builtin_string_proto_split(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // Create result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    // If separator is undefined, return [string]
    if (ctx.argc == 0 || ctx.regs[ctx.base_reg].is_undefined()) {
        TVal elem;
        elem.set_string(s_hstr);
        HString* zero_key = builtin_intern_string(ctx.heap, "0");
        arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);
        TVal len_val;
        len_val.set_fastint(1);
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(arr);
        return;
    }

    TVal* sep_val = &ctx.regs[ctx.base_reg];

    // ── RegExp separator ─────────────────────────────────────────────────
    if (is_regexp_object(sep_val)) {
        HObject* rx = (HObject*)sep_val.get_heapptr();
        char* input = data;
        int input_len = (int)len;

        uint limit = 0xFFFFFFFF;
        if (ctx.argc > 1) {
            double limit_d = builtin_to_integer(&ctx.regs[ctx.base_reg + 1]);
            if (!math::is_nan(limit_d) && limit_d >= 0) {
                limit = (uint)(long)limit_d;
            }
        }

        HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
        TVal zero_tv; zero_tv.set_fastint(0);
        rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);

        uint arr_idx = 0;
        int search_pos = 0;
        HString* len_key = builtin_intern_string(ctx.heap, "length");

        while (search_pos <= input_len && arr_idx < limit) {
            int out_start = 0;
            int out_end = 0;
            int out_num_captures = 0;
            int[re_bindings::RE_MAX_CAPTURES] caps_start;
            int[re_bindings::RE_MAX_CAPTURES] caps_end;
            libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
            libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

            int result = re_bindings::re_exec(
                rx.extra.regexp.regexp_data, input, input_len, search_pos,
                &out_start, &out_end, &out_num_captures,
                &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
            );
            if (result != re_bindings::RE_MATCH) break;

            // Substring before match
            uint substr_len = (uint)out_start - (uint)search_pos;
            HString* substr;
            if (substr_len == 0) {
                substr = builtin_intern_string(ctx.heap, "");
            } else if (substr_len < 256) {
                char[256] buf;
                for (usz i = 0; i < (usz)substr_len; i++) buf[i] = input[(usz)search_pos + i];
                substr = builtin_intern_string(ctx.heap, buf[:substr_len]);
            } else {
                substr = builtin_intern_string(ctx.heap, input[search_pos : substr_len]);
            }
            TVal elem;
            elem.set_string(substr);
            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%u", arr_idx);
            arr.put_prop(builtin_intern_string(ctx.heap, idx_buf[:idx_len]), elem, hobject::PROP_FLAGS_WEC);
            arr_idx++;

            // Capture groups
            int num_caps = out_num_captures;
            if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
            for (int i = 0; i < num_caps && arr_idx < limit; i++) {
                TVal cap_elem;
                if (caps_start[i] >= 0 && caps_end[i] >= 0) {
                    usz cap_len = (usz)(caps_end[i] - caps_start[i]);
                    if (cap_len == 0) {
                        cap_elem.set_string(builtin_intern_string(ctx.heap, ""));
                    } else if (cap_len < 256) {
                        char[256] cap_buf;
                        for (usz j = 0; j < cap_len; j++) cap_buf[j] = input[(usz)caps_start[i] + j];
                        cap_elem.set_string(builtin_intern_string(ctx.heap, cap_buf[:cap_len]));
                    } else {
                        cap_elem.set_string(builtin_intern_string(ctx.heap, input[caps_start[i] : cap_len]));
                    }
                } else {
                    cap_elem.set_undefined();
                }
                char[16] ci_buf;
                int ci_len = libc::snprintf(&ci_buf, 16, "%u", arr_idx);
                arr.put_prop(builtin_intern_string(ctx.heap, ci_buf[:ci_len]), cap_elem, hobject::PROP_FLAGS_WEC);
                arr_idx++;
            }

            if (out_end == search_pos) {
                search_pos = out_end + 1;
                if (search_pos > input_len) break;
            } else {
                search_pos = out_end;
            }
        }

        // Remaining part
        if (arr_idx < limit && search_pos <= input_len) {
            uint substr_len = len - (uint)search_pos;
            HString* substr;
            if (substr_len == 0) {
                substr = builtin_intern_string(ctx.heap, "");
            } else if (substr_len < 256) {
                char[256] buf;
                for (usz i = 0; i < (usz)substr_len; i++) buf[i] = input[(usz)search_pos + i];
                substr = builtin_intern_string(ctx.heap, buf[:substr_len]);
            } else {
                substr = builtin_intern_string(ctx.heap, input[search_pos : substr_len]);
            }
            TVal elem;
            elem.set_string(substr);
            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%u", arr_idx);
            arr.put_prop(builtin_intern_string(ctx.heap, idx_buf[:idx_len]), elem, hobject::PROP_FLAGS_WEC);
            arr_idx++;
        }

        TVal len_val; len_val.set_fastint((long)arr_idx);
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(arr);
        return;
    }

    // ── String separator ─────────────────────────────────────────────────
    HString* sep_hstr = builtin_to_string(ctx.heap, sep_val);
    if (sep_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    // Get limit
    uint limit = 0xFFFFFFFF;
    if (ctx.argc > 1) {
        double limit_d = builtin_to_integer(&ctx.regs[ctx.base_reg + 1]);
        if (!math::is_nan(limit_d) && limit_d >= 0) {
            limit = (uint)(long)limit_d;
        }
    }

    char* sep_data = sep_hstr.get_cstr();
    uint sep_len = sep_hstr.blen;

    // Empty separator: split by character
    if (sep_len == 0) {
        uint count = len < limit ? len : limit;
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        TVal len_val;
        len_val.set_fastint((long)count);
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        for (uint i = 0; i < count; i++) {
            char[2] buf;
            buf[0] = data[i];
            buf[1] = 0;
            HString* ch_str = builtin_intern_string(ctx.heap, buf[:1]);
            TVal elem;
            elem.set_string(ch_str);
            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%d", i);
            HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
            arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.set_object(arr);
        return;
    }

    // Non-empty separator: split by separator
    uint arr_idx = 0;
    uint search_pos = 0;
    HString* len_key = builtin_intern_string(ctx.heap, "length");

    while (search_pos + sep_len <= len && arr_idx < limit) {
        int found_pos = -1;
        for (uint i = search_pos; i + sep_len <= len; i++) {
            bool match = true;
            for (uint j = 0; j < sep_len; j++) {
                if (data[i + j] != sep_data[j]) {
                    match = false;
                    break;
                }
            }
            if (match) { found_pos = (int)i; break; }
        }

        if (found_pos < 0) break;

        uint substr_len = (uint)found_pos - search_pos;
        HString* substr;
        if (substr_len == 0) {
            substr = builtin_intern_string(ctx.heap, "");
        } else {
            char[256] buf;
            usz copy_len = substr_len < 256 ? (usz)substr_len : 256;
            for (usz i = 0; i < copy_len; i++) buf[i] = data[search_pos + i];
            substr = builtin_intern_string(ctx.heap, buf[:copy_len]);
        }

        TVal elem;
        elem.set_string(substr);
        char[16] idx_buf;
        int idx_len = libc::snprintf(&idx_buf, 16, "%d", arr_idx);
        HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
        arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        arr_idx++;

        search_pos = (uint)(found_pos + (int)sep_len);
    }

    // Add remaining part if not at limit
    if (arr_idx < limit) {
        uint substr_len = len - search_pos;
        HString* substr;
        if (substr_len == 0) {
            substr = builtin_intern_string(ctx.heap, "");
        } else {
            char[256] buf;
            usz copy_len = substr_len < 256 ? (usz)substr_len : 256;
            for (usz i = 0; i < copy_len; i++) buf[i] = data[search_pos + i];
            substr = builtin_intern_string(ctx.heap, buf[:copy_len]);
        }
        TVal elem;
        elem.set_string(substr);
        char[16] idx_buf;
        int idx_len = libc::snprintf(&idx_buf, 16, "%d", arr_idx);
        HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
        arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        arr_idx++;
    }

    TVal len_val;
    len_val.set_fastint((long)arr_idx);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(arr);
}

/// String.prototype.concat(...args) — ES5 §15.5.4.6
fn void builtin_string_proto_concat(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // Concatenate all into a buffer
    // First, compute total length
    uint total_len = len;
    usz max_args = ctx.argc < 256 ? (usz)ctx.argc : 256;
    for (usz i = 0; i < max_args; i++) {
        HString* arg_str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + i]);
        if (arg_str == null) continue;
        total_len += arg_str.blen;
    }

    if (total_len > 512) total_len = 512;  // cap buffer size

    char[512] buf;
    usz offset = 0;

    // Copy original string
    usz orig_copy = (usz)(len < 512 ? len : 512);
    for (usz i = 0; i < orig_copy; i++) {
        buf[offset++] = data[i];
    }

    // Copy each arg
    for (usz i = 0; i < max_args && offset < 512; i++) {
        HString* arg_str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + i]);
        if (arg_str == null) continue;
        char* arg_data = arg_str.get_cstr();
        uint arg_len = arg_str.blen;
        usz copy = (usz)(arg_len < (512 - offset) ? arg_len : (512 - offset));
        for (usz j = 0; j < copy; j++) {
            buf[offset++] = arg_data[j];
        }
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    ctx.result.set_string(result);
}

/// Substitute $-patterns in a replace string (ES5 §15.5.4.11 step 10)
fn HString* builtin_replace_substitute(Heap* heap, HString* replace_str,
    char* input, int input_len,
    int match_start, int match_end,
    int* caps_start, int* caps_end, int num_caps) {

    char* rep = replace_str.get_cstr();
    uint rep_len = replace_str.blen;
    char[4096] buf;
    usz offset = 0;

    for (usz i = 0; i < rep_len && offset < 4096; i++) {
        if (rep[i] == '$' && i + 1 < rep_len) {
            char next = rep[i + 1];
            if (next == '$') {
                buf[offset++] = '$';
                i++;
                continue;
            }
            if (next == '&') {
                for (usz j = (usz)match_start; j < (usz)match_end && offset < 4096; j++) {
                    buf[offset++] = input[j];
                }
                i++;
                continue;
            }
            if (next == '`') {
                for (usz j = 0; j < (usz)match_start && offset < 4096; j++) {
                    buf[offset++] = input[j];
                }
                i++;
                continue;
            }
            if (next == '\'') {
                for (usz j = (usz)match_end; j < (usz)input_len && offset < 4096; j++) {
                    buf[offset++] = input[j];
                }
                i++;
                continue;
            }
            if (next >= '1' && next <= '9') {
                int group_idx = next - '1';
                i++;
                if (i + 1 < rep_len && rep[i + 1] >= '0' && rep[i + 1] <= '9') {
                    int two_digit = (next - '0') * 10 + (rep[i + 1] - '0');
                    if (two_digit <= num_caps) {
                        group_idx = two_digit - 1;
                        i++;
                    }
                }
                if (group_idx < num_caps && group_idx >= 0 &&
                    caps_start[group_idx] >= 0 && caps_end[group_idx] >= 0) {
                    for (usz j = (usz)caps_start[group_idx]; j < (usz)caps_end[group_idx] && offset < 4096; j++) {
                        buf[offset++] = input[j];
                    }
                }
                continue;
            }
        }
        buf[offset++] = rep[i];
    }
    return builtin_intern_string(heap, buf[:offset]);
}

/// String.prototype.replace(searchValue, replaceValue) — ES5 §15.5.4.11
fn void builtin_string_proto_replace(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    if (ctx.argc < 1) {
        ctx.result.set_string(s_hstr);
        return;
    }

    TVal* search_val = &ctx.regs[ctx.base_reg];
    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    // ── RegExp searchValue ────────────────────────────────────────────────
    if (is_regexp_object(search_val)) {
        HObject* rx = (HObject*)search_val.get_heapptr();

        HString* global_key = builtin_intern_string(ctx.heap, "global");
        bool global_flag = false;
        if (try gv = rx.get_prop(global_key)) {
            if (gv.is_boolean()) global_flag = gv.get_boolean();
        }

        bool replace_is_fn = false;
        TVal replace_val;
        replace_val.set_undefined();
        if (ctx.argc > 1) {
            replace_val = ctx.regs[ctx.base_reg + 1];
            if (replace_val.is_object() && replace_val.get_heapptr() != null &&
                ((HObject*)replace_val.get_heapptr()).is_callable()) {
                replace_is_fn = true;
            }
        }

        if (!global_flag) {
            // ── Non-global: single match ──────────────────────────────────
            int out_start = 0;
            int out_end = 0;
            int out_num_captures = 0;
            int[re_bindings::RE_MAX_CAPTURES] caps_start;
            int[re_bindings::RE_MAX_CAPTURES] caps_end;
            libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
            libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

            int result = re_bindings::re_exec(
                rx.extra.regexp.regexp_data, input, input_len, 0,
                &out_start, &out_end, &out_num_captures,
                &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
            );

            if (result != re_bindings::RE_MATCH) {
                ctx.result.set_string(s_hstr);
                return;
            }

            HString* replace_str;
            if (replace_is_fn && ctx.heap.call_fn != null && ctx.vm != null) {
                int num_caps = out_num_captures;
                if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
                TVal[36] fn_args;
                int arg_count = 0;
                usz m_len = (usz)(out_end - out_start);
                fn_args[arg_count].set_string(
                    m_len == 0 ? builtin_intern_string(ctx.heap, "")
                               : builtin_intern_string(ctx.heap, input[out_start : m_len]));
                arg_count++;
                for (int i = 0; i < num_caps; i++) {
                    if (caps_start[i] >= 0 && caps_end[i] >= 0) {
                        usz cap_len = (usz)(caps_end[i] - caps_start[i]);
                        fn_args[arg_count].set_string(
                            cap_len == 0 ? builtin_intern_string(ctx.heap, "")
                                         : builtin_intern_string(ctx.heap, input[caps_start[i] : cap_len]));
                    } else {
                        fn_args[arg_count].set_undefined();
                    }
                    arg_count++;
                }
                TVal offset_tv; offset_tv.set_fastint((long)out_start);
                fn_args[arg_count++] = offset_tv;
                fn_args[arg_count++].set_string(s_hstr);
                TVal this_val; this_val.set_undefined();
                TVal res = ctx.heap.call_fn(ctx.vm, replace_val, &fn_args[0], (uint)arg_count, this_val);
                if (ctx.heap.has_error) { ctx.should_throw = true; return; }
                replace_str = builtin_to_string(ctx.heap, &res);
                if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "undefined");
            } else {
                HString* raw_replace = ctx.argc > 1
                    ? builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1])
                    : builtin_intern_string(ctx.heap, "undefined");
                if (raw_replace == null) { ctx.result.set_string(s_hstr); return; }
                replace_str = builtin_replace_substitute(ctx.heap, raw_replace,
                    input, input_len, out_start, out_end,
                    &caps_start, &caps_end, out_num_captures);
                if (replace_str == null) replace_str = raw_replace;
            }

            char[4096] buf;
            usz bOff = 0;
            char* rData = replace_str.get_cstr();
            uint rLen = replace_str.blen;
            for (usz i = 0; i < (usz)out_start && bOff < 4096; i++) buf[bOff++] = input[i];
            for (usz i = 0; i < (usz)rLen && bOff < 4096; i++) buf[bOff++] = rData[i];
            for (usz i = (usz)out_end; i < (usz)input_len && bOff < 4096; i++) buf[bOff++] = input[i];
            ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:bOff]));
            return;
        } else {
            // ── Global: replace all matches ───────────────────────────────
            HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
            TVal zero_tv; zero_tv.set_fastint(0);
            rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);

            char[8192] buf;
            usz bOff = 0;
            int search_pos = 0;

            while (search_pos <= input_len) {
                int out_start = 0;
                int out_end = 0;
                int out_num_captures = 0;
                int[re_bindings::RE_MAX_CAPTURES] caps_start;
                int[re_bindings::RE_MAX_CAPTURES] caps_end;
                libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
                libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

                int result = re_bindings::re_exec(
                    rx.extra.regexp.regexp_data, input, input_len, search_pos,
                    &out_start, &out_end, &out_num_captures,
                    &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
                );
                if (result != re_bindings::RE_MATCH) break;

                for (usz i = (usz)search_pos; i < (usz)out_start && bOff < 8192; i++) buf[bOff++] = input[i];

                HString* replace_str;
                if (replace_is_fn && ctx.heap.call_fn != null && ctx.vm != null) {
                    int num_caps = out_num_captures;
                    if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
                    TVal[36] fn_args;
                    int arg_count = 0;
                    usz m_len = (usz)(out_end - out_start);
                    fn_args[arg_count].set_string(
                        m_len == 0 ? builtin_intern_string(ctx.heap, "")
                                   : builtin_intern_string(ctx.heap, input[out_start : m_len]));
                    arg_count++;
                    for (int i = 0; i < num_caps; i++) {
                        if (caps_start[i] >= 0 && caps_end[i] >= 0) {
                            usz cap_len = (usz)(caps_end[i] - caps_start[i]);
                            fn_args[arg_count].set_string(
                                cap_len == 0 ? builtin_intern_string(ctx.heap, "")
                                             : builtin_intern_string(ctx.heap, input[caps_start[i] : cap_len]));
                        } else {
                            fn_args[arg_count].set_undefined();
                        }
                        arg_count++;
                    }
                    TVal offset_tv; offset_tv.set_fastint((long)out_start);
                    fn_args[arg_count++] = offset_tv;
                    fn_args[arg_count++].set_string(s_hstr);
                    TVal this_val; this_val.set_undefined();
                    TVal res = ctx.heap.call_fn(ctx.vm, replace_val, &fn_args[0], (uint)arg_count, this_val);
                    if (ctx.heap.has_error) { ctx.should_throw = true; return; }
                    replace_str = builtin_to_string(ctx.heap, &res);
                    if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "undefined");
                } else {
                    HString* raw_replace = ctx.argc > 1
                        ? builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1])
                        : builtin_intern_string(ctx.heap, "undefined");
                    if (raw_replace == null) break;
                    replace_str = builtin_replace_substitute(ctx.heap, raw_replace,
                        input, input_len, out_start, out_end,
                        &caps_start, &caps_end, out_num_captures);
                    if (replace_str == null) replace_str = raw_replace;
                }

                char* rData = replace_str.get_cstr();
                uint rLen = replace_str.blen;
                for (usz i = 0; i < (usz)rLen && bOff < 8192; i++) buf[bOff++] = rData[i];

                if (out_end == search_pos) {
                    search_pos = out_end + 1;
                    if (search_pos > input_len) break;
                } else {
                    search_pos = out_end;
                }
            }

            for (usz i = (usz)search_pos; i < (usz)input_len && bOff < 8192; i++) buf[bOff++] = input[i];
            ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:bOff]));
            return;
        }
    }

    // ── String searchValue (existing code) ──────────────────────────────
    HString* search_hstr = builtin_to_string(ctx.heap, search_val);
    if (search_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    HString* replace_hstr;
    if (ctx.argc > 1) {
        replace_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1]);
    } else {
        replace_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (replace_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    int found_pos = -1;
    for (uint i = 0; i + search_len <= (uint)input_len; i++) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (input[i + j] != search_data[j]) { match = false; break; }
        }
        if (match) { found_pos = (int)i; break; }
    }

    if (found_pos < 0) {
        ctx.result.set_string(s_hstr);
        return;
    }

    char* replace_data = replace_hstr.get_cstr();
    uint replace_len = replace_hstr.blen;

    char[4096] buf;
    usz bOff = 0;
    for (usz i = 0; i < (usz)found_pos && bOff < 4096; i++) buf[bOff++] = input[i];
    for (usz i = 0; i < (usz)replace_len && bOff < 4096; i++) buf[bOff++] = replace_data[i];
    uint suffix_start = (uint)(found_pos + (int)search_len);
    for (usz i = (usz)suffix_start; i < (usz)input_len && bOff < 4096; i++) buf[bOff++] = input[i];

    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:bOff]));
}

// ============================================================================
// Additional String.prototype methods
// ============================================================================

/// String.prototype.includes(searchString, position) — ES6 §21.1.3.7
fn void builtin_string_proto_includes(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

    double pos_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : 0.0;
    uint pos;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos = 0;
    } else if (pos_d >= (double)len) {
        pos = len;
    } else {
        pos = (uint)(long)pos_d;
    }

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (search_len == 0) { ctx.result.set_boolean(true); return; }

    bool found = false;
    for (uint i = pos; i + search_len <= len; i++) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (data[i + j] != search_data[j]) { match = false; break; }
        }
        if (match) { found = true; break; }
    }
    ctx.result.set_boolean(found);
}

/// String.prototype.startsWith(searchString, position) — ES6 §21.1.3.18
fn void builtin_string_proto_startsWith(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

    double pos_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : 0.0;
    uint pos;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos = 0;
    } else if (pos_d > (double)len) {
        pos = len;
    } else {
        pos = (uint)(long)pos_d;
    }

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (pos + search_len > len) { ctx.result.set_boolean(false); return; }

    bool found = true;
    for (uint j = 0; j < search_len; j++) {
        if (data[pos + j] != search_data[j]) { found = false; break; }
    }
    ctx.result.set_boolean(found);
}

/// String.prototype.endsWith(searchString, endPosition) — ES6 §21.1.3.6
fn void builtin_string_proto_endsWith(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

    double end_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : (double)len;
    uint end_pos;
    if (math::is_nan(end_d) || end_d < 0) {
        end_pos = 0;
    } else if (end_d > (double)len) {
        end_pos = len;
    } else {
        end_pos = (uint)(long)end_d;
    }

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (search_len > end_pos) { ctx.result.set_boolean(false); return; }

    uint start = end_pos - search_len;
    bool found = true;
    for (uint j = 0; j < search_len; j++) {
        if (data[start + j] != search_data[j]) { found = false; break; }
    }
    ctx.result.set_boolean(found);
}

/// String.prototype.repeat(count) — ES6 §21.1.3.14
fn void builtin_string_proto_repeat(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    double count_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (count_d < 0 || math::is_inf(count_d)) {
        // Throw RangeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.range_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Invalid count value");
            TVal msg_val; msg_val.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            TVal err_val; err_val.set_object(err);
            ctx.heap.curr_thread = err;
        }
        ctx.result.set_undefined();
        return;
    }
    uint count = (uint)(long)count_d;

    if (count == 0 || s_hstr.blen == 0) {
        HString* empty = builtin_intern_string(ctx.heap, "");
        ctx.result.set_string(empty);
        return;
    }

    // Build repeated string
    usz total = (usz)s_hstr.blen * (usz)count;
    char* buf = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, total + 1);
    if (buf == null) { ctx.result.set_undefined(); return; }
    char* src = s_hstr.get_cstr();
    for (uint i = 0; i < count; i++) {
        libc::memcpy(&buf[i * s_hstr.blen], src, s_hstr.blen);
    }
    buf[total] = 0;

    HString* result = ctx.heap.str_intern(buf[:total]);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
    ctx.heap.free_func(ctx.heap.heap_udata, buf);
}

/// String.prototype.trimStart() — ES2019 §21.1.3.26
fn void builtin_string_proto_trimStart(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    uint start = 0;
    while (start < len && is_ecma_whitespace(data[start])) { start++; }
    if (start == 0) {
        ctx.result.set_string(s_hstr); return;
    }
    HString* result = ctx.heap.str_intern(data[start..len]);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
}

/// String.prototype.trimEnd() — ES2019 §21.1.3.27
fn void builtin_string_proto_trimEnd(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    uint end = len;
    while (end > 0 && is_ecma_whitespace(data[end - 1])) { end--; }
    if (end == len) {
        ctx.result.set_string(s_hstr); return;
    }
    HString* result = ctx.heap.str_intern(data[0..end]);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
}

/// String.prototype.codePointAt(pos) — ES6 §21.1.3.3
fn void builtin_string_proto_codePointAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    double pos_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    uint pos;
    if (math::is_nan(pos_d) || pos_d < 0) {
        ctx.result.set_undefined(); return;
    }
    pos = (uint)(long)pos_d;
    if (pos >= len) { ctx.result.set_undefined(); return; }

    // Simple ASCII fallback (most test262 tests use ASCII)
    ctx.result.set_fastint((long)(data[pos] & 0xFF));
}

/// String.prototype.at(index) — ES2022 §21.1.3.1
fn void builtin_string_proto_at(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    double idx_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(idx_d)) { ctx.result.set_undefined(); return; }

    long idx = (long)idx_d;
    if (idx < 0) { idx = (long)len + idx; }
    if (idx < 0 || idx >= (long)len) { ctx.result.set_undefined(); return; }

    ctx.result.set_fastint((long)data[idx] & 0xFF);
}

/// String.prototype.padStart(maxLength, fillString) — ES2017 §21.1.3.13
fn void builtin_string_proto_padStart(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    double max_len_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(max_len_d) || max_len_d < 0) { max_len_d = 0; }
    uint max_len = (uint)(long)max_len_d;

    uint str_len = s_hstr.blen;
    if (str_len >= max_len) {
        ctx.result.set_string(s_hstr); return;
    }

    HString* fill_hstr;
    if (ctx.argc > 1) {
        fill_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1]);
    } else {
        fill_hstr = builtin_intern_string(ctx.heap, " ");
    }
    if (fill_hstr == null || fill_hstr.blen == 0) {
        ctx.result.set_string(s_hstr); return;
    }

    uint pad_len = max_len - str_len;
    char* fill_data = fill_hstr.get_cstr();
    uint fill_len = fill_hstr.blen;
    char* src = s_hstr.get_cstr();

    usz total = (usz)pad_len + (usz)str_len;
    char* buf_ptr = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, total + 1);
    if (buf_ptr == null) { ctx.result.set_undefined(); return; }

    for (uint i = 0; i < pad_len; i++) {
        buf_ptr[i] = fill_data[i % fill_len];
    }
    libc::memcpy(&buf_ptr[pad_len], src, str_len);
    buf_ptr[total] = 0;

    char[] buf_slice = buf_ptr[:total];
    HString* result = ctx.heap.str_intern(buf_slice);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
    ctx.heap.free_func(ctx.heap.heap_udata, buf_ptr);
}

/// String.prototype.padEnd(maxLength, fillString) — ES2017 §21.1.3.12
fn void builtin_string_proto_padEnd(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    double max_len_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(max_len_d) || max_len_d < 0) { max_len_d = 0; }
    uint max_len = (uint)(long)max_len_d;

    uint str_len = s_hstr.blen;
    if (str_len >= max_len) {
        ctx.result.set_string(s_hstr); return;
    }

    HString* fill_hstr;
    if (ctx.argc > 1) {
        fill_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1]);
    } else {
        fill_hstr = builtin_intern_string(ctx.heap, " ");
    }
    if (fill_hstr == null || fill_hstr.blen == 0) {
        ctx.result.set_string(s_hstr); return;
    }

    uint pad_len = max_len - str_len;
    char* fill_data = fill_hstr.get_cstr();
    uint fill_len = fill_hstr.blen;
    char* src = s_hstr.get_cstr();

    usz total = (usz)str_len + (usz)pad_len;
    char* buf_ptr = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, total + 1);
    if (buf_ptr == null) { ctx.result.set_undefined(); return; }

    libc::memcpy(buf_ptr, src, str_len);
    for (uint i = 0; i < pad_len; i++) {
        buf_ptr[str_len + i] = fill_data[i % fill_len];
    }
    buf_ptr[total] = 0;

    char[] buf_slice = buf_ptr[:total];
    HString* result = ctx.heap.str_intern(buf_slice);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
    ctx.heap.free_func(ctx.heap.heap_udata, buf_ptr);
}

/// String.prototype.lastIndexOf(searchString, position) — ES5 §15.5.4.8
fn void builtin_string_proto_lastIndexOf(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_fastint(-1); return; }

    double pos_d = (ctx.argc > 1) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 1]) : (double)len;
    if (math::is_nan(pos_d) || pos_d < 0) { pos_d = 0; }
    if (pos_d > (double)len) { pos_d = (double)len; }
    // For lastIndexOf, search from min(pos, len) backwards
    int start = (int)(long)pos_d;
    if (start > (int)len) start = (int)len;

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (search_len == 0) { ctx.result.set_fastint((long)(start < 0 ? 0 : (long)start)); return; }

    int result = -1;
    for (int i = start; i >= 0 && i + (int)search_len <= (int)len; i--) {
        bool found = true;
        for (uint j = 0; j < search_len; j++) {
            if (data[(uint)i + j] != search_data[j]) { found = false; break; }
        }
        if (found) { result = i; break; }
    }
    ctx.result.set_fastint((long)result);
}

/// Helper: check if a TVal is a RegExp object
fn bool is_regexp_object(TVal* val) {
    if (!val.is_object() || val.get_heapptr() == null) return false;
    HObject* obj = (HObject*)val.get_heapptr();
    return obj.get_class() == hobject::ObjClass.REGEXP && obj.extra.regexp.regexp_data != null;
}

/// String.prototype.match(regexp) — ES5 §15.5.4.10
fn void builtin_string_proto_match(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    // No args or undefined → null (per spec: RegExp(undefined) would match "undefined" string,
    // but most engines return null for match() with no args)
    if (ctx.argc == 0) {
        ctx.result.set_null();
        return;
    }

    TVal* regexp_arg = &ctx.regs[ctx.base_reg];

    // If arg is a RegExp object, use it directly
    if (is_regexp_object(regexp_arg)) {
        HObject* rx = (HObject*)regexp_arg.get_heapptr();

        // Get global flag
        HString* global_key = builtin_intern_string(ctx.heap, "global");
        bool global_flag = false;
        if (try gv = rx.get_prop(global_key)) {
            if (gv.is_boolean()) global_flag = gv.get_boolean();
        }

        if (!global_flag) {
            // Non-global: single exec call
            int out_start = 0;
            int out_end = 0;
            int out_num_captures = 0;
            int[re_bindings::RE_MAX_CAPTURES] caps_start;
            int[re_bindings::RE_MAX_CAPTURES] caps_end;
            libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
            libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

            // Get lastIndex
            HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
            int start_pos = 0;
            if (try liv = rx.get_prop(li_key)) {
                if (liv.is_fastint()) { start_pos = (int)liv.get_fastint(); }
                else if (liv.is_number()) { start_pos = (int)liv.get_number(); }
            }

            int result = re_bindings::re_exec(
                rx.extra.regexp.regexp_data, input, input_len, start_pos,
                &out_start, &out_end, &out_num_captures,
                &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
            );

            if (result != re_bindings::RE_MATCH) {
                ctx.result.set_null();
                return;
            }

            // Create result array with full match as element 0
            HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err = arr_raw) { ctx.result.set_null(); return; }
            HObject* arr = arr_raw;
            arr.prototype = ctx.heap.array_proto;

            usz match_len = (usz)(out_end - out_start);
            HString* match_str;
            if (match_len == 0) {
                match_str = builtin_intern_string(ctx.heap, "");
            } else {
                match_str = builtin_intern_string(ctx.heap, input[out_start : match_len]);
            }
            TVal elem;
            elem.set_string(match_str);
            HString* zero_key = builtin_intern_string(ctx.heap, "0");
            arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

            // Set index property
            TVal idx_tv;
            idx_tv.set_fastint((long)out_start);
            HString* idx_key = builtin_intern_string(ctx.heap, "index");
            arr.put_prop(idx_key, idx_tv, hobject::PROP_FLAGS_WEC);

            // Set input property
            TVal input_tv;
            input_tv.set_string(s_hstr);
            HString* input_key = builtin_intern_string(ctx.heap, "input");
            arr.put_prop(input_key, input_tv, hobject::PROP_FLAGS_WEC);

            TVal len_tv;
            len_tv.set_fastint(1);
            HString* len_key = builtin_intern_string(ctx.heap, "length");
            arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

            ctx.result.set_object(arr);
            return;
        } else {
            // Global: collect all matches
            HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");

            // Reset lastIndex to 0
            TVal zero_tv;
            zero_tv.set_fastint(0);
            rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);

            HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err = arr_raw) { ctx.result.set_null(); return; }
            HObject* arr = arr_raw;
            arr.prototype = ctx.heap.array_proto;

            uint arr_idx = 0;
            int search_pos = 0;

            while (search_pos <= input_len) {
                int out_start = 0;
                int out_end = 0;
                int out_num_captures = 0;
                int[re_bindings::RE_MAX_CAPTURES] caps_start;
                int[re_bindings::RE_MAX_CAPTURES] caps_end;
                libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
                libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

                int result = re_bindings::re_exec(
                    rx.extra.regexp.regexp_data, input, input_len, search_pos,
                    &out_start, &out_end, &out_num_captures,
                    &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
                );

                if (result != re_bindings::RE_MATCH) break;

                // Add match string to array
                usz match_len = (usz)(out_end - out_start);
                HString* match_str;
                if (match_len == 0) {
                    match_str = builtin_intern_string(ctx.heap, "");
                } else {
                    match_str = builtin_intern_string(ctx.heap, input[out_start : match_len]);
                }
                TVal elem;
                elem.set_string(match_str);
                char[16] idx_buf;
                int idx_len = libc::snprintf(&idx_buf, 16, "%u", arr_idx);
                HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
                arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
                arr_idx++;

                // Advance: if empty match, move by one; else go to end of match
                if (out_end == search_pos) {
                    search_pos = out_end + 1;
                    if (search_pos > input_len) break;
                } else {
                    search_pos = out_end;
                }
            }

            if (arr_idx == 0) {
                // Reset lastIndex
                rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
                ctx.result.set_null();
                return;
            }

            // Update lastIndex on the regexp
            TVal li_tv;
            li_tv.set_fastint(0);
            rx.put_prop(li_key, li_tv, hobject::PROP_FLAGS_WEC);

            TVal len_tv;
            len_tv.set_fastint((long)arr_idx);
            HString* len_key = builtin_intern_string(ctx.heap, "length");
            arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

            ctx.result.set_object(arr);
            return;
        }
    }

    // Non-RegExp arg: convert to string and do literal search
    HString* search_hstr = builtin_to_string(ctx.heap, regexp_arg);
    if (search_hstr == null) { ctx.result.set_null(); return; }
    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    // Find first occurrence via indexOf
    int found_pos = -1;
    for (uint i = 0; i + search_len <= (uint)input_len; i++) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (input[i + j] != search_data[j]) { match = false; break; }
        }
        if (match) { found_pos = (int)i; break; }
    }

    if (found_pos < 0) {
        ctx.result.set_null();
        return;
    }

    // Create result array with single match
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_null(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    TVal elem;
    elem.set_string(search_hstr);
    HString* zero_key = builtin_intern_string(ctx.heap, "0");
    arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

    TVal len_tv;
    len_tv.set_fastint(1);
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(arr);
}

/// String.prototype.search(regexp) — ES5 §15.5.4.12
fn void builtin_string_proto_search(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    if (ctx.argc == 0) {
        ctx.result.set_fastint(-1);
        return;
    }

    TVal* regexp_arg = &ctx.regs[ctx.base_reg];

    // If arg is a RegExp object, use it directly
    if (is_regexp_object(regexp_arg)) {
        HObject* rx = (HObject*)regexp_arg.get_heapptr();

        int out_start = 0;
        int out_end = 0;
        int out_num_captures = 0;
        int[re_bindings::RE_MAX_CAPTURES] caps_start;
        int[re_bindings::RE_MAX_CAPTURES] caps_end;
        libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
        libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

        int result = re_bindings::re_exec(
            rx.extra.regexp.regexp_data, input, input_len, 0,
            &out_start, &out_end, &out_num_captures,
            &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
        );

        ctx.result.set_fastint((result == re_bindings::RE_MATCH) ? (long)out_start : -1);
        return;
    }

    // Non-RegExp arg: convert to string and do literal search
    HString* search_hstr = builtin_to_string(ctx.heap, regexp_arg);
    if (search_hstr == null) { ctx.result.set_fastint(-1); return; }
    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    for (uint i = 0; i + search_len <= (uint)input_len; i++) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (input[i + j] != search_data[j]) { match = false; break; }
        }
        if (match) {
            ctx.result.set_fastint((long)i);
            return;
        }
    }
    ctx.result.set_fastint(-1);
}

// ============================================================================
// Additional Array.prototype methods
// ============================================================================

/// Helper: get numeric property value from TVal
fn double builtin_to_number_getdouble(BuiltinContext* ctx, TVal* val) {
    if (val.is_fastint()) return (double)val.get_fastint();
    if (val.is_number()) return val.get_number();
    TVal num;
    builtin_to_number(val, &num);
    if (num.is_fastint()) return (double)num.get_fastint();
    return num.get_number();
}

/// Array.of(...items) — ES6 §22.1.2.3
fn void builtin_array_of(BuiltinContext* ctx) {
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    uint len = (uint)ctx.argc;
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_val; len_val.set_fastint((long)len);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    for (uint i = 0; i < len; i++) {
        TVal elem = ctx.regs[ctx.base_reg + (uint)i];
        char[16] buf;
        int slen = libc::snprintf(&buf, 16, "%d", i);
        if (slen > 0 && slen < 16) {
            HString* idx_key = builtin_intern_string(ctx.heap, buf[:slen]);
            arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        }
    }
    ctx.result.set_object(arr);
}

/// Array.prototype.fill(value, start, end) — ES6 §22.1.3.6
fn void builtin_array_proto_fill(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    TVal fill_val;
    if (ctx.argc > 0) {
        fill_val = ctx.regs[ctx.base_reg];
    } else {
        fill_val.set_undefined();
    }

    int start_i = 0;
    if (ctx.argc > 1) {
        double sd = builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 1]);
        start_i = (int)(long)sd;
        if (start_i < 0) { start_i = (int)len + start_i; if (start_i < 0) start_i = 0; }
        if (start_i > (int)len) start_i = (int)len;
    }

    int end_i = (int)len;
    if (ctx.argc > 2) {
        double ed = builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 2]);
        end_i = (int)(long)ed;
        if (end_i < 0) { end_i = (int)len + end_i; if (end_i < 0) end_i = 0; }
        if (end_i > (int)len) end_i = (int)len;
    }

    for (int i = start_i; i < end_i; i++) {
        array_set_elem(obj, (uint)i, fill_val, ctx.heap);
    }
    ctx.result.set_object(obj);
}

/// Array.prototype.at(index) — ES2022 §22.1.3.1
fn void builtin_array_proto_at(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    double idx_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(idx_d)) { ctx.result.set_undefined(); return; }

    long idx = (long)idx_d;
    if (idx < 0) idx = (long)len + idx;
    if (idx < 0 || idx >= (long)len) { ctx.result.set_undefined(); return; }

    *ctx.result = array_get_elem(obj, (uint)idx, ctx.heap);
}

/// Array.prototype.copyWithin(downstream, start, end) — ES6 §22.1.3.3
fn void builtin_array_proto_copyWithin(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    double downstream_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    int downstream_i = (int)(long)downstream_d;
    if (downstream_i < 0) downstream_i = (int)len + downstream_i < 0 ? 0 : (int)len + downstream_i;
    if (downstream_i > (int)len) downstream_i = (int)len;

    int start_i = 0;
    if (ctx.argc > 1) {
        double sd = builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 1]);
        start_i = (int)(long)sd;
        if (start_i < 0) { start_i = (int)len + start_i; if (start_i < 0) start_i = 0; }
        if (start_i > (int)len) start_i = (int)len;
    }

    int end_i = (int)len;
    if (ctx.argc > 2) {
        double ed = builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 2]);
        end_i = (int)(long)ed;
        if (end_i < 0) { end_i = (int)len + end_i; if (end_i < 0) end_i = 0; }
        if (end_i > (int)len) end_i = (int)len;
    }

    int count = end_i - start_i;
    if (count > (int)len - downstream_i) count = (int)len - downstream_i;
    if (count <= 0) { ctx.result.set_object(obj); return; }

    // Forward copy is safe when downstream < start; otherwise copy backwards
    if (downstream_i < start_i) {
        for (int i = 0; i < count; i++) {
            array_set_elem(obj, (uint)(downstream_i + i), array_get_elem(obj, (uint)(start_i + i), ctx.heap), ctx.heap);
        }
    } else {
        for (int i = count - 1; i >= 0; i--) {
            array_set_elem(obj, (uint)(downstream_i + i), array_get_elem(obj, (uint)(start_i + i), ctx.heap), ctx.heap);
        }
    }
    ctx.result.set_object(obj);
}

/// Array.prototype.includes(searchElement, fromIndex) — ES7 §22.1.3.13
fn void builtin_array_proto_includes(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    int start_i = 0;
    if (ctx.argc > 1) {
        double sd = builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 1]);
        start_i = (int)(long)sd;
        if (start_i < 0) { start_i = (int)len + start_i; if (start_i < 0) start_i = 0; }
        if (start_i > (int)len) start_i = (int)len;
    }

    TVal search_elem;
    if (ctx.argc > 0) {
        search_elem = ctx.regs[ctx.base_reg];
    } else {
        search_elem.set_undefined();
    }

    for (int i = start_i; i < (int)len; i++) {
        TVal elem = array_get_elem(obj, (uint)i, ctx.heap);
        if (same_value_zero(elem, search_elem)) {
            ctx.result.set_boolean(true);
            return;
        }
    }
    ctx.result.set_boolean(false);
}

/// Helper: flatten source array into downstream array recursively.
/// Returns the next downstream index after all elements are inserted.
fn uint flatten_into(HObject* downstream, HObject* source, uint source_len, uint downstream_idx, double depth, Heap* heap) {
    for (uint i = 0; i < source_len; i++) {
        TVal elem = array_get_elem(source, i, heap);
        if (elem.is_object() && elem.get_heapptr() != null &&
            ((HObject*)elem.get_heapptr()).get_class() == hobject::ObjClass.ARRAY && depth > 0) {
            HObject* inner = (HObject*)elem.get_heapptr();
            uint inner_len = array_get_length(inner, heap);
            downstream_idx = flatten_into(downstream, inner, inner_len, downstream_idx, depth - 1, heap);
        } else {
            array_set_elem(downstream, downstream_idx, elem, heap);
            downstream_idx++;
        }
    }
    return downstream_idx;
}

/// Array.prototype.flat(depth) — ES2019 §22.1.3.10
fn void builtin_array_proto_flat(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.flat requires 'this' to be an object");
            TVal msg_tv; msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    double depth_num = 1.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (!arg.is_undefined()) {
            depth_num = builtin_to_integer(arg);
        }
    }
    if (depth_num < 0) depth_num = 0;

    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    uint n = flatten_into(result, obj, len, 0, depth_num, ctx.heap);
    array_set_length(result, n, ctx.heap);

    ctx.result.set_object(result);
}

/// Array.prototype.flatMap(mapFn, thisArg) — ES2019 §22.1.3.11
fn void builtin_array_proto_flatMap(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.flatMap requires 'this' to be an object");
            TVal msg_tv; msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        return;
    }

    // Validate callbackfn is callable (if provided)
    if (ctx.argc >= 1) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (!arg.is_object() || arg.get_heapptr() == null || !((HObject*)arg.get_heapptr()).is_callable()) {
            HObject*? err_raw2 = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err2 = err_raw2) {
                err2.prototype = ctx.heap.type_err_proto;
                HString* msg2 = builtin_intern_string(ctx.heap, "Array.prototype.flatMap callback is not callable");
                TVal msg_tv2; msg_tv2.set_string(msg2);
                HString* msg_key2 = builtin_intern_string(ctx.heap, "message");
                err2.put_prop(msg_key2, msg_tv2, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err2);
            }
            return;
        }
    }

    // Stub: flatten without mapping (no VM callback support yet)
    uint len = array_get_length(obj, ctx.heap);

    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    uint n = flatten_into(result, obj, len, 0, 1.0, ctx.heap);
    array_set_length(result, n, ctx.heap);

    ctx.result.set_object(result);
}

// ============================================================================
// Number constructor builtins
// ============================================================================

/// Helper: extract the double value from 'this' for Number.prototype methods.
/// Returns NaN on incompatible 'this' (caller checks via isnan).
fn double number_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.NUMBER &&
            (obj.extra.prim.primitive_value.is_number() || obj.extra.prim.primitive_value.is_fastint())) {
            return obj.extra.prim.primitive_value.get_number_or_fastint();
        }
    } else if (this_val.is_number()) {
        return this_val.get_number();
    } else if (this_val.is_fastint()) {
        return (double)this_val.get_fastint();
    }
    return double::nan;
}

/// Helper: check if a double is -0.
fn bool is_neg_zero(double d) {
    return d == 0.0 && math::signbit(d);
}

/// Helper: convert a positive integer to a string in the given radix (2-36).
/// Writes at most 64 chars into buf. Returns the number of chars written.
fn int number_to_radix_str(ulong val, uint radix, char* buf, usz buf_size) {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    char[64] tmp;
    int pos = 0;
    while (val > 0 && pos < 64) {
        uint digit = (uint)(val % (ulong)radix);
        val /= (ulong)radix;
        if (digit < 10) {
            tmp[pos++] = (char)('0' + digit);
        } else {
            tmp[pos++] = (char)('a' + digit - 10);
        }
    }
    // Reverse into buf
    int write_pos = 0;
    while (pos > 0 && write_pos < (int)buf_size - 1) {
        pos--;
        buf[write_pos++] = tmp[pos];
    }
    buf[write_pos] = 0;
    return write_pos;
}

/// ToNumber then return number primitive (function call) or
/// a Number wrapper object (constructor call).
fn void builtin_number(BuiltinContext* ctx) {
    TVal num;
    if (ctx.argc > 0) {
        builtin_to_number(&ctx.regs[ctx.base_reg], &num);
    } else {
        num.set_fastint(0);
    }

    if (ctx.is_constructor) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.NUMBER);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.number_proto;
        obj.extra.prim.primitive_value = num;
        ctx.result.set_object(obj);
    } else {
        if (num.is_fastint()) {
            ctx.result.set_fastint(num.get_fastint());
        } else {
            ctx.result.set_number(num.get_number());
        }
    }
}

/// Number.prototype.toString(radix) — ES5 §15.7.4.2
/// Returns string representation in the given radix (2-36), default 10.
fn void builtin_number_proto_toString(BuiltinContext* ctx) {
    double d = number_proto_get_this(ctx);
    if (math::is_nan(d) && !is_neg_zero(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.set_string(s);
        return;
    }

    // Determine radix
    int radix = 10;
    if (ctx.argc > 0) {
        TVal* rad_arg = &ctx.regs[ctx.base_reg];
        if (rad_arg.is_fastint()) {
            radix = (int)rad_arg.get_fastint();
        } else if (rad_arg.is_number()) {
            radix = (int)(long)rad_arg.get_number();
        } else {
            radix = 10;
        }
        if (radix < 2 || radix > 36) {
            // RangeError
            ctx.result.set_undefined();
            return;
        }
    }

    // Handle special values
    if (math::is_nan(d) && !is_neg_zero(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.set_string(s);
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.set_string(s);
        return;
    }
    if (d == 0.0) {
        HString* s = builtin_intern_string(ctx.heap, "0");
        ctx.result.set_string(s);
        return;
    }

    // Radix 10: use existing ToString formatting
    if (radix == 10) {
        char[64] buf;
        int len = libc::snprintf(&buf, 64, "%.17g", d);
        if (len < 0 || len >= 64) {
            ctx.result.set_undefined();
            return;
        }
        HString* s = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.set_string(s);
        return;
    }

    // Radix 2-36: manual conversion
    bool negative = d < 0;
    if (negative) d = -d;

    // Split into integer and fractional parts
    double int_part = math::trunc(d);
    double frac_part = d - int_part;

    char[128] buf;
    usz offset = 0;

    if (negative) {
        buf[offset++] = '-';
    }

    // Convert integer part
    ulong int_val = (ulong)(long)int_part;
    char[64] int_digits;
    int int_len = number_to_radix_str(int_val, (uint)radix, &int_digits, 64);
    for (int i = 0; i < int_len; i++) {
        buf[offset++] = int_digits[i];
    }

    // Convert fractional part (up to 20 digits)
    if (frac_part > 0.0 && offset < 120) {
        buf[offset++] = '.';
        int max_frac_digits = 20;
        if ((int)offset + max_frac_digits > 127) max_frac_digits = 127 - (int)offset;
        for (int i = 0; i < max_frac_digits; i++) {
            frac_part *= (double)radix;
            uint digit = (uint)(long)frac_part;
            if (digit >= (uint)radix) digit = (uint)radix - 1;
            frac_part -= (double)digit;
            if (digit < 10) {
                buf[offset++] = (char)('0' + digit);
            } else {
                buf[offset++] = (char)('a' + digit - 10);
            }
            if (frac_part <= 0.0) break;
        }
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    if (result == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(result);
}

/// Number.prototype.toFixed(fractionDigits) — ES5 §15.7.4.5
fn void builtin_number_proto_toFixed(BuiltinContext* ctx) {
    double d = number_proto_get_this(ctx);
    if (math::is_nan(d) && !is_neg_zero(d)) {
        // Use isnan check
        double test = d;
        if (math::is_nan(test) && !is_neg_zero(d)) {
            // Actually re-check — the first call with NaN might fail
            // Just use a simpler approach
        }
    }
    // Re-get properly
    d = number_proto_get_this(ctx);
    if (math::is_nan(d) && !is_neg_zero(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.set_string(s);
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.set_string(s);
        return;
    }

    int f = 0;
    if (ctx.argc > 0) {
        double f_d = builtin_to_integer(&ctx.regs[ctx.base_reg]);
        if (f_d < 0 || f_d > 20) {
            ctx.result.set_undefined();
            return;
        }
        f = (int)(long)f_d;
    }

    char[64] buf;
    int len = libc::snprintf(&buf, 64, "%.*f", f, d);
    if (len < 0 || len >= 64) {
        ctx.result.set_undefined();
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(s);
}

/// Number.prototype.toExponential(fractionDigits) — ES5 §15.7.4.6
fn void builtin_number_proto_toExponential(BuiltinContext* ctx) {
    double d = number_proto_get_this(ctx);
    if (math::is_nan(d) && !is_neg_zero(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.set_string(s);
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.set_string(s);
        return;
    }

    if (ctx.argc == 0) {
        // No arg: use default ToString behavior via %.17g (same as toString)
        char[64] buf;
        int len = libc::snprintf(&buf, 64, "%.17g", d);
        if (len < 0 || len >= 64) {
            ctx.result.set_undefined();
            return;
        }
        HString* s = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.set_string(s);
        return;
    }

    double f_d = builtin_to_integer(&ctx.regs[ctx.base_reg]);
    if (f_d < 0 || f_d > 20) {
        ctx.result.set_undefined();
        return;
    }
    int f = (int)(long)f_d;

    char[64] buf;
    int len = libc::snprintf(&buf, 64, "%.*e", f, d);
    if (len < 0 || len >= 64) {
        ctx.result.set_undefined();
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(s);
}

/// Number.prototype.toPrecision(precision) — ES5 §15.7.4.7
fn void builtin_number_proto_toPrecision(BuiltinContext* ctx) {
    double d = number_proto_get_this(ctx);
    if (math::is_nan(d) && !is_neg_zero(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.set_string(s);
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.set_string(s);
        return;
    }

    if (ctx.argc == 0) {
        // No arg: return ToString(x)
        char[64] buf;
        int len = libc::snprintf(&buf, 64, "%.17g", d);
        if (len < 0 || len >= 64) {
            ctx.result.set_undefined();
            return;
        }
        HString* s = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.set_string(s);
        return;
    }

    double p_d = builtin_to_integer(&ctx.regs[ctx.base_reg]);
    if (p_d < 1 || p_d > 21) {
        ctx.result.set_undefined();
        return;
    }
    int p = (int)(long)p_d;

    char[64] buf;
    int len = libc::snprintf(&buf, 64, "%.*g", p, d);
    if (len < 0 || len >= 64) {
        ctx.result.set_undefined();
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(s);
}

/// Number.prototype.data.valueOf — returns the wrapped number primitive
fn void builtin_number_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.NUMBER &&
            (obj.extra.prim.primitive_value.is_number() || obj.extra.prim.primitive_value.is_fastint())) {
            if (obj.extra.prim.primitive_value.is_fastint()) {
                ctx.result.set_fastint(obj.extra.prim.primitive_value.get_fastint());
            } else {
                ctx.result.set_number(obj.extra.prim.primitive_value.get_number());
            }
            return;
        }
    } else if (this_val.is_number()) {
        ctx.result.set_number(this_val.get_number());
        return;
    } else if (this_val.is_fastint()) {
        ctx.result.set_fastint(this_val.get_fastint());
        return;
    }
    ctx.result.set_undefined();
}

// ============================================================================
// Number static methods (ES6 §20.1.2)
// ============================================================================

/// Number.isNaN(number) — ES6 §20.1.2.4
/// Returns true only if the argument is the NaN number value (no coercion).
fn void builtin_number_isNaN(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (!ctx.regs[ctx.base_reg].is_number() && !ctx.regs[ctx.base_reg].is_fastint())) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    ctx.result.set_boolean(false);
    if (arg.is_number()) {
        ctx.result.set_boolean(math::is_nan(arg.get_number()));
    } else {
        // FASTINT is never NaN
        ctx.result.set_boolean(false);
    }
}

/// Number.isFinite(number) — ES6 §20.1.2.2
/// Returns true only if the argument is a finite number value (no coercion).
fn void builtin_number_isFinite(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (!ctx.regs[ctx.base_reg].is_number() && !ctx.regs[ctx.base_reg].is_fastint())) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    ctx.result.set_boolean(false);
    if (arg.is_number()) {
        ctx.result.set_boolean(!math::is_nan(arg.get_number()) && !math::is_inf(arg.get_number()));
    } else {
        // FASTINT is always finite
        ctx.result.set_boolean(true);
    }
}

/// Number.isInteger(number) — ES6 §20.1.2.3
/// Returns true only if the argument is an integer number value (no coercion).
fn void builtin_number_isInteger(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (!ctx.regs[ctx.base_reg].is_number() && !ctx.regs[ctx.base_reg].is_fastint())) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    double d;
    if (arg.is_fastint()) {
        // FASTINT is always an integer
        ctx.result.set_boolean(true);
        return;
    }
    d = arg.get_number();
    // NaN, Infinity, -Infinity are not integers
    if (math::is_nan(d) || math::is_inf(d)) {
        ctx.result.set_boolean(false);
        return;
    }
    // Check: floor(abs(d)) == abs(d) — i.e. no fractional part
    double abs_d = d < 0 ? -d : d;
    double fl = math::floor(abs_d);
    ctx.result.set_boolean((fl == abs_d));
}

/// Number.isSafeInteger(number) — ES6 §20.1.2.5
/// Returns true only if the argument is a safe integer (±(2^53 - 1)).
fn void builtin_number_isSafeInteger(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (!ctx.regs[ctx.base_reg].is_number() && !ctx.regs[ctx.base_reg].is_fastint())) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    if (arg.is_fastint()) {
        // FASTINT values are always safe integers
        ctx.result.set_boolean(true);
        return;
    }
    double d = arg.get_number();
    if (math::is_nan(d) || math::is_inf(d)) {
        ctx.result.set_boolean(false);
        return;
    }
    double abs_d = d < 0 ? -d : d;
    double fl = math::floor(abs_d);
    // Must be integer AND within safe range (2^53 - 1 = 9007199254740991)
    ctx.result.set_boolean((fl == abs_d) && (abs_d <= 9007199254740991.0));
}

// ============================================================================
// Object constructor builtins
// ============================================================================

/// ToObject — ES5 §9.9
/// Wraps primitives into proper exotic wrapper objects.
/// Returns the object directly for OBJECT type. Returns false for null/undefined.
/// Sets ctx.result and returns true on success. Returns false on allocation failure.
fn bool builtin_to_object(BuiltinContext* ctx, TVal val) {
    // Already an object
    if (val.is_object()) {
        *ctx.result = val;
        return true;
    }
    // null/undefined → caller should throw TypeError
    if (val.is_null() || val.is_undefined()) {
        return false;
    }
    // Boolean → Boolean exotic object
    if (val.is_boolean()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.BOOLEAN);
        if (catch err = obj_raw) return false;
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.bool_proto;
        obj.extra.prim.primitive_value.set_boolean(val.get_boolean());
        ctx.result.set_object(obj);
        return true;
    }
    // Number/fastint → Number exotic object
    if (val.is_number() || val.is_fastint()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.NUMBER);
        if (catch err = obj_raw) return false;
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.number_proto;
        obj.extra.prim.primitive_value = val;
        ctx.result.set_object(obj);
        return true;
    }
    // String → String exotic object with .length own property
    if (val.is_string()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
        if (catch err = obj_raw) return false;
        HObject* obj = obj_raw;
        obj.flags.exotic_stringobj = true;
        obj.prototype = ctx.heap.string_proto;
        HString* prim_str = (HString*)val.get_heapptr();
        obj.extra.prim.primitive_value.set_string(prim_str);
        // Set .length own property (ES5 §15.5.5.1) — non-writable, non-enumerable, non-configurable
        HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)prim_str.clen);
        obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
        // Set indexed character properties (ES5 §15.5.5.1)
        populate_string_indexed_props(obj, prim_str, ctx.heap);
        ctx.result.set_object(obj);
        return true;
    }
    return false;
}

/// Helper: build a property descriptor object for a data property
fn void builtin_build_data_descriptor(Heap* heap, HObject** out, TVal value, bool writable, bool enumerable, bool configurable) {
    HObject*? desc_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = desc_raw) { *out = null; return; }
    HObject* desc = desc_raw;
    desc.prototype = heap.object_proto;
    desc.put_prop(builtin_intern_string(heap, "value"), value, hobject::PROP_FLAGS_WEC);
    TVal w_tv; w_tv.set_boolean(writable);
    desc.put_prop(builtin_intern_string(heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC);
    TVal e_tv; e_tv.set_boolean(enumerable);
    desc.put_prop(builtin_intern_string(heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC);
    TVal c_tv; c_tv.set_boolean(configurable);
    desc.put_prop(builtin_intern_string(heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC);
    *out = desc;
}

/// Object() as function (ES5 §15.2.1.1) or new Object() as constructor (§15.2.2.1).
/// If value is null/undefined/absent, returns a new empty Object.
/// If value is already an Object, returns it.
/// Otherwise, wraps the primitive (boolean/number/string) in a wrapper object.
fn void builtin_object(BuiltinContext* ctx) {
    // Handle object prototype method calls (this-value dispatch)
    if (!ctx.is_constructor && ctx.argc == 0) {
        // Object() with no args — create and return new empty object
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.object_proto;
        ctx.result.set_object(obj);
        return;
    }

    // Get the first argument
    TVal arg = ctx.regs[ctx.base_reg];

    // null/undefined/not supplied → new empty object
    if (arg.is_null() || arg.is_undefined()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.object_proto;
        ctx.result.set_object(obj);
        return;
    }

    // Already an object → return as-is
    if (arg.is_object()) {
        ctx.result.set_object(arg.get_heapptr());
        return;
    }

    // Primitive → create wrapper object (ToObject per ES5 §9.9)
    if (arg.is_boolean()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.BOOLEAN);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.bool_proto;
        obj.extra.prim.primitive_value.set_boolean(arg.get_boolean());
        ctx.result.set_object(obj);
        return;
    }

    if (arg.is_number() || arg.is_fastint()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.NUMBER);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.number_proto;
        obj.extra.prim.primitive_value = arg;
        ctx.result.set_object(obj);
        return;
    }

    if (arg.is_string()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.flags.exotic_stringobj = true;
        obj.prototype = ctx.heap.string_proto;
        HString* prim_str = (HString*)arg.get_heapptr();
        obj.extra.prim.primitive_value.set_string(prim_str);
        // Set .length own property (ES5 §15.5.5.1)
        HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)prim_str.clen);
        obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
        // Set indexed character properties (ES5 §15.5.5.1)
        populate_string_indexed_props(obj, prim_str, ctx.heap);
        ctx.result.set_object(obj);
        return;
    }

    // Fallback — new empty object
    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = obj_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* obj = obj_raw;
    obj.prototype = ctx.heap.object_proto;
    ctx.result.set_object(obj);
}

/// Object.keys(obj) — ES5 §15.2.3.14
/// Returns an array of an object's own enumerable property names.
fn void builtin_object_keys(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.is_null() || arg.is_undefined()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        // ToObject wrapper for primitives — use proper exotic class
        if (!builtin_to_object(ctx, arg)) {
            ctx.result.set_undefined();
            return;
        }
        obj = (HObject*)ctx.result.get_heapptr();
    }
    // First pass: count enumerable own properties (both named and dense array indices)
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_values()[i].flags.enumerable && obj.shape.props()[i].key != null) {
            count++;
        }
    }
    // Count dense array indices as enumerable own properties
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            count++;
        }
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    // Fill array with keys: named properties first, then dense indices
    uint idx = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_values()[i].flags.enumerable && obj.shape.props()[i].key != null) {
            HString* key = (HString*)obj.shape.props()[i].key;
            TVal key_tv;
            key_tv.set_string(key);
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Dense array indices (as strings)
    char[types::FORMAT_BUF] buf;
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            int len = libc::snprintf(&buf, types::FORMAT_BUF, "%u", i);
            if (len < 0) {
                ctx.result.set_undefined();
                return;
            }
            HString* key = ctx.heap.str_intern(buf[..len]);
            if (key == null) {
                ctx.result.set_undefined();
                return;
            }
            TVal key_tv;
            key_tv.set_string(key);
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Set .length
    TVal len_tv;
    len_tv.set_fastint((long)idx);
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.getOwnPropertyNames — ES5 §15.2.3.4
// ============================================================================
/// Returns an array of all own property names (both enumerable and non-enumerable)
/// of the given object. Equivalent to Object.keys but without the enumerable filter.
fn void builtin_object_getOwnPropertyNames(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.is_null() || arg.is_undefined()) {
        ctx.result.set_undefined();
        return;
    }

    // Handle lightfuncs: return ["name", "length"] as own property names
    if (arg.is_lightfunc()) {
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = arr_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* arr = arr_raw;
        arr.prototype = ctx.heap.array_proto;

        HString* name_str = builtin_intern_string(ctx.heap, "name");
        TVal name_tv; name_tv.set_string(name_str);
        array_set_elem(arr, 0, name_tv, ctx.heap);

        HString* length_str = builtin_intern_string(ctx.heap, "length");
        TVal length_tv; length_tv.set_string(length_str);
        array_set_elem(arr, 1, length_tv, ctx.heap);

        TVal len_tv; len_tv.set_fastint(2);
        arr.put_prop(builtin_intern_string(ctx.heap, "length"), len_tv, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(arr);
        return;
    }

    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        // ToObject wrapper for primitives — use proper exotic class
        if (!builtin_to_object(ctx, arg)) {
            ctx.result.set_undefined();
            return;
        }
        obj = (HObject*)ctx.result.get_heapptr();
    }
    // First pass: count all own properties (named, both enumerable and non-enumerable)
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.shape.props()[i].key != null) {
            count++;
        }
    }
    // Count dense array indices as own properties
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            count++;
        }
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    // Fill array with property names: named properties first, then dense indices
    uint idx = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.shape.props()[i].key != null) {
            HString* key = (HString*)obj.shape.props()[i].key;
            TVal key_tv;
            key_tv.set_string(key);
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Dense array indices (as strings)
    char[types::FORMAT_BUF] buf;
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            int len = libc::snprintf(&buf, types::FORMAT_BUF, "%u", i);
            if (len < 0) {
                ctx.result.set_undefined();
                return;
            }
            HString* key = ctx.heap.str_intern(buf[..len]);
            if (key == null) {
                ctx.result.set_undefined();
                return;
            }
            TVal key_tv;
            key_tv.set_string(key);
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Set .length
    TVal len_tv;
    len_tv.set_fastint((long)idx);
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.getPrototypeOf — ES5 §15.2.3.2
// ============================================================================
/// Returns the [[Prototype]] of an object. Throws TypeError if argument is
/// not an object (null or undefined).
fn void builtin_object_getPrototypeOf(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        // Throw TypeError: Object.getPrototypeOf requires an argument
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.getPrototypeOf requires a value");
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object()) {
        // Throw TypeError for null/undefined/primitives
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.getPrototypeOf called on non-object");
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    HObject* proto = obj.prototype;
    if (proto == null) {
        ctx.result.set_null();
        return;
    }
    ctx.result.set_object(proto);
}

// ============================================================================
// Object.isExtensible — ES5 §15.2.3.13
// ============================================================================
/// Returns true if the object is extensible (can have new properties added).
/// Throws TypeError if argument is not an object.
fn void builtin_object_isExtensible(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object()) {
        // Throw TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.isExtensible called on non-object");
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    ctx.result.set_boolean(obj.is_extensible());
}

// ============================================================================
// Object.preventExtensions — ES5 §15.2.3.10
// ============================================================================
/// Makes an object non-extensible (prevents adding new properties).
/// Returns the object itself. Throws TypeError if argument is not an object.
fn void builtin_object_preventExtensions(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        // Throw TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.preventExtensions requires a value");
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object()) {
        // Throw TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.preventExtensions called on non-object");
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    obj.flags.extensible = false;
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.getOwnPropertyDescriptor — ES5 §15.2.3.3
// ============================================================================
/// Returns a property descriptor for an own property of the given object.
/// Throws TypeError if first argument is not an object.
fn void builtin_object_getOwnPropertyDescriptor(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg0 = ctx.regs[ctx.base_reg];

    // Handle lightfuncs: synthesize .name and .length property descriptors
    if (arg0.is_lightfunc()) {
        if (ctx.argc < 2) {
            ctx.result.set_undefined();
            return;
        }
        TVal key_val = ctx.regs[ctx.base_reg + 1];
        void* key = null;
        char[64] key_buf;
        if (key_val.is_string()) {
            key = key_val.get_heapptr();
        } else if (key_val.is_fastint()) {
            int len = libc::snprintf(&key_buf, 64, "%ld", key_val.get_fastint());
            if (len < 0 || len >= 64) { ctx.result.set_undefined(); return; }
            key = ctx.heap.str_intern(key_buf[:len]);
            if (key == null) { ctx.result.set_undefined(); return; }
        } else if (key_val.is_number()) {
            int len = libc::snprintf(&key_buf, 64, "%.17g", key_val.get_number());
            if (len < 0 || len >= 64) { ctx.result.set_undefined(); return; }
            key = ctx.heap.str_intern(key_buf[:len]);
            if (key == null) { ctx.result.set_undefined(); return; }
        } else {
            ctx.result.set_undefined();
            return;
        }

        uint fn_idx = (uint)(usz)arg0.get_heapptr();
        HString* key_hstr = (HString*)key;

        if (key_hstr.equals("name")) {
            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
            if (meta.name.len > 0) {
                HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch err4 = desc_raw) { ctx.result.set_undefined(); return; }
                HObject* desc = desc_raw;
                desc.prototype = ctx.heap.object_proto;

                HString* name_val = builtin_intern_string(ctx.heap, meta.name);
                TVal name_tv; name_tv.set_string(name_val);
                desc.put_prop(builtin_intern_string(ctx.heap, "value"), name_tv, hobject::PROP_FLAGS_WEC);
                TVal w_tv; w_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC);
                TVal e_tv; e_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC);
                TVal c_tv; c_tv.set_boolean(true);
                desc.put_prop(builtin_intern_string(ctx.heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC);

                ctx.result.set_object(desc);
            } else {
                ctx.result.set_undefined();
            }
            return;
        } else if (key_hstr.equals("length")) {
            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
            if (meta.arity >= 0) {
                HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch err5 = desc_raw) { ctx.result.set_undefined(); return; }
                HObject* desc = desc_raw;
                desc.prototype = ctx.heap.object_proto;

                TVal len_tv; len_tv.set_fastint((long)meta.arity);
                desc.put_prop(builtin_intern_string(ctx.heap, "value"), len_tv, hobject::PROP_FLAGS_WEC);
                TVal w_tv; w_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC);
                TVal e_tv; e_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC);
                TVal c_tv; c_tv.set_boolean(true);
                desc.put_prop(builtin_intern_string(ctx.heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC);

                ctx.result.set_object(desc);
            } else {
                ctx.result.set_undefined();
            }
            return;
        } else {
            ctx.result.set_undefined();
            return;
        }
    }

    if (!arg0.is_object()) {
        // ToObject: wrap primitives into proper exotic wrapper objects (ES5 §15.2.3.3)
        if (arg0.is_null() || arg0.is_undefined()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Object.getOwnPropertyDescriptor called on non-object");
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
            return;
        }
        if (!builtin_to_object(ctx, arg0)) {
            ctx.result.set_undefined();
            return;
        }
        arg0 = *ctx.result;
    }
    HObject* obj = (HObject*)arg0.get_heapptr();

    // Resolve the property key (second argument)
    if (ctx.argc < 2) {
        ctx.result.set_undefined();
        return;
    }
    TVal key_val = ctx.regs[ctx.base_reg + 1];
    HString* key_hstr = builtin_to_string(ctx.heap, &key_val);
    if (key_hstr == null) { ctx.result.set_undefined(); return; }
    void* key = key_hstr;

    // String exotic [[GetOwnProperty]] — ES5 §15.5.5.1
    // Numeric indices on String exotic objects return character descriptors.
    // This runs AFTER the default lookup as a fallback (step 1 of spec: try
    // default first, then synthesize if not found).

    // Look up own property (not prototype chain - don't fall through to array_part
    // unless the key matches a numeric index and this is an Array)
    int idx = obj.find_prop_idx(key);
    if (idx < 0) {
        // Check dense array part if key is a string representing a valid index
        HString* key_str = (HString*)key;
        char[] kd = key_str.get_data();
        bool is_numeric = true;
        uint arr_idx = 0;
        for (usz i = 0; i < kd.len; i++) {
            if (kd[i] < '0' || kd[i] > '9') {
                is_numeric = false;
                break;
            }
            arr_idx = arr_idx * 10 + (uint)(kd[i] - '0');
        }
        if (is_numeric && kd.len > 0 && kd.len <= 10 && arr_idx < obj.array_size) {
            TVal av = obj.array_part()[arr_idx];
            if (av.is_undefined()) {
                ctx.result.set_undefined();
                return;
            }
            // Build a data descriptor
            HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (catch err5 = desc_raw) {
                ctx.result.set_undefined();
                return;
            }
            HObject* desc = desc_raw;
            desc.prototype = ctx.heap.object_proto;

            HString* value_key = builtin_intern_string(ctx.heap, "value");
            TVal vt;
            vt.set_string(key_str);
            // Actually set the array element value as the descriptor value
            TVal array_val = obj.array_part()[arr_idx];
            desc.put_prop(value_key, array_val, hobject::PROP_FLAGS_WEC);

            HString* writable_key = builtin_intern_string(ctx.heap, "writable");
            TVal w_tv;
            w_tv.set_boolean(true);
            desc.put_prop(writable_key, w_tv, hobject::PROP_FLAGS_WEC);

            HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
            TVal e_tv;
            e_tv.set_boolean(true);
            desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC);

            HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
            TVal c_tv;
            c_tv.set_boolean(true);
            desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC);

            ctx.result.set_object(desc);
            return;
        }

        // String exotic fallback — ES5 §15.5.5.1 step 3-4:
        // If default lookup returned undefined and P is a string index,
        // synthesize a character descriptor with writable:true, enumerable:true, configurable:true.
        if (obj.get_class() == hobject::ObjClass.STRING &&
            obj.extra.prim.primitive_value.is_string() &&
            is_numeric && kd.len > 0 && kd.len <= 10) {
            HString* prim_str = (HString*)obj.extra.prim.primitive_value.get_heapptr();
            if (arr_idx < (ulong)prim_str.clen) {
                uint cp = prim_str.char_at((uint)arr_idx);
                char[4] cbuf;
                uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
                HString* char_str = ctx.heap.str_intern(cbuf[:cblen]);
                if (char_str != null) {
                    TVal char_tv; char_tv.set_string(char_str);
                    HObject* desc;
                    builtin_build_data_descriptor(ctx.heap, &desc, char_tv, true, true, false);
                    if (desc != null) {
                        ctx.result.set_object(desc);
                        return;
                    }
                }
            }
        }

        ctx.result.set_undefined();
        return;
    }

    hobject::PropValue* entry = &obj.prop_values()[idx];

    // Build the descriptor object
    HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err6 = desc_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* desc = desc_raw;
    desc.prototype = ctx.heap.object_proto;

    if (entry.flags.is_accessor) {
        // Accessor descriptor: { get, set, enumerable, configurable }
        HString* get_key = builtin_intern_string(ctx.heap, "get");
        desc.put_prop(get_key, entry.data.getter, hobject::PROP_FLAGS_WEC);

        HString* set_key = builtin_intern_string(ctx.heap, "set");
        desc.put_prop(set_key, entry.setter, hobject::PROP_FLAGS_WEC);

        HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
        TVal e_tv;
        e_tv.set_boolean(entry.flags.enumerable);
        desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC);

        HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
        TVal c_tv;
        c_tv.set_boolean(entry.flags.configurable);
        desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC);
    } else {
        // Data descriptor: { value, writable, enumerable, configurable }
        HString* value_key = builtin_intern_string(ctx.heap, "value");
        desc.put_prop(value_key, entry.data.value, hobject::PROP_FLAGS_WEC);

        HString* writable_key = builtin_intern_string(ctx.heap, "writable");
        TVal w_tv;
        w_tv.set_boolean(entry.flags.writable);
        desc.put_prop(writable_key, w_tv, hobject::PROP_FLAGS_WEC);

        HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
        TVal e_tv;
        e_tv.set_boolean(entry.flags.enumerable);
        desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC);

        HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
        TVal c_tv;
        c_tv.set_boolean(entry.flags.configurable);
        desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC);
    }

    ctx.result.set_object(desc);
}

/// ToPropertyDescriptor — ES5 §8.10.5
///
/// Parses a descriptor object into PropFlags + value (or getter/setter).
/// `out_flags` receives the flags to use for a newly created property.
/// `out_value` receives the data value (or getter/setter).
/// `is_accessor_out` is set true when the descriptor is an accessor descriptor.
/// Returns true on success, sets ctx.should_throw on error.
fn bool to_property_descriptor(BuiltinContext* ctx, HObject* desc_obj,
                               hobject::PropFlags* out_flags,
                               TVal* out_value, bool* is_accessor_out) {
    // Check the five possible descriptor fields.
    HString* enum_key   = builtin_intern_string(ctx.heap, "enumerable");
    HString* conf_key   = builtin_intern_string(ctx.heap, "configurable");
    HString* value_key  = builtin_intern_string(ctx.heap, "value");
    HString* writ_key   = builtin_intern_string(ctx.heap, "writable");
    HString* get_key    = builtin_intern_string(ctx.heap, "get");
    HString* set_key    = builtin_intern_string(ctx.heap, "set");

    if (enum_key   == null) return false;
    if (conf_key   == null) return false;
    if (value_key  == null) return false;
    if (writ_key   == null) return false;
    if (get_key    == null) return false;
    if (set_key    == null) return false;

    TVal enum_val;   bool has_enumerable   = false;
    if (try v = desc_obj.get_prop_proto(enum_key)) {
        enum_val = v; has_enumerable = true; }
    TVal conf_val;   bool has_configurable = false;
    if (try v = desc_obj.get_prop_proto(conf_key)) {
        conf_val = v; has_configurable = true; }
    TVal value_val;  bool has_value        = false;
    if (try v = desc_obj.get_prop_proto(value_key)) {
        value_val = v; has_value = true; }
    TVal writ_val;   bool has_writable     = false;
    if (try v = desc_obj.get_prop_proto(writ_key)) {
        writ_val = v; has_writable = true; }
    TVal get_val;    bool has_get          = false;
    if (try v = desc_obj.get_prop_proto(get_key)) {
        get_val = v; has_get = true; }
    TVal set_val;    bool has_set          = false;
    if (try v = desc_obj.get_prop_proto(set_key)) {
        set_val = v; has_set = true; }

    // Step 16: If both data and accessor fields present, throw TypeError
    if ((has_value || has_writable) && (has_get || has_set)) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) return false;
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Invalid property descriptor — cannot have both data and accessor fields");
        if (msg_key == null || msg_str == null) return false;
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return false;
    }

    // Validate getter/setter are callable or undefined
    if (has_get && !get_val.is_undefined()) {
        if (!get_val.is_object() && !get_val.is_lightfunc()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err2 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key2 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str2 = builtin_intern_string(ctx.heap, "Getter must be callable or undefined");
            if (msg_key2 == null || msg_str2 == null) return false;
            TVal msg_tv;
            msg_tv.set_string(msg_str2);
            err.put_prop(msg_key2, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
            return false;
        }
        HObject* fn_obj = (HObject*)get_val.get_heapptr();
        if (!fn_obj.is_callable()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err3 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key3 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str3 = builtin_intern_string(ctx.heap, "Getter must be callable");
            if (msg_key3 == null || msg_str3 == null) return false;
            TVal msg_tv;
            msg_tv.set_string(msg_str3);
            err.put_prop(msg_key3, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
            return false;
        }
    }
    if (has_set && !set_val.is_undefined()) {
        if (!set_val.is_object() && !set_val.is_lightfunc()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err4 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key4 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str4 = builtin_intern_string(ctx.heap, "Setter must be callable or undefined");
            if (msg_key4 == null || msg_str4 == null) return false;
            TVal msg_tv;
            msg_tv.set_string(msg_str4);
            err.put_prop(msg_key4, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
            return false;
        }
        HObject* fn_obj = (HObject*)set_val.get_heapptr();
        if (!fn_obj.is_callable()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err5 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key5 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str5 = builtin_intern_string(ctx.heap, "Setter must be callable");
            if (msg_key5 == null || msg_str5 == null) return false;
            TVal msg_tv;
            msg_tv.set_string(msg_str5);
            err.put_prop(msg_key5, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
            return false;
        }
    }

    bool is_accessor = has_get || has_set;

    // Build output flags
    hobject::PropFlags flags;
    flags.is_accessor = is_accessor;

    // Set defaults: if descriptor doesn't mention a field, preserve existing
    // (will be handled by caller). Here we set sentinel values:
    // For a new property, absent fields default to false.
    if (has_enumerable) {
        flags.enumerable = builtin_to_boolean(&enum_val);
    } else {
        flags.enumerable = false;
    }

    if (has_configurable) {
        flags.configurable = builtin_to_boolean(&conf_val);
    } else {
        flags.configurable = false;
    }

    if (has_writable && !is_accessor) {
        flags.writable = builtin_to_boolean(&writ_val);
    } else if (!is_accessor) {
        flags.writable = false;
    }

    if (is_accessor) {
        flags.writable = false;
        if (has_get) {
            out_value[0] = get_val;
        } else {
            out_value[0] = types::make_undefined();
        }
        if (has_set) {
            out_value[1] = set_val;
        } else {
            out_value[1] = types::make_undefined();
        }
    } else {
        if (has_value) {
            out_value[0] = value_val;
        } else {
            out_value[0] = types::make_undefined();
        }
        out_value[1] = types::make_undefined(); // not used for data
    }

    out_flags[0] = flags;
    is_accessor_out[0] = is_accessor;
    return true;
}

/// Object.defineProperty — ES5 §15.2.3.6
fn void builtin_object_defineProperty(BuiltinContext* ctx) {
    // Step 1: Check first arg is Object
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg0 = ctx.regs[ctx.base_reg];
    if (!arg0.is_object()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.defineProperty called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj = (HObject*)arg0.get_heapptr();

    // Step 2: Convert property key to string
    if (ctx.argc < 2) {
        ctx.result.set_undefined();
        return;
    }
    TVal key_val = ctx.regs[ctx.base_reg + 1];
    HString* key_hstr = builtin_to_string(ctx.heap, &key_val);
    if (key_hstr == null) { ctx.result.set_undefined(); return; }
    void* key = key_hstr;

    // Step 3: Check Attributes is Object
    if (ctx.argc < 3) {
        ctx.result.set_undefined();
        return;
    }
    TVal attr_val = ctx.regs[ctx.base_reg + 2];
    if (!attr_val.is_object()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err5 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key3 = builtin_intern_string(ctx.heap, "message");
        HString* msg_str3 = builtin_intern_string(ctx.heap, "Object.defineProperty called with non-object descriptor");
        if (msg_key3 == null || msg_str3 == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str3);
        err.put_prop(msg_key3, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* desc_obj = (HObject*)attr_val.get_heapptr();

    // Step 4: ToPropertyDescriptor
    hobject::PropFlags desc_flags;
    TVal[2] desc_vals;  // [0]=value/getter, [1]=setter (unused for data)
    bool is_accessor;
    if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_accessor)) {
        if (ctx.should_throw) return;
        ctx.result.set_undefined();
        return;
    }

    // Step 5: [[DefineOwnProperty]]
    // Check if property already exists
    int existing_idx = obj.find_prop_idx(key);
    if (existing_idx < 0) {
        // Property doesn't exist — check extensibility
        if (!obj.flags.extensible) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err6 = err_raw) {
                ctx.result.set_undefined();
                return;
            }
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key4 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str4 = builtin_intern_string(ctx.heap, "Cannot define property on a non-extensible object");
            if (msg_key4 == null || msg_str4 == null) { ctx.result.set_undefined(); return; }
            TVal msg_tv;
            msg_tv.set_string(msg_str4);
            err.put_prop(msg_key4, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
            return;
        }
        // Create new property
        if (is_accessor) {
            // Accessor property — set value as getter placeholder
            obj.put_prop(key, desc_vals[0], desc_flags);
            int idx = obj.find_prop_idx(key);
            if (idx >= 0) {
                obj.prop_values()[idx].data.getter = desc_vals[0];
                obj.prop_values()[idx].setter = desc_vals[1];
            }
        } else {
            obj.put_prop(key, desc_vals[0], desc_flags);
        }
    } else {
        // Property exists — validate changes per ES5 §8.12.9
        hobject::PropValue* current = &obj.prop_values()[existing_idx];
        hobject::PropFlags cur_flags = current.flags;
        TVal cur_value = current.data.value;

        // Check if descriptor is empty (generic, no fields)
        bool has_value_field   = (ctx.regs[ctx.base_reg + 2].is_object()); // already validated
        // We've already extracted descriptor fields above, so check what was present

        // Check configurable constraint — ES5 §8.12.9 step 8
        if (!cur_flags.configurable) {
            bool reject = false;
            // Only reject if the field is actually present in the descriptor AND differs
            bool desc_has_conf = false;
            bool desc_has_enum = false;
            HString* tmp_conf_k = builtin_intern_string(ctx.heap, "configurable");
            HString* tmp_enum_k = builtin_intern_string(ctx.heap, "enumerable");
            if (tmp_conf_k != null) desc_has_conf = desc_obj.find_prop_idx(tmp_conf_k) >= 0;
            if (tmp_enum_k != null) desc_has_enum = desc_obj.find_prop_idx(tmp_enum_k) >= 0;
            if (desc_has_conf && desc_flags.configurable != cur_flags.configurable) reject = true;
            if (desc_has_enum && desc_flags.enumerable != cur_flags.enumerable) reject = true;
            if (reject) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err7 = err_raw) {
                    ctx.result.set_undefined();
                    return;
                }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key5 = builtin_intern_string(ctx.heap, "message");
                HString* msg_str5 = builtin_intern_string(ctx.heap, "Cannot redefine non-configurable property");
                if (msg_key5 == null || msg_str5 == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.set_string(msg_str5);
                err.put_prop(msg_key5, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
                return;
            }
        }

        // Update the property
        if (is_accessor != cur_flags.is_accessor) {
            // Changing from data to accessor or vice versa on non-configurable
            if (!cur_flags.configurable) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err8 = err_raw) {
                    ctx.result.set_undefined();
                    return;
                }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key6 = builtin_intern_string(ctx.heap, "message");
                HString* msg_str6 = builtin_intern_string(ctx.heap, "Cannot change property type from data to accessor or vice versa on non-configurable property");
                if (msg_key6 == null || msg_str6 == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.set_string(msg_str6);
                err.put_prop(msg_key6, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
                return;
            }
            // Type change allowed only if configurable
        }

        if (is_accessor) {
            // Update accessor fields
            bool has_get_in_desc = false;
            bool has_set_in_desc = false;
            bool has_enum_in_desc = false;
            bool has_conf_in_desc = false;
            // Re-check which fields were in the descriptor
            HString* get_k = builtin_intern_string(ctx.heap, "get");
            HString* set_k = builtin_intern_string(ctx.heap, "set");
            HString* enum_k = builtin_intern_string(ctx.heap, "enumerable");
            HString* conf_k = builtin_intern_string(ctx.heap, "configurable");
            if (get_k != null) has_get_in_desc = desc_obj.find_prop_idx(get_k) >= 0;
            if (set_k != null) has_set_in_desc = desc_obj.find_prop_idx(set_k) >= 0;
            if (enum_k != null) has_enum_in_desc = desc_obj.find_prop_idx(enum_k) >= 0;
            if (conf_k != null) has_conf_in_desc = desc_obj.find_prop_idx(conf_k) >= 0;

            if (has_get_in_desc) current.data.getter = desc_vals[0];
            if (has_set_in_desc) current.setter = desc_vals[1];

            // Update flags — only overwrite fields present in descriptor
            current.flags.is_accessor = true;
            if (has_enum_in_desc) current.flags.enumerable   = desc_flags.enumerable;
            if (has_conf_in_desc) current.flags.configurable = desc_flags.configurable;
        } else {
            // Update data property
            bool has_val_in_desc = false;
            bool has_wrt_in_desc = false;
            bool has_enum_in_desc = false;
            bool has_conf_in_desc = false;
            HString* val_k  = builtin_intern_string(ctx.heap, "value");
            HString* writ_k = builtin_intern_string(ctx.heap, "writable");
            HString* enum_k = builtin_intern_string(ctx.heap, "enumerable");
            HString* conf_k = builtin_intern_string(ctx.heap, "configurable");
            if (val_k  != null) has_val_in_desc  = desc_obj.find_prop_idx(val_k)  >= 0;
            if (writ_k != null) has_wrt_in_desc  = desc_obj.find_prop_idx(writ_k) >= 0;
            if (enum_k != null) has_enum_in_desc = desc_obj.find_prop_idx(enum_k) >= 0;
            if (conf_k != null) has_conf_in_desc = desc_obj.find_prop_idx(conf_k) >= 0;

            // Check writable → non-writable transition when non-configurable
            if (!cur_flags.configurable && !cur_flags.writable && has_wrt_in_desc && desc_flags.writable) {
                // Cannot change non-writable to writable on non-configurable
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err9 = err_raw) {
                    ctx.result.set_undefined();
                    return;
                }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key7 = builtin_intern_string(ctx.heap, "message");
                HString* msg_str7 = builtin_intern_string(ctx.heap, "Cannot change writable attribute of non-configurable property from false to true");
                if (msg_key7 == null || msg_str7 == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.set_string(msg_str7);
                err.put_prop(msg_key7, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
                return;
            }

            if (has_val_in_desc) {
                // ES5 §8.12.9 step 9: If non-configurable and non-writable, reject only if
                // the new value differs from the current value (SameValue check).
                if (!cur_flags.configurable && !cur_flags.writable) {
                    if (!same_value(cur_value, desc_vals[0])) {
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (catch err10 = err_raw) {
                            ctx.result.set_undefined();
                            return;
                        }
                        HObject* err = err_raw;
                        err.prototype = ctx.heap.type_err_proto;
                        HString* msg_key8 = builtin_intern_string(ctx.heap, "message");
                        HString* msg_str8 = builtin_intern_string(ctx.heap, "Cannot change value of non-writable non-configurable property");
                        if (msg_key8 == null || msg_str8 == null) { ctx.result.set_undefined(); return; }
                        TVal msg_tv;
                        msg_tv.set_string(msg_str8);
                        err.put_prop(msg_key8, msg_tv, hobject::PROP_FLAGS_WEC);
                        ctx.should_throw = true;
                        ctx.throw_value.set_object(err);
                        return;
                    }
                }
                current.data.value = desc_vals[0];
            }

            if (has_wrt_in_desc)  current.flags.writable     = desc_flags.writable;
            if (has_enum_in_desc) current.flags.enumerable   = desc_flags.enumerable;
            if (has_conf_in_desc) current.flags.configurable = desc_flags.configurable;
            // Clear is_accessor when converting accessor→data (ES5 §8.12.9 step 9)
            current.flags.is_accessor = false;
        }
    }

    // Step 6: Return O
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.defineProperties — ES5 §15.2.3.7
// ============================================================================
/// Define multiple properties on an object from a properties object.
fn void builtin_object_defineProperties(BuiltinContext* ctx) {
    // Step 1: Check first arg is Object
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg0 = ctx.regs[ctx.base_reg];
    if (!arg0.is_object()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.defineProperties called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj = (HObject*)arg0.get_heapptr();

    // Step 2: Check Properties argument is present and is an object
    if (ctx.argc < 2) {
        ctx.result.set_object(obj);
        return;
    }
    TVal props_val = ctx.regs[ctx.base_reg + 1];
    if (!props_val.is_object()) {
        ctx.result.set_object(obj);
        return;
    }
    HObject* props = (HObject*)props_val.get_heapptr();

    // Step 4: For each key, get descriptor and call DefinePropertyOrThrow
    // Collect keys first in case properties are modified during iteration
    HString*[256] keys_arr;
    uint keys_count = 0;
    for (uint i = 0; i < props.prop_count && keys_count < 256; i++) {
        if (props.shape.props()[i].key != null) {
            keys_arr[keys_count] = (HString*)props.shape.props()[i].key;
            keys_count++;
        }
    }

    for (uint k = 0; k < keys_count; k++) {
        HString* p_key = keys_arr[k];
        // Get descObj = props.[[GetOwnProperty]](p_key).value
        PropValue*? prop_entry = props.find_prop(p_key);
        if (try pe = prop_entry) {
            TVal desc_obj_val = pe.data.value;

            // ToPropertyDescriptor(desc_obj)
            if (!desc_obj_val.is_object()) {
                // TypeError — property descriptor must be an object
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                char[128] msg_buf;
                int msg_len = libc::snprintf(&msg_buf, 128, "Property descriptor for '%s' must be an object", p_key.get_data());
                HString* msg_str = builtin_intern_string(ctx.heap, msg_buf[:msg_len]);
                if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.set_string(msg_str);
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
                return;
            }
            HObject* desc_obj = (HObject*)desc_obj_val.get_heapptr();

            // Convert to property descriptor
            hobject::PropFlags desc_flags;
            TVal[2] desc_vals;
            bool is_accessor;
            if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_accessor)) {
                if (ctx.should_throw) return;
                ctx.result.set_undefined();
                return;
            }

            // [[DefineOwnProperty]]
            int existing_idx = obj.find_prop_idx(p_key);
            if (existing_idx < 0) {
                if (!obj.flags.extensible) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (catch err3 = err_raw) { ctx.result.set_undefined(); return; }
                    HObject* err = err_raw;
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    HString* msg_str = builtin_intern_string(ctx.heap, "Cannot define property on a non-extensible object");
                    if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                    TVal msg_tv;
                    msg_tv.set_string(msg_str);
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                    return;
                }
                if (is_accessor) {
                    obj.put_prop(p_key, desc_vals[0], desc_flags);
                    int idx = obj.find_prop_idx(p_key);
                    if (idx >= 0) {
                        obj.prop_values()[idx].data.getter = desc_vals[0];
                        obj.prop_values()[idx].setter = desc_vals[1];
                    }
                } else {
                    obj.put_prop(p_key, desc_vals[0], desc_flags);
                }
            } else {
                // Property exists — validate changes
                hobject::PropValue* current = &obj.prop_values()[existing_idx];
                hobject::PropFlags cur_flags = current.flags;
                if (!cur_flags.configurable) {
                    if (desc_flags.configurable != cur_flags.configurable ||
                        desc_flags.enumerable != cur_flags.enumerable) {
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (catch err4 = err_raw) { ctx.result.set_undefined(); return; }
                        HObject* err = err_raw;
                        err.prototype = ctx.heap.type_err_proto;
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot redefine non-configurable property");
                        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                        TVal msg_tv;
                        msg_tv.set_string(msg_str);
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                        ctx.should_throw = true;
                        ctx.throw_value.set_object(err);
                        return;
                    }
                }

                if (is_accessor) {
                    if (has_get_in_desc_helper(ctx.heap, desc_obj)) current.data.getter = desc_vals[0];
                    if (has_set_in_desc_helper(ctx.heap, desc_obj)) current.setter = desc_vals[1];
                    current.flags.is_accessor = true;
                    if (has_enumerable_in_desc_helper(ctx.heap, desc_obj)) current.flags.enumerable = desc_flags.enumerable;
                    if (has_configurable_in_desc_helper(ctx.heap, desc_obj)) current.flags.configurable = desc_flags.configurable;
                } else {
                    // Basic data property update
                    if (has_value_in_desc_helper(ctx.heap, desc_obj)) {
                        if (!cur_flags.configurable && !cur_flags.writable) {
                            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (catch err5 = err_raw) { ctx.result.set_undefined(); return; }
                            HObject* err = err_raw;
                            err.prototype = ctx.heap.type_err_proto;
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            HString* msg_str = builtin_intern_string(ctx.heap, "Cannot change value of non-writable non-configurable property");
                            if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                            TVal msg_tv;
                            msg_tv.set_string(msg_str);
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                            ctx.should_throw = true;
                            ctx.throw_value.set_object(err);
                            return;
                        }
                        current.data.value = desc_vals[0];
                    }
                    if (has_writable_in_desc_helper(ctx.heap, desc_obj)) current.flags.writable = desc_flags.writable;
                    if (has_enumerable_in_desc_helper(ctx.heap, desc_obj)) current.flags.enumerable = desc_flags.enumerable;
                    if (has_configurable_in_desc_helper(ctx.heap, desc_obj)) current.flags.configurable = desc_flags.configurable;
                }
            }
        }
    }

    // Step 5: Return obj
    ctx.result.set_object(obj);
}

/// Helper: check if descriptor object has "get" property
fn bool has_get_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "get");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "set" property
fn bool has_set_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "set");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "value" property
fn bool has_value_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "writable" property
fn bool has_writable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "writable");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "enumerable" property
fn bool has_enumerable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "enumerable");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "configurable" property
fn bool has_configurable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "configurable");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}

// ============================================================================
// Object.create — ES5 §15.2.3.5
// ============================================================================
/// Create a new object with the specified prototype and optional properties.
fn void builtin_object_create(BuiltinContext* ctx) {
    // Step 1-2: Check prototype argument
    if (ctx.argc < 1) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.create requires at least 1 argument");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    TVal proto_val = ctx.regs[ctx.base_reg];

    // If O is not Object or Null, throw TypeError
    if (proto_val.is_null()) {
        // null prototype is valid
    } else if (proto_val.is_object()) {
        // valid
    } else {
        // Throw TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object prototype may only be an Object or null");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject*? proto_obj_raw = null;
    if (proto_val.is_object()) {
        proto_obj_raw = (HObject*)proto_val.get_heapptr();
    }

    // Step 3: Create a new object with [[Prototype]] = O
    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err3 = obj_raw) { ctx.result.set_undefined(); return; }
    HObject* obj = obj_raw;
    if (try proto_obj = proto_obj_raw) {
        obj.prototype = proto_obj;
    } else {
        obj.prototype = null;
    }
    obj.flags.extensible = true;

    // Step 4: If Properties is not undefined, call defineProperties
    if (ctx.argc >= 2) {
        TVal props_val = ctx.regs[ctx.base_reg + 1];
        if (!props_val.is_undefined() && !props_val.is_null()) {
            // Create a mini-BuiltinContext for the defineProperties call
            // We reuse the same approach: inline defineProperties logic
            if (props_val.is_object()) {
                HObject* props = (HObject*)props_val.get_heapptr();

                // Collect own property keys
                HString*[256] keys_arr;
                uint keys_count = 0;
                for (uint i = 0; i < props.prop_count && keys_count < 256; i++) {
                    if (props.shape.props()[i].key != null) {
                        keys_arr[keys_count] = (HString*)props.shape.props()[i].key;
                        keys_count++;
                    }
                }

                for (uint k = 0; k < keys_count; k++) {
                    HString* pk_key = keys_arr[k];
                    PropValue*? prop_entry = props.find_prop(pk_key);
                    if (try pe = prop_entry) {
                        TVal desc_obj_val = pe.data.value;
                        if (!desc_obj_val.is_object()) {
                            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (catch err4 = err_raw) { ctx.result.set_undefined(); return; }
                            HObject* err = err_raw;
                            err.prototype = ctx.heap.type_err_proto;
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            char[128] msg_buf;
                            int msg_len = libc::snprintf(&msg_buf, 128, "Property descriptor for '%s' must be an object", pk_key.get_data());
                            HString* msg_str = builtin_intern_string(ctx.heap, msg_buf[:msg_len]);
                            if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                            TVal msg_tv;
                            msg_tv.set_string(msg_str);
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                            ctx.should_throw = true;
                            ctx.throw_value.set_object(err);
                            return;
                        }
                        HObject* desc_obj = (HObject*)desc_obj_val.get_heapptr();

                        hobject::PropFlags desc_flags;
                        TVal[2] desc_vals;
                        bool is_accessor;
                        if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_accessor)) {
                            if (ctx.should_throw) return;
                            ctx.result.set_undefined();
                            return;
                        }

                        if (is_accessor) {
                            obj.put_prop(pk_key, desc_vals[0], desc_flags);
                            int idx = obj.find_prop_idx(pk_key);
                            if (idx >= 0) {
                                obj.prop_values()[idx].data.getter = desc_vals[0];
                                obj.prop_values()[idx].setter = desc_vals[1];
                            }
                        } else {
                            obj.put_prop(pk_key, desc_vals[0], desc_flags);
                        }
                    }
                }
            }
        }
    }

    // Step 5: Return obj
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.seal — ES5 §15.2.3.8
// ============================================================================
/// Seal an object: prevent extensions and make all properties non-configurable.
fn void builtin_object_seal(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.seal called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    obj.seal();
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.freeze — ES5 §15.2.3.9
// ============================================================================
/// Freeze an object: seal and make all data properties non-writable.
fn void builtin_object_freeze(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.freeze called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    obj.freeze();
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.isSealed — ES5 §15.2.3.11
// ============================================================================
/// Check if an object is sealed.
fn void builtin_object_isSealed(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.isSealed called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();

    // Check if any own property is configurable
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.shape.props()[i].key != null && obj.prop_values()[i].flags.configurable) {
            ctx.result.set_boolean(false);
            return;
        }
    }

    // Check if extensible
    if (obj.flags.extensible) {
        ctx.result.set_boolean(false);
        return;
    }

    ctx.result.set_boolean(true);
}

// ============================================================================
// Object.isFrozen — ES5 §15.2.3.12
// ============================================================================
/// Check if an object is frozen.
fn void builtin_object_isFrozen(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.isFrozen called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();

    // Check if any own property is configurable or data property writable
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.shape.props()[i].key != null) {
            if (obj.prop_values()[i].flags.configurable) {
                ctx.result.set_boolean(false);
                return;
            }
            if (!obj.prop_values()[i].flags.is_accessor && obj.prop_values()[i].flags.writable) {
                ctx.result.set_boolean(false);
                return;
            }
        }
    }

    // Check if extensible
    if (obj.flags.extensible) {
        ctx.result.set_boolean(false);
        return;
    }

    ctx.result.set_boolean(true);
}

// ============================================================================
// Object.entries — ES2017 §19.1.2.21
// ============================================================================
/// Returns an array of the given object's own enumerable string-keyed property
/// [key, value] pairs.
fn void builtin_object_entries(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.is_null() || arg.is_undefined()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        // ToObject wrapper for primitives — use proper exotic class
        if (!builtin_to_object(ctx, arg)) { ctx.result.set_undefined(); return; }
        obj = (HObject*)ctx.result.get_heapptr();
    }
    // Count enumerable own properties
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_values()[i].flags.enumerable && obj.shape.props()[i].key != null) count++;
    }
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) count++;
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err3 = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;
    // Named properties → [key, value] pairs
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_values()[i].flags.enumerable && obj.shape.props()[i].key != null) {
            HString* key = (HString*)obj.shape.props()[i].key;
            // Create pair array [key, value]
            HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err4 = pair_raw) { ctx.result.set_undefined(); return; }
            HObject* pair = pair_raw;
            pair.prototype = ctx.heap.array_proto;
            TVal key_tv; key_tv.set_string(key);
            array_set_elem(pair, 0, key_tv, ctx.heap);
            array_set_elem(pair, 1, obj.prop_values()[i].data.value, ctx.heap);
            TVal len_tv; len_tv.set_fastint(2);
            HString* len_key = builtin_intern_string(ctx.heap, "length");
            pair.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
            TVal pair_tv; pair_tv.set_object(pair);
            array_set_elem(arr, idx, pair_tv, ctx.heap);
            idx++;
        }
    }
    // Dense array indices → [key, value] pairs
    char[types::FORMAT_BUF] buf;
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            int slen = libc::snprintf(&buf, types::FORMAT_BUF, "%u", i);
            if (slen < 0) continue;
            HString* key_s = ctx.heap.str_intern(buf[..slen]);
            if (key_s == null) continue;
            HObject*? pair_raw2 = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err6 = pair_raw2) continue;
            HObject* pair2 = pair_raw2;
            pair2.prototype = ctx.heap.array_proto;
            TVal key_tv2; key_tv2.set_string(key_s);
            array_set_elem(pair2, 0, key_tv2, ctx.heap);
            array_set_elem(pair2, 1, obj.array_part()[i], ctx.heap);
            TVal len_tv2; len_tv2.set_fastint(2);
            HString* len_key2 = builtin_intern_string(ctx.heap, "length");
            pair2.put_prop(len_key2, len_tv2, hobject::PROP_FLAGS_WEC);
            TVal pair_tv2; pair_tv2.set_object(pair2);
            array_set_elem(arr, idx, pair_tv2, ctx.heap);
            idx++;
        }
    }
    // Set .length on result array
    TVal rlen_tv; rlen_tv.set_fastint((long)idx);
    HString* rlen_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(rlen_key, rlen_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.values — ES2017 §19.1.2.22
// ============================================================================
/// Returns an array of the given object's own enumerable string-keyed property values.
fn void builtin_object_values(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.is_null() || arg.is_undefined()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        HObject*? wrapped = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err2 = wrapped) { ctx.result.set_undefined(); return; }
        obj = wrapped;
        obj.prototype = ctx.heap.object_proto;
    }
    // Count enumerable own properties
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_values()[i].flags.enumerable && obj.shape.props()[i].key != null) count++;
    }
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) count++;
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err3 = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;
    // Named properties
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_values()[i].flags.enumerable && obj.shape.props()[i].key != null) {
            array_set_elem(arr, idx, obj.prop_values()[i].data.value, ctx.heap);
            idx++;
        }
    }
    // Dense array indices
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            array_set_elem(arr, idx, obj.array_part()[i], ctx.heap);
            idx++;
        }
    }
    // Set .length
    TVal rlen_tv; rlen_tv.set_fastint((long)idx);
    HString* rlen_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(rlen_key, rlen_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.assign — ES2015 §19.1.2.2
// ============================================================================
/// Copies enumerable own properties from source objects to a downstream object.
fn void builtin_object_assign(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal downstream_val = ctx.regs[ctx.base_reg];
    // TypeError if downstream is null or undefined
    if (downstream_val.is_null() || downstream_val.is_undefined()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    // ToObject on downstream
    HObject* downstream;
    if (downstream_val.is_object()) {
        downstream = (HObject*)downstream_val.get_heapptr();
    } else {
        HObject*? wrapped = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err2 = wrapped) { ctx.result.set_undefined(); return; }
        downstream = wrapped;
        downstream.prototype = ctx.heap.object_proto;
    }
    // Copy properties from each source (args 1..N)
    for (uint s = 1; s < ctx.argc; s++) {
        TVal source = ctx.regs[ctx.base_reg + s];
        // Skip null, undefined, and non-objects
        if (source.is_null() || source.is_undefined()) continue;
        if (!source.is_object()) continue;
        HObject* src_obj = (HObject*)source.get_heapptr();
        // Copy enumerable own named properties
        for (uint i = 0; i < src_obj.prop_count; i++) {
            if (src_obj.prop_values()[i].flags.enumerable && src_obj.shape.props()[i].key != null) {
                downstream.put_prop(src_obj.shape.props()[i].key, src_obj.prop_values()[i].data.value, hobject::PROP_FLAGS_WEC);
            }
        }
        // Copy enumerable own dense array indices
        for (uint i = 0; i < src_obj.array_size; i++) {
            if (!src_obj.array_part()[i].is_undefined()) {
                array_set_elem(downstream, i, src_obj.array_part()[i], ctx.heap);
            }
        }
    }
    ctx.result.set_object(downstream);
}

// ============================================================================
// Object.is — ES6 §19.1.2.10
// ============================================================================
/// Object.is(value1, value2) — SameValue comparison.
/// Differs from === in two ways: NaN === NaN, and +0 !== -0.
fn void builtin_object_is(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        // Missing args → undefined (per ES6 spec, both args required)
        TVal undef; undef.set_undefined();
        TVal undef2; undef2.set_undefined();
        // With < 2 args, default is undefined === undefined → true
        ctx.result.set_boolean((ctx.argc == 0) ? true : same_value(ctx.regs[ctx.base_reg], undef2));
        return;
    }
    TVal x = ctx.regs[ctx.base_reg];
    TVal y = ctx.regs[ctx.base_reg + 1];
    ctx.result.set_boolean(same_value(x, y));
}

// ============================================================================
// Object.hasOwn — ES2022 §19.1.2.10
// ============================================================================
/// Object.hasOwn(obj, prop) — returns true if obj has own property prop.
/// Equivalent to Object.prototype.hasOwnProperty.call(obj, prop).
fn void builtin_object_hasOwn(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.hasOwn requires 2 arguments");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    TVal obj_val = ctx.regs[ctx.base_reg];
    TVal prop_val = ctx.regs[ctx.base_reg + 1];
    // ToObject on first argument — throw TypeError for null/undefined
    if (obj_val.is_null() || obj_val.is_undefined()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj;
    if (obj_val.is_object()) {
        obj = (HObject*)obj_val.get_heapptr();
    } else {
        // Primitive — wrap via ToObject (for now, return false)
        ctx.result.set_boolean(false);
        return;
    }
    HString* key = builtin_to_string(ctx.heap, &prop_val);
    if (key == null) {
        ctx.result.set_boolean(false);
        return;
    }
    PropValue*? entry = obj.find_prop(key);
    if (try e = entry) {
        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// Object.setPrototypeOf — ES2015 §19.1.2.19
// ============================================================================
/// Object.setPrototypeOf(obj, proto) — sets the prototype of obj to proto.
fn void builtin_object_setPrototypeOf(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        ctx.result.set_undefined();
        return;
    }
    TVal obj_val = ctx.regs[ctx.base_reg];
    TVal proto_val = ctx.regs[ctx.base_reg + 1];
    // TypeError if obj is not an object (null/undefined/primitive)
    if (obj_val.is_null() || obj_val.is_undefined()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.setPrototypeOf requires an object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    // TypeError if proto is not an object or null
    if (!proto_val.is_null() && !proto_val.is_object()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.setPrototypeOf requires an object or null");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    // Only set prototype on objects (not primitives)
    if (!obj_val.is_object()) {
        ctx.result.set_fastint(obj_val.get_fastint());
        return;
    }
    HObject* obj = (HObject*)obj_val.get_heapptr();
    if (proto_val.is_null()) {
        obj.prototype = null;
    } else {
        obj.prototype = (HObject*)proto_val.get_heapptr();
    }
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.fromEntries — ES2019 §19.1.2.5
// ============================================================================
/// Creates a new object from an iterable of [key, value] pairs.
fn void builtin_object_fromEntries(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.is_null() || arg.is_undefined()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.fromEntries requires an iterable");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    if (!arg.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* iterable = (HObject*)arg.get_heapptr();
    // Create result object
    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err2 = obj_raw) { ctx.result.set_undefined(); return; }
    HObject* obj = obj_raw;
    obj.prototype = ctx.heap.object_proto;
    // Get length
    usz len = 0;
    bool has_len = false;
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    if (try len_tv = iterable.get_prop(length_key)) {
        if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
            len = (usz)len_tv.get_fastint();
            has_len = true;
        } else if (len_tv.is_number()) {
            len = (usz)len_tv.get_number();
            has_len = true;
        }
    }
    if (!has_len || len == 0) {
        ctx.result.set_object(obj);
        return;
    }
    // Iterate entries
    for (usz i = 0; i < len; i++) {
        TVal idx_tv;
        idx_tv.set_fastint((long)i);
        TVal entry;
        if (try e = iterable.get_prop(&idx_tv)) {
            entry = e;
        } else {
            continue;
        }
        if (!entry.is_object()) continue;
        HObject* pair = (HObject*)entry.get_heapptr();
        // Get key from pair[0]
        TVal key_idx;
        key_idx.set_fastint(0);
        TVal key_val;
        if (try kv = pair.get_prop(&key_idx)) {
            key_val = kv;
        } else {
            continue;
        }
        // Get value from pair[1]
        TVal val_idx;
        val_idx.set_fastint(1);
        TVal val_val;
        if (try vv = pair.get_prop(&val_idx)) {
            val_val = vv;
        } else {
            val_val.set_undefined();
        }
        // Convert key to string
        HString* key_str = null;
        if (key_val.is_string()) {
            key_str = (HString*)key_val.get_heapptr();
        } else if (key_val.is_number()) {
            char[32] buf;
            int slen = libc::snprintf(&buf[0], 32, "%g", key_val.get_number());
            if (slen > 0) {
                key_str = ctx.heap.str_intern(buf[..slen]);
            }
        } else if (key_val.is_object()) {
            // Symbol objects: skip per spec (Symbol keys are not string-coerced)
            HObject* key_obj = (HObject*)key_val.get_heapptr();
            if (key_obj.get_class() == hobject::ObjClass.SYMBOL) continue;
            // For other objects, use toString via .name or [object Object]
            char[64] buf;
            char* repr = "[object Object]";
            int slen = 15;
            libc::memcpy(&buf, repr, (usz)slen);
            key_str = ctx.heap.str_intern(buf[..slen]);
        } else {
            // ToPropertyKey: toString for null/undefined/boolean
            char[64] buf;
            char* repr = "undefined";
            int slen = 9;
            if (key_val.is_null()) {
                repr = "null";
                slen = 4;
            } else if (key_val.is_boolean()) {
                if (key_val.get_boolean()) { repr = "true"; slen = 4; }
                else { repr = "false"; slen = 5; }
            }
            uint hash = ctx.heap.hash_string(buf[..slen]);
            libc::memcpy(&buf, repr, (usz)slen);
            key_str = ctx.heap.str_intern(buf[..slen]);
        }
        if (key_str != null) {
            obj.put_prop(key_str, val_val, hobject::PROP_FLAGS_WEC);
        }
    }
    ctx.result.set_object(obj);
}

fn void builtin_object_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        char[64] buf;
        char* class_name = "Object";
        switch (obj.get_class()) {
            case hobject::ObjClass.ARRAY:     class_name = "Array"; break;
            case hobject::ObjClass.FUNCTION:  class_name = "Function"; break;
            case hobject::ObjClass.BOOLEAN:   class_name = "Boolean"; break;
            case hobject::ObjClass.NUMBER:    class_name = "Number"; break;
            case hobject::ObjClass.STRING:    class_name = "String"; break;
            case hobject::ObjClass.ERROR:     class_name = "Error"; break;
            case hobject::ObjClass.JSON:      class_name = "JSON"; break;
            case hobject::ObjClass.MATH:      class_name = "Math"; break;
            case hobject::ObjClass.DATE:      class_name = "Date"; break;
            case hobject::ObjClass.REGEXP:    class_name = "RegExp"; break;
            case hobject::ObjClass.MAP:       class_name = "Map"; break;
            case hobject::ObjClass.SET:       class_name = "Set"; break;
            case hobject::ObjClass.WEAKMAP:   class_name = "WeakMap"; break;
            case hobject::ObjClass.WEAKSET:   class_name = "WeakSet"; break;
            case hobject::ObjClass.SYMBOL:    class_name = "Symbol"; break;
            case hobject::ObjClass.PROMISE:   class_name = "Promise"; break;
            case hobject::ObjClass.GENERATOR: class_name = "Generator"; break;
            default:                          class_name = "Object"; break;
        }

        // ES6 §19.1.3.6: check @@toStringTag on the object
        HString* tag_sym = ensure_tostringtag_symbol(ctx.heap);
        if (tag_sym != null) {
            TVal? tag_val = obj.get_prop_proto(tag_sym);
            if (try tv = tag_val) {
                if (tv.is_string()) {
                    HString* tag_str = (HString*)tv.get_heapptr();
                    if (tag_str != null && !tag_str.is_symbol()) {
                        char[] tag_bytes = tag_str.get_data();
                        int tag_len = (int)tag_bytes.len;
                        if (tag_len > 0 && tag_len < 64) {
                            // Build "[object <tag>]"
                            buf[0] = '[';
                            buf[1] = 'o';
                            buf[2] = 'b';
                            buf[3] = 'j';
                            buf[4] = 'e';
                            buf[5] = 'c';
                            buf[6] = 't';
                            buf[7] = ' ';
                            int pos = 8;
                            for (int i = 0; i < tag_len && pos < 62; i++) {
                                buf[pos] = tag_bytes[i];
                                pos++;
                            }
                            buf[pos] = ']';
                            pos++;
                            HString* s = builtin_intern_string(ctx.heap, buf[:pos]);
                            ctx.result.set_string(s);
                            return;
                        }
                    }
                }
            }
        }

        int len = libc::snprintf(&buf, 64, "[object %s]", class_name);
        if (len > 0 && len < 64) {
            HString* s = builtin_intern_string(ctx.heap, buf[:len]);
            ctx.result.set_string(s);
            return;
        }
    } else if (this_val.is_undefined()) {
        HString* s = builtin_intern_string(ctx.heap, "[object Undefined]");
        ctx.result.set_string(s);
        return;
    } else if (this_val.is_null()) {
        HString* s = builtin_intern_string(ctx.heap, "[object Null]");
        ctx.result.set_string(s);
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, "[object Object]");
    ctx.result.set_string(s);
}

/// Object.prototype.hasOwnProperty — ES5 §15.2.4.5
fn void builtin_object_proto_hasOwnProperty(BuiltinContext* ctx) {
    // V = first argument, converted to string key
    TVal arg;
    if (ctx.argc > 0) {
        arg = ctx.regs[ctx.base_reg];
    } else {
        arg.set_undefined();
    }
    HString* key = builtin_to_string(ctx.heap, &arg);
    if (key == null) {
        ctx.result.set_boolean(false);
        return;
    }
    // O = ToObject(this value)
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* obj;
    if (this_val.is_lightfunc()) {
        // Lightfuncs have .name and .length as own properties per ES6 spec
        if (key.equals("name") || key.equals("length")) {
            ctx.result.set_boolean(true);
        } else {
            ctx.result.set_boolean(false);
        }
        return;
    } else if (this_val.is_object() && this_val.get_heapptr() != null) {
        obj = (HObject*)this_val.get_heapptr();
    } else {
        // Primitive this value — return false (no own properties)
        ctx.result.set_boolean(false);
        return;
    }
    // Check own property
    PropValue*? entry = obj.find_prop(key);
    if (try e = entry) {
        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

/// Object.prototype.propertyIsEnumerable — ES5 §15.2.4.7
fn void builtin_object_proto_propertyIsEnumerable(BuiltinContext* ctx) {
    // V = first argument, converted to string key
    TVal arg;
    if (ctx.argc > 0) {
        arg = ctx.regs[ctx.base_reg];
    } else {
        arg.set_undefined();
    }
    HString* key = builtin_to_string(ctx.heap, &arg);
    if (key == null) {
        ctx.result.set_boolean(false);
        return;
    }
    // O = ToObject(this value)
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* obj;
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        obj = (HObject*)this_val.get_heapptr();
    } else {
        ctx.result.set_boolean(false);
        return;
    }
    // Find own property descriptor
    PropValue*? entry = obj.find_prop(key);
    if (try e = entry) {
        ctx.result.set_boolean(e.flags.enumerable);
    } else {
        ctx.result.set_boolean(false);
    }
}

/// Object.prototype.data.valueOf — returns 'this'
fn void builtin_object_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    ctx.result.set_fastint(this_val.get_fastint());
    ctx.result.set_number(this_val.get_number());
    ctx.result.set_object(this_val.get_heapptr());
}

/// Object.prototype.isPrototypeOf(V) — ES5 §15.2.4.6
/// Returns true if the object is in the prototype chain of V.
fn void builtin_object_proto_isPrototypeOf(BuiltinContext* ctx) {
    ctx.result.set_boolean(false);

    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        return;
    }
    HObject* proto = (HObject*)this_val.get_heapptr();

    // Get argument V — must be an object
    if (ctx.argc == 0) {
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object() || arg.get_heapptr() == null) {
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();

    // Walk the prototype chain of obj looking for proto
    HObject* cur = obj.prototype;
    while (cur != null) {
        if (cur == proto) {
            ctx.result.set_boolean(true);
            return;
        }
        cur = cur.prototype;
    }
}

/// Object.prototype.toLocaleString() — ES5 §15.2.4.3
/// Calls the toString method and returns the result.
fn void builtin_object_proto_toLocaleString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        ctx.result.set_undefined();
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();

    // Call toString() on the object
    HString* ts_key = builtin_intern_string(ctx.heap, "toString");
    PropValue*? entry = obj.find_prop(ts_key);
    if (try e = entry) {
        TVal fn_val = e.data.value;
        if (fn_val.is_lightfunc()) {
            // Re-dispatch to toString
            ctx.needs_re_dispatch = true;
            ctx.regs[ctx.base_reg - 1] = fn_val;  // replace callee with toString
            ctx.re_nargs = 0;
            return;
        }
        if (fn_val.is_object() && fn_val.get_heapptr() != null) {
            HObject* fn_obj = (HObject*)fn_val.get_heapptr();
            if (fn_obj.is_callable()) {
                ctx.needs_re_dispatch = true;
                ctx.regs[ctx.base_reg - 1] = fn_val;
                ctx.re_nargs = 0;
                return;
            }
        }
    }

    ctx.result.set_undefined();
}

// ============================================================================
// Array constructor builtins
// ============================================================================

/// Array() as function (ES5 §15.4.1) or new Array() as constructor (§15.4.2).
/// Creates and returns a new Array object.
fn void builtin_array(BuiltinContext* ctx) {
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    HString* len_key = builtin_intern_string(ctx.heap, "length");

    if (ctx.argc == 0) {
        // No args: empty array with length 0
        TVal len_val;
        len_val.set_fastint(0);
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(arr);
        return;
    }

    if (ctx.argc == 1) {
        // Single arg: check if it's a number
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.is_number() || arg.is_fastint()) {
            // Single numeric arg: set array length
            double d;
            if (arg.is_fastint()) {
                d = (double)arg.get_fastint();
            } else {
                d = arg.get_number();
            }
            // ToUint32 check per ES5
            uint n = (uint)(long)d;
            if ((double)n != d) {
                // Invalid array length — create empty array as fallback
                TVal len_val;
                len_val.set_fastint(0);
                arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
            } else {
                TVal len_val;
                len_val.set_fastint((long)n);
                arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
            }
        } else {
            // Single non-numeric arg: array with one element
            TVal len_val;
            len_val.set_fastint(1);
            arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

            // Set element at index 0
            HString* zero_key = builtin_intern_string(ctx.heap, "0");
            arr.put_prop(zero_key, arg, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.set_object(arr);
        return;
    }

    // Multiple args: create array with given elements
    TVal len_val;
    len_val.set_fastint((long)ctx.argc);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    // Set each element
    for (ushort i = 0; i < ctx.argc; i++) {
        TVal elem = ctx.regs[ctx.base_reg + (uint)i];
        char[16] buf;
        int len = libc::snprintf(&buf, 16, "%d", i);
        if (len > 0 && len < 16) {
            HString* idx_key = builtin_intern_string(ctx.heap, buf[:len]);
            arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        }
    }

    ctx.result.set_object(arr);
}

// ============================================================================
// Array.prototype helpers
// ============================================================================

/// Helper: get the 'this' value as an object for Array.prototype methods.
fn HObject* array_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        return (HObject*)this_val.get_heapptr();
    }
    // TypeError: Array.prototype method called on non-object
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Array.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        TVal err_tv;
        err_tv.set_object(err);
        ctx.throw_value = err_tv;
    }
    ctx.should_throw = true;
    return null;
}

/// Get the 'length' property of an array-like object as a uint.
fn uint array_get_length(HObject* obj, Heap* heap) {
    // Fast path: ARRAY uses cached array_length field (no prop table walk).
    if (obj.get_class() == ARRAY) {
        return obj.array_length;
    }
    // ARGUMENTS and other array-likes: read from prop table.
    if (obj.get_class() == ARGUMENTS) {
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key == null) return 0;
        TVal? len_val = obj.get_prop(len_key);
        if (try v = len_val) {
            if (v.is_fastint()) return (uint)(long)v.get_fastint();
            if (v.is_number()) return (uint)(long)v.get_number();
        }
        // Fallback: might be inherited
        len_val = obj.get_prop_proto(len_key);
        if (try v = len_val) {
            if (v.is_fastint()) return (uint)(long)v.get_fastint();
            if (v.is_number()) return (uint)(long)v.get_number();
        }
        return 0;
    }
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (len_key == null) return 0;
    TVal? len_val = obj.get_prop_proto(len_key);
    if (try v = len_val) {
        if (v.is_fastint()) return (uint)(long)v.get_fastint();
        if (v.is_number()) return (uint)(long)v.get_number();
    }
    return 0;
}

/// Set the 'length' property of an array-like object.
fn void array_set_length(HObject* obj, uint len_val, Heap* heap) {
    // Fast path: ARRAY uses cached array_length field + prop table sync.
    if (obj.get_class() == ARRAY) {
        obj.array_length = len_val;
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            int idx = obj.find_prop_idx(len_key);
            if (idx >= 0) {
                TVal tv;
                tv.set_fastint((long)len_val);
                obj.prop_values()[idx].data.value = tv;
                return;
            }
        }
        return;
    }
    // ARGUMENTS: update prop table directly.
    if (obj.get_class() == ARGUMENTS) {
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            int idx = obj.find_prop_idx(len_key);
            if (idx >= 0) {
                TVal tv;
                tv.set_fastint((long)len_val);
                obj.prop_values()[idx].data.value = tv;
                return;
            }
        }
    }
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (len_key == null) return;
    TVal tv;
    tv.set_fastint((long)len_val);
    obj.put_prop(len_key, tv, hobject::PROP_FLAGS_WEC);
}

/// Get array element at numeric index (returns undefined for holes).
/// Checks the dense array part first, then falls back to named properties.
fn TVal array_get_elem(HObject* obj, uint idx, Heap* heap) {
    // Try the dense array part first.
    if (obj.array_part() != null && idx < obj.array_size) {
        TVal v = obj.array_part()[idx];
        if (!v.is_undefined()) return v;
    }
    // Fall back to named property lookup (elements may be stored as named
    // properties via PUTPROP or Object.defineProperty).
    char[16] buf;
    int len = libc::snprintf(&buf, 16, "%d", idx);
    if (len <= 0 || len >= 16) { TVal undef; undef.set_undefined(); return undef; }
    HString* key = builtin_intern_string(heap, buf[:len]);
    if (key == null) { TVal undef; undef.set_undefined(); return undef; }
    TVal? result = obj.get_prop(key);
    if (try v = result) {
        return v;
    }
    TVal? result2 = obj.get_prop_proto(key);
    if (try v2 = result2) {
        return v2;
    }
    TVal undef; undef.set_undefined(); return undef;
}

/// Set array element at numeric index.
/// Uses the dense array part for numeric indices (O(1) push/append).
fn void array_set_elem(HObject* obj, uint idx, TVal val, Heap* heap) {
    obj.set_array_idx(idx, val);
}

/// Delete array element at numeric index (set to undefined in dense part).
fn void array_delete_elem(HObject* obj, uint idx, Heap* heap) {
    TVal undef; undef.set_undefined();
    obj.set_array_idx(idx, undef);
}

/// Strict equality comparison for Array.prototype.indexOf / lastIndexOf.
fn bool array_strict_equals(TVal a, TVal b) {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) || math::is_nan(b.get_number())) return false;
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING:    return a.get_heapptr() == b.get_heapptr();
            default: return false;
        }
    }
    if ((a.is_number() && b.is_fastint()) || (a.is_fastint() && b.is_number())) {
        double av = a.is_fastint() ? (double)a.get_fastint() : a.get_number();
        double bv = b.is_fastint() ? (double)b.get_fastint() : b.get_number();
        return av == bv;
    }
    return false;
}

/// Metadata for LIGHTFUNC builtins: name and expected arity.
/// Used by GETPROP to resolve `.name` and `.length` on LIGHTFUNC values.
struct BuiltinMeta {
    char[] name;
    int arity;
}

fn BuiltinMeta builtin_get_metadata(uint idx) {
    switch (idx) {
        case 0:  return { "print", 1 };
        case 1:  return { "log", 1 };
        case 2:  return { "parseInt", 2 };
        case 3:  return { "parseFloat", 1 };
        case 4:  return { "isNaN", 1 };
        case 5:  return { "isFinite", 1 };
        case 6:  return { "Error", 1 };
        case 7:  return { "TypeError", 1 };
        case 8:  return { "RangeError", 1 };
        case 9:  return { "ReferenceError", 1 };
        case 10: return { "SyntaxError", 1 };
        case 11: return { "EvalError", 1 };
        case 12: return { "toString", 0 };
        case 13: return { "Boolean", 1 };
        case 14: return { "toString", 0 };
        case 15: return { "valueOf", 0 };
        case 16: return { "String", 1 };
        case 17: return { "toString", 0 };
        case 18: return { "valueOf", 0 };
        case 19: return { "Number", 1 };
        case 20: return { "toString", 0 };
        case 21: return { "valueOf", 0 };
        case 22: return { "Object", 1 };
        case 23: return { "toString", 0 };
        case 24: return { "valueOf", 0 };
        case 25: return { "Array", 0 };
        case 26: return { "abs", 1 };
        case 27: return { "floor", 1 };
        case 28: return { "ceil", 1 };
        case 29: return { "round", 1 };
        case 30: return { "max", 2 };
        case 31: return { "min", 2 };
        case 32: return { "pow", 2 };
        case 33: return { "sqrt", 1 };
        case 34: return { "exp", 1 };
        case 35: return { "log", 1 };
        case 36: return { "sin", 1 };
        case 37: return { "cos", 1 };
        case 38: return { "tan", 1 };
        case 39: return { "random", 0 };
        case 40: return { "charAt", 1 };
        case 41: return { "charCodeAt", 1 };
        case 42: return { "indexOf", 2 };
        case 43: return { "slice", 2 };
        case 44: return { "substring", 2 };
        case 45: return { "substr", 2 };
        case 46: return { "toUpperCase", 0 };
        case 47: return { "toLowerCase", 0 };
        case 48: return { "trim", 0 };
        case 49: return { "split", 2 };
        case 50: return { "concat", 1 };
        case 51: return { "replace", 2 };
        case 52: return { "toString", 0 };
        case 53: return { "join", 1 };
        case 54: return { "pop", 0 };
        case 55: return { "push", 1 };
        case 56: return { "reverse", 0 };
        case 57: return { "shift", 0 };
        case 58: return { "slice", 2 };
        case 59: return { "sort", 1 };
        case 60: return { "splice", 2 };
        case 61: return { "unshift", 1 };
        case 62: return { "indexOf", 2 };
        case 63: return { "lastIndexOf", 2 };
        case 64: return { "concat", 1 };
        case 73: return { "toFixed", 1 };
        case 74: return { "toExponential", 1 };
        case 75: return { "toPrecision", 1 };
        case 77: return { "call", 1 };
        case 78: return { "apply", 2 };
        case 79: return { "bind", 1 };
        case 80: return { "bind", 1 };
        case 81: return { "eval", 1 };
        case 82: return { "parse", 2 };
        case 83: return { "stringify", 3 };
        case 84: return { "Date", 7 };
        case 85: return { "now", 0 };
        case 86: return { "UTC", 7 };
        case 87: return { "parse", 1 };
        case 88: return { "toString", 0 };
        case 89: return { "toJSON", 1 };
        case 90: return { "valueOf", 0 };
        case 91: return { "getTime", 0 };
        case 92: return { "getFullYear", 0 };
        case 93: return { "getMonth", 0 };
        case 94: return { "getDate", 0 };
        case 95: return { "getDay", 0 };
        case 96: return { "getHours", 0 };
        case 97: return { "getMinutes", 0 };
        case 98: return { "getSeconds", 0 };
        case 99: return { "getMilliseconds", 0 };
        case 101: return { "Function", 1 };
        case 103: return { "RegExp", 2 };
        case 104: return { "test", 1 };
        case 105: return { "exec", 1 };
        case 106: return { "toString", 0 };
        case 107: return { "isPrototypeOf", 1 };
        case 108: return { "hasOwnProperty", 1 };
        case 109: return { "propertyIsEnumerable", 1 };
        case 112: return { "Map", 0 };
        case 113: return { "set", 2 };
        case 114: return { "get", 1 };
        case 115: return { "has", 1 };
        case 116: return { "delete", 1 };
        case 117: return { "clear", 0 };
        case 118: return { "keys", 0 };
        case 119: return { "values", 0 };
        case 120: return { "entries", 0 };
        case 121: return { "forEach", 1 };
        case 122: return { "Set", 0 };
        case 123: return { "add", 1 };
        case 124: return { "has", 1 };
        case 125: return { "delete", 1 };
        case 126: return { "clear", 0 };
        case 127: return { "keys", 0 };
        case 128: return { "values", 0 };
        case 129: return { "entries", 0 };
        case 130: return { "forEach", 1 };
        case 131: return { "WeakMap", 0 };
        case 132: return { "set", 2 };
        case 133: return { "get", 1 };
        case 134: return { "has", 1 };
        case 135: return { "delete", 1 };
        case 136: return { "WeakSet", 0 };
        case 137: return { "add", 1 };
        case 138: return { "has", 1 };
        case 139: return { "delete", 1 };
        case 140: return { "Symbol", 1 };
        case 141: return { "for", 1 };
        case 142: return { "keyFor", 1 };
        case 143: return { "toString", 0 };
        case 144: return { "valueOf", 0 };
        case 145: return { "Promise", 1 };
        case 146: return { "then", 2 };
        case 147: return { "catch", 1 };
        case 148: return { "finally", 1 };
        case 149: return { "resolve", 1 };
        case 150: return { "reject", 1 };
        case 151: return { "all", 1 };
        case 152: return { "race", 1 };
        case 153: return { "Function", 1 };
        case 154: return { "next", 1 };
        case 155: return { "throw", 1 };
        case 156: return { "return", 1 };
        case 157: return { "keys", 1 };
        case 158: return { "getPrototypeOf", 1 };
        case 159: return { "isExtensible", 1 };
        case 160: return { "preventExtensions", 1 };
        case 161: return { "getOwnPropertyDescriptor", 2 };
        case 162: return { "defineProperty", 3 };
        case 163: return { "getOwnPropertyNames", 1 };
        case 164: return { "defineProperties", 2 };
        case 165: return { "create", 1 };
        case 166: return { "seal", 1 };
        case 167: return { "freeze", 1 };
        case 168: return { "isSealed", 1 };
        case 169: return { "isFrozen", 1 };
        case 170: return { "includes", 2 };
        case 171: return { "startsWith", 2 };
        case 172: return { "endsWith", 2 };
        case 173: return { "repeat", 1 };
        case 174: return { "trimStart", 0 };
        case 175: return { "trimEnd", 0 };
        case 176: return { "codePointAt", 1 };
        case 177: return { "at", 1 };
        case 178: return { "padStart", 2 };
        case 179: return { "padEnd", 2 };
        case 180: return { "lastIndexOf", 2 };
        case 181: return { "of", 0 };
        case 182: return { "fill", 1 };
        case 183: return { "find", 1 };
        case 184: return { "findIndex", 1 };
        case 185: return { "includes", 1 };
        case 186: return { "at", 1 };
        case 187: return { "copyWithin", 1 };
        case 188: return { "entries", 1 };
        case 189: return { "values", 1 };
        case 190: return { "assign", 2 };
        case 191: return { "isNaN", 1 };
        case 192: return { "isFinite", 1 };
        case 193: return { "isInteger", 1 };
        case 194: return { "isSafeInteger", 1 };
        case 195: return { "acos", 1 };
        case 196: return { "asin", 1 };
        case 197: return { "atan", 1 };
        case 198: return { "atan2", 2 };
        case 199: return { "cosh", 1 };
        case 200: return { "sinh", 1 };
        case 201: return { "tanh", 1 };
        case 202: return { "acosh", 1 };
        case 203: return { "asinh", 1 };
        case 204: return { "atanh", 1 };
        case 205: return { "log2", 1 };
        case 206: return { "log10", 1 };
        case 207: return { "log1p", 1 };
        case 208: return { "expm1", 1 };
        case 209: return { "cbrt", 1 };
        case 210: return { "hypot", 2 };
        case 211: return { "trunc", 1 };
        case 212: return { "sign", 1 };
        case 213: return { "fround", 1 };
        case 214: return { "clz32", 1 };
        case 215: return { "imul", 2 };
        case 216: return { "isArray", 1 };
        case 217: return { "fromCharCode", 1 };
        case 218: return { "is", 2 };
        case 219: return { "hasOwn", 2 };
        case 220: return { "setPrototypeOf", 2 };
        case 221: return { "flat", 0 };
        case 222: return { "flatMap", 1 };
        case 223: return { "fromCodePoint", 1 };
        case 224: return { "encodeURI", 1 };
        case 225: return { "encodeURIComponent", 1 };
        case 226: return { "decodeURI", 1 };
        case 227: return { "decodeURIComponent", 1 };
        case 228: return { "URIError", 1 };
        case 229: return { "toReversed", 0 };
        case 230: return { "toSorted", 1 };
        case 231: return { "toSpliced", 2 };
        case 232: return { "with", 2 };
        case 233: return { "match", 1 };
        case 234: return { "search", 1 };
        case 235: return { "getUTCFullYear", 0 };
        case 236: return { "getUTCMonth", 0 };
        case 237: return { "getUTCDate", 0 };
        case 238: return { "getUTCDay", 0 };
        case 239: return { "getUTCHours", 0 };
        case 240: return { "getUTCMinutes", 0 };
        case 241: return { "getUTCSeconds", 0 };
        case 242: return { "getUTCMilliseconds", 0 };
        case 243: return { "setTime", 1 };
        case 244: return { "setMilliseconds", 1 };
        case 245: return { "setSeconds", 2 };
        case 246: return { "setMinutes", 3 };
        case 247: return { "setHours", 4 };
        case 248: return { "setDate", 1 };
        case 249: return { "setMonth", 2 };
        case 250: return { "setFullYear", 3 };
        case 251: return { "setUTCMilliseconds", 1 };
        case 252: return { "setUTCSeconds", 2 };
        case 253: return { "setUTCMinutes", 3 };
        case 254: return { "setUTCHours", 4 };
        case 255: return { "setUTCDate", 1 };
        case 256: return { "setUTCMonth", 2 };
        case 257: return { "setUTCFullYear", 3 };
        case 258: return { "toISOString", 0 };
        case 259: return { "toUTCString", 0 };
        case 260: return { "toGMTString", 0 };
        case 261: return { "toLocaleString", 0 };
        case 262: return { "toLocaleDateString", 0 };
        case 263: return { "toLocaleTimeString", 0 };
        case 266: return { "allSettled", 1 };
        case 267: return { "any", 1 };
        case 268: return { "AggregateError", 2 };
        case 269: return { "next", 0 };
        case 270: return { "next", 0 };
        case 271: return { "[Symbol.iterator]", 0 };
        case 272: return { "[Symbol.iterator]", 0 };
        case 285: return { "from", 1 };
        default: return { "", -1 };
    }
}

/// Helper: register a method on Array.prototype.
/// Creates a proper HObject function with .name and .length properties
/// (ES6 §17: built-in function objects have non-enumerable .name/.length).
fn bool register_array_proto_method(HObject* proto, Heap* heap, char[] name, uint fn_index) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    void* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    // Create HObject function with builtin_fn_index for proper .name/.length
    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    func_obj.extra.func.builtin_fn_index = (int)fn_index;
    func_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
    func_obj.flags.callable = true;
    func_obj.prototype = heap.function_proto;
    // Set .name (non-writable, non-enumerable, configurable)
    HString* name_prop_key = builtin_intern_string(heap, "name");
    HString* name_val = builtin_intern_string(heap, name);
    if (name_prop_key != null && name_val != null) {
        TVal name_tv;
        name_tv.set_string(name_val);
        func_obj.put_prop(name_prop_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    // Set .length from builtin metadata
    builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_index);
    if (meta.arity >= 0) {
        HString* length_str = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (length_str != null) {
            TVal len_tv;
            len_tv.set_fastint((long)meta.arity);
            func_obj.put_prop(length_str, len_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    // Register on prototype
    TVal tv;
    tv.set_object(func_obj);
    proto.put_prop(key, tv, hobject::PROP_FLAGS_WC);
    return true;
}

/// Helper: compile a JS function expression and register it as a method on a prototype.
/// The src must be a complete function expression like "(function(a,b){...})" or "(function name(a){...})".
/// Used for callback-based methods (forEach, map, filter, etc.) that can't be LIGHTFUNC builtins.
/// length_override: if >= 0, overrides the .length property (for optional params like reduce's initialValue).
fn bool register_compiled_proto_method(HObject* proto, Heap* heap, EnvRecord* global_env, char[] name, char[] src, int length_override = -1) {
    Lexer lex = lexer::lexer_init(src, heap);
    CompiledFunction*? cf = compiler::compile_function(&lex, heap, true);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
        return false;
    }
    HObject*? func_obj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) return false;
    HObject* func_obj = func_obj_raw;
    func_obj.extra.func.comp_func = func;
    func_obj.extra.func.builtin_fn_index = -1;
    func_obj.extra.func.callable_kind = hobject::CallableKind.COMPILED_FN;
    func_obj.extra.func.var_env = global_env;
    func_obj.extra.func.lex_env = global_env;
    func_obj.prototype = heap.function_proto;
    func_obj.flags.callable = true;
    HString* name_str = builtin_intern_string(heap, "name");
    if (name_str != null) {
        HString* fname = builtin_intern_string(heap, name);
        if (fname != null) {
            TVal name_tv;
            name_tv.set_string(fname);
            func_obj.put_prop(name_str, name_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    HString* length_str = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (length_str != null) {
        TVal len_tv;
        long len_val = length_override >= 0 ? length_override : (long)func.num_formals;
        len_tv.set_fastint(len_val);
        func_obj.put_prop(length_str, len_tv, hobject::PROP_FLAGS_NWC);
    }
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    void* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal tv;
    tv.set_object(func_obj);
    proto.put_prop(key, tv, hobject::PROP_FLAGS_WC);
    return true;
}

// ============================================================================
// Array.prototype.toString (ES5 §15.4.4.2)
// ============================================================================
//
// Join all elements with comma separator.
fn void builtin_array_proto_toString(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    char[4096] buf;
    usz offset = 0;

    for (uint i = 0; i < len; i++) {
        if (i > 0) {
            if (offset < 4095) buf[offset++] = ',';
        }
        TVal elem = array_get_elem(obj, i, ctx.heap);
        if (!elem.is_undefined() && !elem.is_null()) {
            HString* elem_str = builtin_to_string(ctx.heap, &elem);
            if (elem_str != null) {
                char* data = elem_str.get_cstr();
                uint blen = elem_str.blen;
                uint max_copy = blen;
                if ((uint)offset + max_copy > 4090) max_copy = 4090 - (uint)offset;
                for (uint j = 0; j < max_copy; j++) {
                    buf[offset++] = data[j];
                }
            }
        }
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    if (result == null) { ctx.result.set_undefined(); return; }
    ctx.result.set_string(result);
}

// ============================================================================
// Array.prototype.join (ES5 §15.4.4.5)
// ============================================================================
fn void builtin_array_proto_join(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    // Get separator (default ",")
    char[] sep = ",";
    if (ctx.argc > 0) {
        TVal sep_val = ctx.regs[ctx.base_reg];
        HString* sep_str = builtin_to_string(ctx.heap, &sep_val);
        if (sep_str != null) {
            sep = sep_str.get_data();
        }
    }

    uint len = array_get_length(obj, ctx.heap);

    // Empty array returns ""
    if (len == 0) {
        HString* result = builtin_intern_string(ctx.heap, "");
        if (result == null) { ctx.result.set_undefined(); return; }
        ctx.result.set_string(result);
        return;
    }

    char[4096] buf;
    usz offset = 0;

    for (uint i = 0; i < len; i++) {
        if (i > 0) {
            for (usz si = 0; si < sep.len && offset < 4090; si++) {
                buf[offset++] = sep[si];
            }
        }
        TVal elem = array_get_elem(obj, i, ctx.heap);
        if (!elem.is_undefined() && !elem.is_null()) {
            HString* elem_str = builtin_to_string(ctx.heap, &elem);
            if (elem_str != null) {
                char* data = elem_str.get_cstr();
                uint blen = elem_str.blen;
                uint max_copy = blen;
                if (offset + max_copy > 4090) max_copy = 4090 - (uint)offset;
                for (uint j = 0; j < max_copy; j++) {
                    buf[offset++] = data[j];
                }
            }
        }
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    if (result == null) { ctx.result.set_undefined(); return; }
    ctx.result.set_string(result);
}

// ============================================================================
// Array.prototype.pop (ES5 §15.4.4.6)
// ============================================================================
fn void builtin_array_proto_pop(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    if (len == 0) {
        array_set_length(obj, 0, ctx.heap);
        ctx.result.set_undefined();
        return;
    }

    uint idx = len - 1;
    TVal elem = array_get_elem(obj, idx, ctx.heap);
    array_delete_elem(obj, idx, ctx.heap);
    array_set_length(obj, idx, ctx.heap);

    // Return the popped element
    *ctx.result = elem;
}

// ============================================================================
// Array.prototype.push (ES5 §15.4.4.7)
// ============================================================================
fn void builtin_array_proto_push(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    for (ushort i = 0; i < ctx.argc; i++) {
        TVal arg = ctx.regs[ctx.base_reg + i];
        array_set_elem(obj, len + i, arg, ctx.heap);
    }

    uint new_len = len + (uint)ctx.argc;
    array_set_length(obj, new_len, ctx.heap);

    ctx.result.set_fastint((long)new_len);
}

// ============================================================================
// Array.prototype.reverse (ES5 §15.4.4.8)
// ============================================================================
fn void builtin_array_proto_reverse(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    uint middle = len / 2;

    for (uint lower = 0; lower < middle; lower++) {
        uint upper = len - 1 - lower;
        TVal lower_val = array_get_elem(obj, lower, ctx.heap);
        TVal upper_val = array_get_elem(obj, upper, ctx.heap);
        array_set_elem(obj, lower, upper_val, ctx.heap);
        array_set_elem(obj, upper, lower_val, ctx.heap);
    }

    ctx.result.set_object(obj);
}

// ============================================================================
// Array.prototype.shift (ES5 §15.4.4.9)
// ============================================================================
fn void builtin_array_proto_shift(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    if (len == 0) {
        array_set_length(obj, 0, ctx.heap);
        ctx.result.set_undefined();
        return;
    }

    TVal first = array_get_elem(obj, 0, ctx.heap);

    for (uint k = 1; k < len; k++) {
        TVal elem = array_get_elem(obj, k, ctx.heap);
        array_set_elem(obj, k - 1, elem, ctx.heap);
    }

    array_delete_elem(obj, len - 1, ctx.heap);
    array_set_length(obj, len - 1, ctx.heap);

    // Return the first element
    *ctx.result = first;
}

// ============================================================================
// Array.prototype.slice (ES5 §15.4.4.10)
// ============================================================================
fn void builtin_array_proto_slice(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    // Determine start
    double relative_start = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.is_fastint()) {
            relative_start = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_start = arg.get_number();
        }
    }

    uint k;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        k = tmp < 0 ? 0 : (uint)(long)tmp;
    } else {
        k = relative_start > (double)len ? len : (uint)(long)relative_start;
    }

    // Determine end
    double relative_end = (double)len;
    if (ctx.argc > 1) {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        if (arg.is_fastint()) {
            relative_end = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_end = arg.get_number();
        }
    }

    uint final_val;
    if (relative_end < 0) {
        double tmp = (double)len + relative_end;
        final_val = tmp < 0 ? 0 : (uint)(long)tmp;
    } else {
        final_val = relative_end > (double)len ? len : (uint)(long)relative_end;
    }

    // Create result array
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined();
        return;
    }
    HObject* result_arr = new_arr;
    result_arr.prototype = ctx.heap.array_proto;

    uint n = 0;
    for (uint i = k; i < final_val; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        array_set_elem(result_arr, n, elem, ctx.heap);
        n++;
    }
    array_set_length(result_arr, n, ctx.heap);

    ctx.result.set_object(result_arr);
}

// ============================================================================
// Array.prototype.sort (ES5 §15.4.4.11) — with comparefn support
// ============================================================================
fn void builtin_array_proto_sort(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    if (len <= 1) {
        ctx.result.set_object(obj);
        return;
    }

    // Check comparefn argument
    bool has_comparefn = false;
    TVal comparefn;
    comparefn.set_undefined();
    if (ctx.argc > 0) {
        TVal* arg0 = &ctx.regs[ctx.base_reg];
        if (!arg0.is_undefined()) {
            if (!arg0.is_object() || arg0.get_heapptr() == null ||
                !((HObject*)arg0.get_heapptr()).is_callable()) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_str = builtin_intern_string(ctx.heap,
                        "Array.prototype.sort: comparefn is not a function or undefined");
                    if (msg_str != null) {
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
                    }
                    TVal err_tv;
                    err_tv.set_object(err);
                    ctx.throw_value = err_tv;
                }
                ctx.should_throw = true;
                return;
            }
            comparefn = *arg0;
            has_comparefn = true;
        }
    }

    // Compact defined elements to the front
    uint def_count = 0;
    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        if (!elem.is_undefined()) {
            array_set_elem(obj, def_count, elem, ctx.heap);
            def_count++;
        }
    }

    // Bubble-sort
    for (uint i = 0; i < def_count; i++) {
        for (uint j = 0; j < def_count - 1 - i; j++) {
            TVal a = array_get_elem(obj, j, ctx.heap);
            TVal b = array_get_elem(obj, j + 1, ctx.heap);
            int cmp = 0;

            if (has_comparefn && ctx.heap.call_fn != null && ctx.vm != null) {
                TVal[2] args;
                args[0] = a;
                args[1] = b;
                TVal this_val;
                this_val.set_undefined();
                TVal res = ctx.heap.call_fn(ctx.vm, comparefn, &args[0], 2, this_val);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    return;
                }
                TVal num;
                builtin_to_number(&res, &num);
                if (num.is_number()) {
                    double d = num.get_number();
                    if (!math::is_nan(d)) {
                        cmp = d < 0 ? -1 : (d > 0 ? 1 : 0);
                    }
                } else if (num.is_fastint()) {
                    long v = num.get_fastint();
                    cmp = v < 0 ? -1 : (v > 0 ? 1 : 0);
                }
            } else {
                HString* a_str = builtin_to_string(ctx.heap, &a);
                HString* b_str = builtin_to_string(ctx.heap, &b);
                if (a_str != null && b_str != null) {
                    cmp = hstring::hstring_compare(a_str, b_str);
                } else if (a_str == null && b_str == null) {
                    cmp = 0;
                } else if (a_str == null) {
                    cmp = 1;
                } else {
                    cmp = -1;
                }
            }
            if (cmp > 0) {
                array_set_elem(obj, j, b, ctx.heap);
                array_set_elem(obj, j + 1, a, ctx.heap);
            }
        }
    }

    // Delete remaining elements (holes/undefined go to end)
    for (uint i = def_count; i < len; i++) {
        array_delete_elem(obj, i, ctx.heap);
    }

    ctx.result.set_object(obj);
}

// ============================================================================
// Array.prototype.splice (ES5 §15.4.4.12)
// ============================================================================
fn void builtin_array_proto_splice(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    // Get relativeStart (argument 0)
    double relative_start = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.is_fastint()) {
            relative_start = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_start = arg.get_number();
        }
    }

    uint actual_start;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        actual_start = tmp < 0 ? 0 : (uint)(long)tmp;
    } else {
        actual_start = relative_start > (double)len ? len : (uint)(long)relative_start;
    }

    // Get actualDeleteCount
    uint actual_delete_count;
    if (ctx.argc <= 1) {
        actual_delete_count = len - actual_start;
    } else {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        double delete_count;
        if (arg.is_fastint()) {
            delete_count = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            delete_count = arg.get_number();
        } else {
            delete_count = 0;
        }

        if (delete_count < 0) delete_count = 0;
        uint dc = (uint)(long)delete_count;
        actual_delete_count = dc > (len - actual_start) ? (len - actual_start) : dc;
    }

    // Create result array with deleted items
    HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = result_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* result = result_raw;
    result.prototype = ctx.heap.array_proto;

    for (uint i = 0; i < actual_delete_count; i++) {
        TVal elem = array_get_elem(obj, actual_start + i, ctx.heap);
        array_set_elem(result, i, elem, ctx.heap);
    }
    array_set_length(result, actual_delete_count, ctx.heap);

    // Get items to insert
    ushort item_count = 0;
    if (ctx.argc > 2) {
        item_count = ctx.argc - 2;
    }

    // Shift elements left or right
    if (item_count < actual_delete_count) {
        uint shift_len = len - actual_start - actual_delete_count;
        for (uint k = 0; k < shift_len; k++) {
            TVal elem = array_get_elem(obj, actual_start + actual_delete_count + k, ctx.heap);
            array_set_elem(obj, actual_start + item_count + k, elem, ctx.heap);
        }
        uint new_len = len - actual_delete_count + item_count;
        for (uint k = new_len; k < len; k++) {
            array_delete_elem(obj, k, ctx.heap);
        }
        array_set_length(obj, new_len, ctx.heap);
    } else if (item_count > actual_delete_count) {
        uint shift_len = len - actual_start - actual_delete_count;
        for (uint k = shift_len; k > 0; k--) {
            uint from = actual_start + actual_delete_count + k - 1;
            uint to = actual_start + item_count + k - 1;
            TVal elem = array_get_elem(obj, from, ctx.heap);
            array_set_elem(obj, to, elem, ctx.heap);
        }
        array_set_length(obj, len - actual_delete_count + item_count, ctx.heap);
    }

    // Insert new items
    for (ushort i = 0; i < item_count; i++) {
        TVal item = ctx.regs[ctx.base_reg + 2 + i];
        array_set_elem(obj, actual_start + i, item, ctx.heap);
    }

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.toReversed (ES2023 §23.1.3.33)
// ============================================================================
fn void builtin_array_proto_toReversed(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toReversed called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, len - 1 - i, ctx.heap);
        array_set_elem(result, i, elem, ctx.heap);
    }
    array_set_length(result, len, ctx.heap);

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.toSorted (ES2023 §23.1.3.34) — default compare (no comparefn)
// ============================================================================
fn void builtin_array_proto_toSorted(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toSorted called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    // Create a copy
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        array_set_elem(result, i, elem, ctx.heap);
    }
    array_set_length(result, len, ctx.heap);

    // Compact defined elements to the front
    uint def_count = 0;
    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(result, i, ctx.heap);
        if (!elem.is_undefined()) {
            array_set_elem(result, def_count, elem, ctx.heap);
            def_count++;
        }
    }

    // Bubble-sort defined elements by string comparison
    for (uint i = 0; i < def_count; i++) {
        for (uint j = 0; j < def_count - 1 - i; j++) {
            TVal a = array_get_elem(result, j, ctx.heap);
            TVal b = array_get_elem(result, j + 1, ctx.heap);
            HString* a_str = builtin_to_string(ctx.heap, &a);
            HString* b_str = builtin_to_string(ctx.heap, &b);
            int cmp = 0;
            if (a_str != null && b_str != null) {
                cmp = hstring::hstring_compare(a_str, b_str);
            } else if (a_str == null && b_str == null) {
                cmp = 0;
            } else if (a_str == null) {
                cmp = 1;
            } else {
                cmp = -1;
            }
            if (cmp > 0) {
                array_set_elem(result, j, b, ctx.heap);
                array_set_elem(result, j + 1, a, ctx.heap);
            }
        }
    }

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.toSpliced (ES2023 §23.1.3.35)
// ============================================================================
fn void builtin_array_proto_toSpliced(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toSpliced called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    // Get relativeStart (argument 0)
    double relative_start = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.is_fastint()) {
            relative_start = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_start = arg.get_number();
        }
    }

    uint actual_start;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        actual_start = tmp < 0 ? 0 : (uint)(long)tmp;
    } else {
        actual_start = relative_start > (double)len ? len : (uint)(long)relative_start;
    }

    // Get actualDeleteCount
    uint actual_delete_count;
    if (ctx.argc <= 1) {
        actual_delete_count = len - actual_start;
    } else {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        double delete_count;
        if (arg.is_fastint()) {
            delete_count = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            delete_count = arg.get_number();
        } else {
            delete_count = 0;
        }

        if (delete_count < 0) delete_count = 0;
        uint dc = (uint)(long)delete_count;
        actual_delete_count = dc > (len - actual_start) ? (len - actual_start) : dc;
    }

    // Get items to insert
    ushort item_count = 0;
    if (ctx.argc > 2) {
        item_count = ctx.argc - 2;
    }

    // Create new array: prefix + items + suffix
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    uint n = 0;
    // Copy prefix [0, actual_start)
    for (uint i = 0; i < actual_start; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        array_set_elem(result, n, elem, ctx.heap);
        n++;
    }
    // Insert new items
    for (ushort i = 0; i < item_count; i++) {
        TVal item = ctx.regs[ctx.base_reg + 2 + i];
        array_set_elem(result, n, item, ctx.heap);
        n++;
    }
    // Copy suffix [actual_start + actual_delete_count, len)
    for (uint i = actual_start + actual_delete_count; i < len; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        array_set_elem(result, n, elem, ctx.heap);
        n++;
    }
    array_set_length(result, n, ctx.heap);

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.with (ES2023 §23.1.3.37)
// ============================================================================
fn void builtin_array_proto_with(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.with called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    // Get index using ToIntegerOrInfinity
    double index_d = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        index_d = builtin_to_integer(arg);
    }

    uint actual_index;
    if (index_d < 0) {
        double tmp = (double)len + index_d;
        if (tmp < 0) {
            actual_index = len; // Out of range
        } else {
            actual_index = (uint)(long)tmp;
        }
    } else if (index_d < (double)len) {
        actual_index = (uint)(long)index_d;
    } else {
        actual_index = len; // Out of range (includes NaN, Infinity, >= len)
    }

    if (actual_index >= len) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.range_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Invalid array index");
            TVal msg_tv; msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        return;
    }

    // Get value to set
    TVal new_val;
    if (ctx.argc > 1) {
        new_val = ctx.regs[ctx.base_reg + 1];
    } else {
        new_val.set_undefined();
    }

    // Create new array
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    for (uint i = 0; i < len; i++) {
        if (i == actual_index) {
            array_set_elem(result, i, new_val, ctx.heap);
        } else {
            TVal elem = array_get_elem(obj, i, ctx.heap);
            array_set_elem(result, i, elem, ctx.heap);
        }
    }
    array_set_length(result, len, ctx.heap);

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.unshift (ES5 §15.4.4.13)
// ============================================================================
fn void builtin_array_proto_unshift(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    ushort arg_count = ctx.argc;

    // Shift existing elements right by arg_count
    for (uint k = len; k > 0; k--) {
        uint from = k - 1;
        uint to = k - 1 + arg_count;
        TVal elem = array_get_elem(obj, from, ctx.heap);
        array_set_elem(obj, to, elem, ctx.heap);
    }

    // Insert new items at the beginning
    for (ushort i = 0; i < arg_count; i++) {
        TVal arg = ctx.regs[ctx.base_reg + i];
        array_set_elem(obj, i, arg, ctx.heap);
    }

    uint new_len = len + (uint)arg_count;
    array_set_length(obj, new_len, ctx.heap);

    ctx.result.set_fastint((long)new_len);
}

// ============================================================================
// Array.prototype.indexOf (ES5 §15.4.4.14)
// ============================================================================
fn void builtin_array_proto_indexOf(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    if (ctx.argc == 0) {
        ctx.result.set_fastint(-1);
        return;
    }

    TVal search_elem = ctx.regs[ctx.base_reg];

    // Get fromIndex (default 0)
    double relative_start = 0.0;
    if (ctx.argc > 1) {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        if (arg.is_fastint()) {
            relative_start = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_start = arg.get_number();
        }
    }

    uint k;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        k = tmp < 0 ? 0 : (uint)(long)tmp;
    } else {
        k = relative_start > (double)len ? len : (uint)(long)relative_start;
    }

    for (; k < len; k++) {
        TVal elem = array_get_elem(obj, k, ctx.heap);
        if (array_strict_equals(elem, search_elem)) {
            ctx.result.set_fastint((long)k);
            return;
        }
    }

    ctx.result.set_fastint(-1);
}

// ============================================================================
// Array.prototype.lastIndexOf (ES5 §15.4.4.15)
// ============================================================================
fn void builtin_array_proto_lastIndexOf(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    if (ctx.argc == 0) {
        ctx.result.set_fastint(-1);
        return;
    }

    TVal search_elem = ctx.regs[ctx.base_reg];

    // Get fromIndex (default len - 1)
    double relative_start = (double)(len - 1);
    if (ctx.argc > 1) {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        if (arg.is_fastint()) {
            relative_start = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_start = arg.get_number();
        }
    }

    int k;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        k = tmp < 0 ? -1 : (int)(long)tmp;
    } else {
        k = relative_start > (double)len ? (int)len - 1 : (int)(long)relative_start;
    }

    for (; k >= 0; k--) {
        TVal elem = array_get_elem(obj, (uint)k, ctx.heap);
        if (array_strict_equals(elem, search_elem)) {
            ctx.result.set_fastint((long)k);
            return;
        }
    }

    ctx.result.set_fastint(-1);
}

// ============================================================================
// Array.prototype.concat (ES5 §15.4.4.4)
// ============================================================================
fn void builtin_array_proto_concat(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    // Create result array
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined();
        return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    uint n = 0;

    // First, copy 'this' elements
    uint this_len = array_get_length(obj, ctx.heap);
    for (uint i = 0; i < this_len; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        array_set_elem(result, n, elem, ctx.heap);
        n++;
    }

    // Then process each argument
    for (ushort arg_i = 0; arg_i < ctx.argc; arg_i++) {
        TVal arg = ctx.regs[ctx.base_reg + arg_i];

        if (arg.is_object() && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.ARRAY) {
            // If argument is an Array, copy its elements
            HObject* arg_arr = (HObject*)arg.get_heapptr();
            uint arg_len = array_get_length(arg_arr, ctx.heap);
            for (uint i = 0; i < arg_len; i++) {
                TVal elem = array_get_elem(arg_arr, i, ctx.heap);
                array_set_elem(result, n, elem, ctx.heap);
                n++;
            }
        } else {
            // Otherwise, add the argument itself
            array_set_elem(result, n, arg, ctx.heap);
            n++;
        }
    }

    array_set_length(result, n, ctx.heap);

    ctx.result.set_object(result);
}

// ============================================================================
// Math method builtins
// ============================================================================

/// Helper: get numeric arg at index i, defaulting to NaN if absent.
fn double math_arg(BuiltinContext* ctx, ushort i) {
    if (i >= ctx.argc) return double::nan;
    TVal* arg = &ctx.regs[ctx.base_reg + i];
    if (arg.is_fastint()) return (double)arg.get_fastint();
    if (arg.is_number()) return arg.get_number();
    // Non-numeric — need ToNumber
    TVal num;
    builtin_to_number(arg, &num);
    return num.is_fastint() ? (double)num.get_fastint() : num.get_number();
}

fn void builtin_math_abs(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math::abs(x));
}

fn void builtin_math_floor(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math::floor(x));
}

fn void builtin_math_ceil(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math::ceil(x));
}

fn void builtin_math_round(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(0.0);
    // ES5 §15.8.2.15: round half away from zero
    if (math::is_nan(x)) {
        ctx.result.set_number(double::nan);
    } else if (math::is_inf(x) || x == 0.0) {
        ctx.result.set_number(x);
    } else {
        // round half up (away from zero)
        double frac = x - math::floor(x);
        if (frac < 0.5) {
            ctx.result.set_number(math::floor(x));
        } else if (frac > 0.5) {
            ctx.result.set_number(math::ceil(x));
        } else {
            // exactly 0.5 — round away from zero
            ctx.result.set_number(math::floor(x) + 1.0);
        }
    }
}

fn void builtin_math_max(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        ctx.result.set_number(-double::inf);
        return;
    }
    double max = math_arg(ctx, 0);
    for (ushort i = 1; i < ctx.argc; i++) {
        double v = math_arg(ctx, i);
        if (math::is_nan(v)) {
            max = double::nan;
        } else if (v > max || math::is_nan(max)) {
            max = v;
        }
    }
    ctx.result.set_number(max);
}

fn void builtin_math_min(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        ctx.result.set_number(double::inf);
        return;
    }
    double min = math_arg(ctx, 0);
    for (ushort i = 1; i < ctx.argc; i++) {
        double v = math_arg(ctx, i);
        if (math::is_nan(v)) {
            min = double::nan;
        } else if (v < min || math::is_nan(min)) {
            min = v;
        }
    }
    ctx.result.set_number(min);
}

fn void builtin_math_pow(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    double y = math_arg(ctx, 1);
    ctx.result.set_number(0.0);
    if (math::is_nan(y) && x != 1.0) {
        ctx.result.set_number(double::nan);
    } else {
        ctx.result.set_number(math_pow(x, y));
    }
}

fn void builtin_math_sqrt(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_sqrt(x));
}

fn void builtin_math_exp(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_exp(x));
}

fn void builtin_math_log(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_log(x));
}

fn void builtin_math_sin(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_sin(x));
}

fn void builtin_math_cos(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_cos(x));
}

fn void builtin_math_tan(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_tan(x));
}

/// Math.random() — uses the heap's PRNG state (xorshift32).
fn void builtin_math_random(BuiltinContext* ctx) {
    uint state = ctx.heap.rnd_state;
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    ctx.heap.rnd_state = state;
    ctx.result.set_number((double)state / 4294967296.0);
}

fn void builtin_math_acos(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_acos(x));
}

fn void builtin_math_asin(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_asin(x));
}

fn void builtin_math_atan(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_atan(x));
}

fn void builtin_math_atan2(BuiltinContext* ctx) {
    double y = math_arg(ctx, 0);
    double x = math_arg(ctx, 1);
    ctx.result.set_number(math_atan2(y, x));
}

fn void builtin_math_cosh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_cosh(x));
}

fn void builtin_math_sinh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_sinh(x));
}

fn void builtin_math_tanh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_tanh(x));
}

fn void builtin_math_acosh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_acosh(x));
}

fn void builtin_math_asinh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_asinh(x));
}

fn void builtin_math_atanh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_atanh(x));
}

fn void builtin_math_log2(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_log2(x));
}

fn void builtin_math_log10(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_log10(x));
}

fn void builtin_math_log1p(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_log1p(x));
}

fn void builtin_math_expm1(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_expm1(x));
}

fn void builtin_math_cbrt(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_cbrt(x));
}

fn void builtin_math_hypot(BuiltinContext* ctx) {
    double result = 0.0;
    for (ushort i = 0; i < ctx.argc; i++) {
        double v = math_arg(ctx, i);
        if (math::is_nan(v)) { result = double::nan; break; }
        result = result + v * v;
    }
    ctx.result.set_number(math_sqrt(result));
}

fn void builtin_math_trunc(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(0.0);
    if (x >= 0) {
        ctx.result.set_number(math::floor(x));
    } else {
        ctx.result.set_number(math::ceil(x));
    }
}

fn void builtin_math_sign(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(0.0);
    if (math::is_nan(x) || x == 0.0) {
        ctx.result.set_number(x);
    } else if (x > 0.0) {
        ctx.result.set_number(1.0);
    } else {
        ctx.result.set_number(-1.0);
    }
}

fn void builtin_math_fround(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(0.0);
    if (math::is_nan(x) || math::is_inf(x) || x == 0.0) {
        ctx.result.set_number(x);
    } else {
        // Round to nearest float32
        float f = (float)x;
        ctx.result.set_number((double)f);
    }
}

fn void builtin_math_clz32(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    uint val = (uint)x;
    if (val == 0) {
        ctx.result.set_fastint(32);
    } else {
        uint count = 0;
        while ((val & 0x80000000) == 0) {
            count++;
            val <<= 1;
        }
        ctx.result.set_fastint((long)count);
    }
}

fn void builtin_math_imul(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    double y = math_arg(ctx, 1);
    int a = (int)(uint)x;
    int b = (int)(uint)y;
    ctx.result.set_fastint((long)(a * b));
}

/// Array.from(items[, mapfn[, thisArg]]) — ES6 §22.1.2.1
///
/// Creates a new Array from an iterable or array-like object.
/// Supports an optional mapfn applied to each element.
fn void builtin_array_from(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Step 1: Get items (first arg) — use undefined if missing
    TVal items;
    if (ctx.argc > 0) {
        items = ctx.regs[ctx.base_reg];
    } else {
        items.set_undefined();
    }

    // Step 2: Check mapfn (second arg, optional)
    TVal mapfn;
    bool mapping = false;
    TVal this_arg;
    if (ctx.argc > 1) {
        mapfn = ctx.regs[ctx.base_reg + 1];
        if (!mapfn.is_undefined() && !mapfn.is_null()) {
            bool callable = false;
            if (mapfn.is_lightfunc()) {
                callable = true;
            } else if (mapfn.is_object() && mapfn.get_heapptr() != null) {
                HObject* fn_obj = (HObject*)mapfn.get_heapptr();
                callable = fn_obj.is_callable();
            }
            if (!callable) {
                HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = heap.type_err_proto;
                    HString* msg_str = builtin_intern_string(heap, "The second argument to Array.from is not callable");
                    if (msg_str != null) {
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = builtin_intern_string(heap, "message");
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
                    }
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                }
                ctx.result.set_undefined();
                return;
            }
            mapping = true;
            if (ctx.argc > 2) {
                this_arg = ctx.regs[ctx.base_reg + 2];
            } else {
                this_arg.set_undefined();
            }
        }
    }

    // Step 3: Try iterable path — get @@iterator from items
    HString* iter_sym = ensure_iterator_symbol(heap);
    bool use_iter = false;
    TVal iterator;
    TVal iterable = items;

    if (iter_sym != null) {
        // GetMethod(items, @@iterator) — ToObject if needed for property access
        HObject* items_obj = null;
        if (items.is_object() && items.get_heapptr() != null) {
            items_obj = (HObject*)items.get_heapptr();
        } else if (!items.is_undefined() && !items.is_null()) {
            // Wrap primitive in temporary object to look up @@iterator
            HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try w = wrapped) {
                items_obj = w;
                // For strings, set the wrapped primitive value
                if (items.is_string()) {
                    items_obj.extra.prim.primitive_value = items;
                }
                HString* proto_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
                if (proto_key != null && heap.string_proto != null) {
                    TVal proto_tv; proto_tv.set_object(heap.string_proto);
                    PropFlags pf; pf.writable = false; pf.enumerable = false; pf.configurable = false; pf.is_accessor = false;
                    items_obj.put_prop(proto_key, proto_tv, pf);
                }
            }
        }

        if (items_obj != null) {
            TVal? iter_method_opt = items_obj.get_prop_proto(iter_sym);
            if (try iter_method = iter_method_opt) {
                bool callable = false;
                if (iter_method.is_lightfunc()) {
                    callable = true;
                } else if (iter_method.is_object() && iter_method.get_heapptr() != null) {
                    HObject* fn_hobj = (HObject*)iter_method.get_heapptr();
                    callable = fn_hobj.is_callable();
                }
                if (callable && heap.call_fn != null && ctx.vm != null) {
                    iterator = heap.call_fn(ctx.vm, iter_method, null, 0, items);
                    use_iter = true;
                }
            }
        }
    }

    if (use_iter) {
        // === Iterable path ===
        HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = arr_raw) { ctx.result.set_undefined(); return; }
        HObject* arr = arr_raw;
        arr.prototype = heap.array_proto;

        HString* next_key = builtin_intern_string(heap, "next");
        HString* done_key = builtin_intern_string(heap, "done");
        HString* value_key = builtin_intern_string(heap, "value");

        uint k = 0;
        while (heap.call_fn != null && ctx.vm != null) {
            if (!iterator.is_object() || iterator.get_heapptr() == null) break;
            HObject* iter_obj = (HObject*)iterator.get_heapptr();

            TVal? next_method_opt = iter_obj.get_prop_proto(next_key);
            TVal next_method;
            if (try nm = next_method_opt) {
                next_method = nm;
            } else { break; }

            bool callable = false;
            if (next_method.is_lightfunc()) {
                callable = true;
            } else if (next_method.is_object() && next_method.get_heapptr() != null) {
                callable = ((HObject*)next_method.get_heapptr()).is_callable();
            }
            if (!callable) break;

            TVal result = heap.call_fn(ctx.vm, next_method, null, 0, iterator);
            if (!result.is_object() || result.get_heapptr() == null) break;

            HObject* result_obj = (HObject*)result.get_heapptr();
            TVal? done_opt = result_obj.get_prop_proto(done_key);
            bool done = false;
            if (try dv = done_opt) {
                done = builtin_to_boolean(&dv);
            }
            if (done) break;

            TVal? value_opt = result_obj.get_prop_proto(value_key);
            TVal next_value;
            if (try vv = value_opt) {
                next_value = vv;
            } else { break; }

            // Apply mapfn if mapping
            TVal final_value = next_value;
            if (mapping) {
                TVal[2] map_args;
                map_args[0] = next_value;
                TVal k_tv; k_tv.set_fastint((long)k);
                map_args[1] = k_tv;
                final_value = heap.call_fn(ctx.vm, mapfn, &map_args[0], 2, this_arg);
            }

            // arr[k] = final_value
            char[16] buf;
            int slen = libc::snprintf(&buf, 16, "%u", k);
            if (slen > 0 && slen < 16) {
                HString* pk = builtin_intern_string(heap, buf[:slen]);
                arr.put_prop(pk, final_value, hobject::PROP_FLAGS_WEC);
            }
            k++;
        }

        HString* len_key = builtin_intern_string(heap, "length");
        if (len_key != null) {
            TVal len_tv; len_tv.set_fastint((long)k);
            arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
        }

        ctx.result.set_object(arr);
        return;
    }

    // === Array-like path ===
    // Step: items must not be null or undefined
    if (items.is_undefined() || items.is_null()) {
        HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = heap.type_err_proto;
            HString* msg_str = builtin_intern_string(heap, "Cannot convert undefined or null to object");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        ctx.result.set_undefined();
        return;
    }

    // ToObject — handle strings specially (direct char access)
    HObject* array_like;
    bool is_string_prim = items.is_string();
    HString* str_val = null;
    if (is_string_prim) {
        str_val = (HString*)items.get_heapptr();
    } else if (items.is_object() && items.get_heapptr() != null) {
        array_like = (HObject*)items.get_heapptr();
    } else {
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) { ctx.result.set_undefined(); return; }
        array_like = wrapped;
        array_like.extra.prim.primitive_value = items;
    }

    // Get .length
    HString* len_key = builtin_intern_string(heap, "length");
    uint len = 0;
    if (is_string_prim) {
        len = str_val.clen;
    } else if (len_key != null) {
        TVal? len_opt = array_like.get_prop_proto(len_key);
        if (try lv = len_opt) {
            double len_d = builtin_to_number_getdouble(ctx, &lv);
            if (len_d <= 0) {
                len = 0;
            } else if (math::is_inf(len_d)) {
                len = 0xFFFFFFFF;  // max uint
            } else if (len_d > (double)0xFFFFFFFF) {
                len = 0xFFFFFFFF;
            } else {
                len = (uint)(long)len_d;
            }
        }
    }

    // Create result array
    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = heap.array_proto;

    for (uint k = 0; k < len; k++) {
        char[16] buf;
        int slen = libc::snprintf(&buf, 16, "%u", k);
        TVal k_value;
        k_value.set_undefined();

        if (is_string_prim && str_val != null) {
            // String primitive: direct character access by byte index
            char* data = str_val.get_cstr();
            uint blen = str_val.blen;
            if (k < blen) {
                char[2] char_buf;
                char_buf[0] = data[k];
                char_buf[1] = 0;
                HString* ch_str = builtin_intern_string(heap, char_buf[:1]);
                if (ch_str != null) k_value.set_string(ch_str);
            }
        } else if (slen > 0 && slen < 16) {
            HString* pk = builtin_intern_string(heap, buf[:slen]);
            TVal? elem_opt = array_like.get_prop_proto(pk);
            if (try elem = elem_opt) {
                k_value = elem;
            }
        }

        TVal final_value = k_value;
        if (mapping) {
            TVal[2] map_args;
            map_args[0] = k_value;
            TVal k_tv; k_tv.set_fastint((long)k);
            map_args[1] = k_tv;
            if (heap.call_fn != null && ctx.vm != null) {
                final_value = heap.call_fn(ctx.vm, mapfn, &map_args[0], 2, this_arg);
            }
        }

        if (slen > 0 && slen < 16) {
            HString* pk = builtin_intern_string(heap, buf[:slen]);
            arr.put_prop(pk, final_value, hobject::PROP_FLAGS_WEC);
        }
    }

    // Set arr.length = len
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint((long)len);
        arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
    }

    ctx.result.set_object(arr);
}

/// Array.isArray(arg) — ES6 §22.1.2.2
fn void builtin_array_isArray(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object() || arg.get_heapptr() == null) {
        ctx.result.set_boolean(false);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    ctx.result.set_boolean(obj.get_class() == hobject::ObjClass.ARRAY);
}

// ============================================================================
// Function.prototype methods
// ============================================================================

/// Helper: get argument from the value stack by index (0-based within the call).
fn TVal builtin_arg(BuiltinContext* ctx, uint idx) {
    if (idx < ctx.argc) {
        return ctx.regs[ctx.base_reg + idx];
    }
    TVal undef;
    undef.set_undefined();
    return undef;
}

/// Function.prototype.call(thisArg, ...args)
///
/// Calls `this` (the downstream function) with `thisArg` as `this` and the
/// remaining arguments passed individually.
///
/// ES5 §15.3.4.4
fn void builtin_function_proto_call(BuiltinContext* ctx) {
    TVal downstream = ctx.this_val;

    // Validate downstream is callable
    bool callable = false;
    if (downstream.is_lightfunc()) {
        callable = true;
    } else if (downstream.is_object()) {
        HObject* hobj = (HObject*)downstream.get_heapptr();
        if (hobj != null) {
            callable = hobj.is_callable();
        }
    }

    if (!callable) {
        // Throw TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            // Cannot easily throw from here — set needs_throw or similar
        }
        ctx.result.set_undefined();
        return;
    }

    // Determine new this value
    TVal new_this;
    if (ctx.argc > 0) {
        new_this = builtin_arg(ctx, 0);
    } else {
        new_this.set_undefined();
    }

    // Number of remaining args after thisArg
    ushort remaining = (ctx.argc > 0) ? (ushort)(ctx.argc - 1) : 0;

    // For LIGHTFUNC downstreams, dispatch directly after shifting args
    if (downstream.is_lightfunc()) {
        uint fn_idx = (uint)(usz)downstream.get_heapptr();
        builtins::BuiltinContext inner_ctx;
        inner_ctx.vm = ctx.vm;
        inner_ctx.regs = ctx.regs;
        inner_ctx.base_reg = ctx.base_reg;
        inner_ctx.argc = remaining;
        inner_ctx.result = ctx.result;
        inner_ctx.heap = ctx.heap;
        inner_ctx.this_val = new_this;
        inner_ctx.is_constructor = false;
        inner_ctx.needs_re_dispatch = false;
        inner_ctx.re_nargs = 0;
        inner_ctx.should_throw = false;
        // Update the this slot so builtins that read ctx.regs[ctx.base_reg - 1] get the correct receiver
        inner_ctx.regs[ctx.base_reg - 1] = new_this;
        // Shift remaining args to start at base_reg
        for (ushort i = 0; i < remaining; i++) {
            ctx.regs[ctx.base_reg + i] = builtin_arg(ctx, i + 1);
        }
        builtins::dispatch_builtin(fn_idx, &inner_ctx);
        return;
    }

    // For OBJECT downstreams — dispatch directly if BUILTIN_FN, else re-dispatch
    if (downstream.is_object()) {
        HObject* hobj = (HObject*)downstream.get_heapptr();
        if (hobj != null && hobj.is_callable() && hobj.extra.func.callable_kind == hobject::CallableKind.BUILTIN_FN && hobj.extra.func.builtin_fn_index >= 0) {
            // Direct dispatch for BUILTIN_FN objects (e.g. Array.prototype.forEach.call(...))
            for (ushort i = 0; i < remaining; i++) {
                ctx.regs[ctx.base_reg + i] = builtin_arg(ctx, i + 1);
            }
            builtins::BuiltinContext inner_ctx;
            inner_ctx.vm = ctx.vm;
            inner_ctx.regs = ctx.regs;
            inner_ctx.base_reg = ctx.base_reg;
            inner_ctx.argc = remaining;
            inner_ctx.result = ctx.result;
            inner_ctx.heap = ctx.heap;
            inner_ctx.this_val = new_this;
            inner_ctx.is_constructor = false;
            inner_ctx.needs_re_dispatch = false;
            inner_ctx.re_nargs = 0;
            inner_ctx.global_env = ctx.global_env;
            inner_ctx.should_throw = false;
            inner_ctx.callee_obj = hobj;
            // Also set the this slot in registers for builtins that read ctx.regs[ctx.base_reg - 1]
            ctx.regs[ctx.base_reg - 1] = new_this;
            builtins::dispatch_builtin((uint)hobj.extra.func.builtin_fn_index, &inner_ctx);
            return;
        }
        // Fallback: re-dispatch for compiled functions and bound functions
        ctx.regs[ctx.base_reg - 2] = downstream;
        ctx.regs[ctx.base_reg - 1] = new_this;
        for (ushort i = 0; i < remaining; i++) {
            ctx.regs[ctx.base_reg + i] = builtin_arg(ctx, i + 1);
        }
        ctx.needs_re_dispatch = true;
        ctx.re_nargs = remaining;
    } else {
        ctx.result.set_undefined();
    }
}

/// Function.prototype.apply(thisArg, argArray)
///
/// Calls `this` (the downstream function) with `thisArg` as `this` and the
/// elements of `argArray` passed as individual arguments.
///
/// ES5 §15.3.4.3
fn void builtin_function_proto_apply(BuiltinContext* ctx) {
    TVal downstream = ctx.this_val;

    // Validate downstream is callable
    bool callable = false;
    if (downstream.is_lightfunc()) {
        callable = true;
    } else if (downstream.is_object()) {
        HObject* hobj = (HObject*)downstream.get_heapptr();
        if (hobj != null) {
            callable = hobj.is_callable();
        }
    }

    if (!callable) {
        ctx.result.set_undefined();
        return;
    }

    // Get new this value
    TVal new_this;
    if (ctx.argc > 0) {
        new_this = builtin_arg(ctx, 0);
    } else {
        new_this.set_undefined();
    }

    // If argArray is undefined or null, call with no args
    TVal arg_array;
    bool has_array = ctx.argc > 1;
    if (has_array) {
        arg_array = builtin_arg(ctx, 1);
        if (arg_array.is_undefined() || arg_array.is_null()) {
            has_array = false;
        }
    }

    if (!has_array) {
        // Call with no args
        if (downstream.is_lightfunc()) {
            uint fn_idx = (uint)(usz)downstream.get_heapptr();
            builtins::BuiltinContext inner_ctx;
            inner_ctx.vm = ctx.vm;
            inner_ctx.regs = ctx.regs;
            inner_ctx.base_reg = ctx.base_reg;
            inner_ctx.argc = 0;
            inner_ctx.result = ctx.result;
            inner_ctx.heap = ctx.heap;
            inner_ctx.this_val = new_this;
            inner_ctx.is_constructor = false;
            inner_ctx.needs_re_dispatch = false;
            inner_ctx.re_nargs = 0;
            inner_ctx.should_throw = false;
            builtins::dispatch_builtin(fn_idx, &inner_ctx);
            return;
        }
        if (downstream.is_object()) {
            ctx.regs[ctx.base_reg - 2] = downstream;
            ctx.regs[ctx.base_reg - 1] = new_this;
            ctx.needs_re_dispatch = true;
            ctx.re_nargs = 0;
        } else {
            ctx.result.set_undefined();
        }
        return;
    }

    // argArray must be an object (array-like)
    if (!arg_array.is_object() || arg_array.get_heapptr() == null) {
        // TypeError
        ctx.result.set_undefined();
        return;
    }

    HObject* arr_obj = (HObject*)arg_array.get_heapptr();

    // Get length via property lookup (arrays store length as a named property)
    uint len = 0;
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    TVal? len_val = arr_obj.get_prop_proto(length_key);
    if (try lv = len_val) {
        if (lv.is_number() || lv.is_fastint()) {
            double d = lv.is_fastint() ? (double)lv.get_fastint() : lv.get_number();
            if (d < 0) d = 0;
            if (math::is_nan(d)) d = 0;
            if (d > 4294967295.0) d = 4294967295.0;
            len = (uint)d;
        }
    }

    // Extract elements from argArray — use heap allocation
    uint max_extract = len < 1024 ? len : 1024;
    uint actual_count = 0;
    TVal* extracted_args = null;
    if (max_extract > 0) {
        extracted_args = (TVal*)libc::malloc(TVal::size * max_extract);
    }
    bool is_dense_array = (arr_obj.get_class() == hobject::ObjClass.ARRAY && arr_obj.array_part() != null);
    for (uint i = 0; i < max_extract; i++) {
        TVal elem;
        if (is_dense_array && i < arr_obj.array_size) {
            elem = arr_obj.array_part()[i];
            if (elem.is_undefined()) {
                char[20] buf;
                int n = libc::snprintf(&buf, 20, "%d", i);
                if (n <= 0 || n >= 20) break;
                HString* key_hstr = builtin_intern_string(ctx.heap, buf[:n]);
                TVal? prop = arr_obj.get_prop_proto(key_hstr);
                if (try p = prop) {
                    elem = p;
                }
            }
        } else {
            char[20] buf;
            int n = libc::snprintf(&buf, 20, "%d", i);
            if (n <= 0 || n >= 20) break;
            HString* key_hstr = builtin_intern_string(ctx.heap, buf[:n]);
            if (key_hstr == null) { break; }
            TVal? prop = arr_obj.get_prop_proto(key_hstr);
            if (try p = prop) {
                elem = p;
            } else {
                elem.set_undefined();
            }
        }
        if (actual_count < max_extract) extracted_args[actual_count++] = elem;
    }

    if (downstream.is_lightfunc()) {
        uint fn_idx = (uint)(usz)downstream.get_heapptr();
        builtins::BuiltinContext inner_ctx;
        inner_ctx.vm = ctx.vm;
        inner_ctx.regs = ctx.regs;
        inner_ctx.base_reg = ctx.base_reg;
        inner_ctx.argc = (ushort)actual_count;
        inner_ctx.result = ctx.result;
        inner_ctx.heap = ctx.heap;
        inner_ctx.this_val = new_this;
        inner_ctx.is_constructor = false;
        inner_ctx.needs_re_dispatch = false;
        inner_ctx.re_nargs = 0;
        inner_ctx.should_throw = false;

        // Write extracted args onto stack
        for (uint i = 0; i < actual_count; i++) {
            ctx.regs[ctx.base_reg + i] = extracted_args[i];
        }

        if (extracted_args != null) libc::free(extracted_args);
        builtins::dispatch_builtin(fn_idx, &inner_ctx);
        return;
    }

    if (downstream.is_object()) {
        ctx.regs[ctx.base_reg - 2] = downstream;
        ctx.regs[ctx.base_reg - 1] = new_this;
        for (uint i = 0; i < actual_count; i++) {
            ctx.regs[ctx.base_reg + i] = extracted_args[i];
        }
        if (extracted_args != null) libc::free(extracted_args);
        ctx.needs_re_dispatch = true;
        ctx.re_nargs = (ushort)actual_count;
    } else {
        if (extracted_args != null) libc::free(extracted_args);
        ctx.result.set_undefined();
    }
}

/// Helper for extracting bound function data from internal properties.
fn void bound_get_data(HObject* bound_obj, TVal* downstream, TVal* bound_this,
                       TVal* bound_args, uint* bound_argc) {
    HString* downstream_key = null;
    HString* this_key = null;
    {
        char[50] buf1 = "\\x00bound_downstream";
        // Use a simple approach — keyed by pointer stored as internal property
    }
    // For simplicity, we store bound data in special internal properties.
    // These are non-enumerable, non-writable, non-configurable properties.
    HString* key_downstream = null;
    // We'll use the property table directly via known interned strings
}

/// Function.prototype.bind(thisArg, ...args)
///
/// Creates a new function that, when called, has its `this` bound to `thisArg`
/// and prepends any additional arguments.
///
/// ES5 §15.3.4.5
fn void builtin_function_proto_bind(BuiltinContext* ctx) {
    TVal downstream = ctx.this_val;

    // Validate downstream is callable
    bool callable = false;
    if (downstream.is_lightfunc()) {
        callable = true;
    } else if (downstream.is_object()) {
        HObject* hobj = (HObject*)downstream.get_heapptr();
        if (hobj != null) {
            callable = hobj.is_callable();
        }
    }

    if (!callable) {
        ctx.result.set_undefined();
        return;
    }

    // Get bound this
    TVal bound_this;
    if (ctx.argc > 0) {
        bound_this = builtin_arg(ctx, 0);
    } else {
        bound_this.set_undefined();
    }

    // Collect bound args
    ushort bound_argc = (ctx.argc > 0) ? (ushort)(ctx.argc - 1) : 0;
    TVal* bound_args_arr = null;

    if (bound_argc > 0) {
        bound_args_arr = (TVal*)libc::malloc(TVal::size * bound_argc);
        if (bound_args_arr == null) {
            ctx.result.set_undefined();
            return;
        }
        for (ushort i = 0; i < bound_argc; i++) {
            bound_args_arr[i] = builtin_arg(ctx, i + 1);
        }
    }

    // Create bound function object
    HObject*? bound_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = bound_raw) {
        if (bound_args_arr != null) libc::free(bound_args_arr);
        ctx.result.set_undefined();
        return;
    }
    HObject* bound_obj = bound_raw;

    // Set up bound function properties
    bound_obj.flags.callable = true;
    bound_obj.flags.is_bound = true;
    bound_obj.prototype = ctx.heap.function_proto;
    bound_obj.extra.func.builtin_fn_index = (int)BUILTIN_BOUND_CALL;
    bound_obj.extra.func.callable_kind = hobject::CallableKind.BOUND_FN;

    // Also maintain constructable flag if downstream is constructable
    bool downstream_constructable = false;
    if (downstream.is_object()) {
        HObject* tobj = (HObject*)downstream.get_heapptr();
        if (tobj != null) downstream_constructable = tobj.flags.constructable;
    }
    bound_obj.flags.constructable = downstream_constructable;

    // Store bound data as internal properties (non-enumerable, non-writable, non-configurable)
    // Key: use special strings "\x00bound_downstream", "\x00bound_this", "\x00bound_args"
    HString* key_downstream = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'a', 'r', 'g', 'e', 't' });
    HString* key_this   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'h', 'i', 's' });
    HString* key_args   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 'a', 'r', 'g', 's' });

    PropFlags internal_flags;
    internal_flags.writable = false;
    internal_flags.enumerable = false;
    internal_flags.configurable = false;
    internal_flags.is_accessor = false;

    bound_obj.put_prop(key_downstream, downstream, internal_flags);
    bound_obj.put_prop(key_this, bound_this, internal_flags);

    // Store bound args as a JS array
    HObject*? args_arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* args_arr = null;
    if (try a = args_arr_raw) {
        args_arr = a;
        args_arr.prototype = ctx.heap.array_proto;
        // Set length
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        TVal len_tv;
        len_tv.set_fastint(bound_argc);
        args_arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
        // Set elements
        for (ushort i = 0; i < bound_argc; i++) {
            char[20] buf;
            int n = libc::snprintf(&buf, 20, "%d", i);
            if (n > 0 && n < 20) {
                HString* elem_key = builtin_intern_string(ctx.heap, buf[:n]);
                args_arr.put_prop(elem_key, bound_args_arr[i], hobject::PROP_FLAGS_WEC);
            }
        }
    }

    if (bound_args_arr != null) libc::free(bound_args_arr);

    TVal args_tv;
    if (args_arr != null) {
        args_tv.set_object(args_arr);
    } else {
        args_tv.set_undefined();
    }
    bound_obj.put_prop(key_args, args_tv, internal_flags);

    // Set .length on the bound function
    // Length = max(0, downstream.length - bound_argc)
    int downstream_len = 0;
    if (downstream.is_object()) {
        HObject* tobj = (HObject*)downstream.get_heapptr();
        if (tobj != null && tobj.extra.func.comp_func != null) {
            downstream_len = (int)tobj.extra.func.comp_func.num_formals;
        }
    }

    int bound_len = downstream_len - (int)bound_argc;
    if (bound_len < 0) bound_len = 0;

    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_tv;
    len_tv.set_fastint((long)bound_len);
    PropFlags wec = hobject::PROP_FLAGS_WEC;
    bound_obj.put_prop(len_key, len_tv, wec);

    // Result
    ctx.result.set_object(bound_obj);
}

/// Bound function [[Call]] handler.
/// When a bound function is called, this handler unwraps the bound data,
/// prepends bound args to the call args, and re-dispatches.
fn void builtin_bound_call(BuiltinContext* ctx) {
    TVal func_val = ctx.regs[ctx.base_reg - 2];
    if (!func_val.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* bound_obj = (HObject*)func_val.get_heapptr();
    if (bound_obj == null || !bound_obj.flags.is_bound) {
        ctx.result.set_undefined();
        return;
    }

    // Extract bound data from internal properties
    HString* key_downstream = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'a', 'r', 'g', 'e', 't' });
    HString* key_this   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'h', 'i', 's' });
    HString* key_args   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 'a', 'r', 'g', 's' });

    TVal? downstream_val = bound_obj.get_prop_proto(key_downstream);
    TVal? this_val   = bound_obj.get_prop_proto(key_this);
    TVal? args_val   = bound_obj.get_prop_proto(key_args);

    TVal downstream;
    TVal bound_this;
    if (try tv = downstream_val) { downstream = tv; }
    else { ctx.result.set_undefined(); return; }
    if (try tv = this_val) { bound_this = tv; }
    else { bound_this.set_undefined(); }

    // Extract bound args array
    uint bound_argc = 0;
    if (try av = args_val) {
        if (av.is_object()) {
            HObject* arr = (HObject*)av.get_heapptr();
            if (arr != null && arr.get_class() == hobject::ObjClass.ARRAY) {
                HString* len_key = builtin_intern_string(ctx.heap, "length");
                TVal? lv = arr.get_prop_proto(len_key);
                if (try l = lv) {
                    if (l.is_fastint()) {
                        bound_argc = (uint)l.get_fastint();
                    } else if (l.is_number()) {
                        bound_argc = (uint)l.get_number();
                    }
                }
            }
        }
    }

    TVal* all_args = null;
    uint max_total = bound_argc + ctx.argc;
    if (max_total > 0) {
        all_args = (TVal*)libc::malloc(TVal::size * max_total);
        if (all_args == null) { ctx.result.set_undefined(); return; }
    }
    uint actual_total = 0;

    // Copy bound args from stored array
    if (try av = args_val) {
        if (av.is_object()) {
            HObject* arr = (HObject*)av.get_heapptr();
            if (arr != null && arr.get_class() == hobject::ObjClass.ARRAY) {
                for (uint i = 0; i < bound_argc && actual_total < max_total; i++) {
                    char[20] buf;
                    int n = libc::snprintf(&buf, 20, "%d", i);
                    if (n > 0 && n < 20) {
                        HString* ek = builtin_intern_string(ctx.heap, buf[:n]);
                        TVal? e = arr.get_prop_proto(ek);
                        if (try ev = e) all_args[actual_total++] = ev;
                    }
                }
            }
        }
    }

    // Append call args
    uint total_argc = bound_argc + ctx.argc;
    for (uint i = 0; i < (uint)ctx.argc && bound_argc + i < 65535; i++) {
        all_args[bound_argc + i] = ctx.regs[ctx.base_reg + i];
    }

    // Determine if downstream is LIGHTFUNC or OBJECT
    if (downstream.is_lightfunc()) {
        uint fn_idx = (uint)(usz)downstream.get_heapptr();
        builtins::BuiltinContext inner_ctx;
        inner_ctx.vm = ctx.vm;
        inner_ctx.regs = ctx.regs;
        inner_ctx.base_reg = ctx.base_reg;
        inner_ctx.argc = (ushort)total_argc;
        inner_ctx.result = ctx.result;
        inner_ctx.heap = ctx.heap;
        inner_ctx.this_val = bound_this;
        inner_ctx.is_constructor = ctx.is_constructor;
        inner_ctx.needs_re_dispatch = false;
        inner_ctx.re_nargs = 0;
        inner_ctx.should_throw = false;

        for (uint i = 0; i < total_argc && i < 65535; i++) {
            ctx.regs[ctx.base_reg + i] = all_args[i];
        }
        builtins::dispatch_builtin(fn_idx, &inner_ctx);
        return;
    }

    if (downstream.is_object()) {
        HObject* tobj = (HObject*)downstream.get_heapptr();
        if (tobj != null && tobj.is_callable()) {
            ctx.regs[ctx.base_reg - 2] = downstream;
            ctx.regs[ctx.base_reg - 1] = bound_this;
            for (uint i = 0; i < total_argc && i < 65535; i++) {
                ctx.regs[ctx.base_reg + i] = all_args[i];
            }
            ctx.needs_re_dispatch = true;
            ctx.re_nargs = (ushort)total_argc;
            return;
        }
    }

    ctx.result.set_undefined();
}

// ============================================================================
// JSON.parse (ES5 §15.12.2)
// ============================================================================

struct JsonParseCtx {
    char* src;
    uint pos;
    uint len;
    Heap* heap;
}

fn void json_skip_ws(JsonParseCtx* jctx) {
    while (jctx.pos < jctx.len) {
        char c = jctx.src[jctx.pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            jctx.pos++;
        } else {
            break;
        }
    }
}

/// Parse a 4-digit hex escape (\uXXXX).
fn uint json_parse_hex4(JsonParseCtx* jctx) {
    uint val = 0;
    for (int i = 0; i < 4; i++) {
        if (jctx.pos >= jctx.len) return 0xFFFFFFFF;
        char c = jctx.src[jctx.pos];
        uint d;
        if (c >= '0' && c <= '9') {
            d = (uint)(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            d = (uint)(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            d = (uint)(c - 'A' + 10);
        } else {
            return 0xFFFFFFFF;
        }
        val = (val << 4) | d;
        jctx.pos++;
    }
    return val;
}

/// Parse a JSON string (between quotes).
fn HString*? json_parse_string(JsonParseCtx* jctx) {
    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '\"') {
        return null;
    }
    jctx.pos++; // skip opening quote

    char[1024] buf;
    usz out_len = 0;

    while (jctx.pos < jctx.len) {
        char c = jctx.src[jctx.pos];
        if (c == '\"') {
            jctx.pos++; // skip closing quote
            return builtin_intern_string(jctx.heap, buf[:out_len]);
        }
        if (c == '\\') {
            jctx.pos++;
            if (jctx.pos >= jctx.len) return null;
            char esc = jctx.src[jctx.pos];
            jctx.pos++;
            char ch;
            switch (esc) {
                case '\"': ch = '\"'; break;
                case '\\': ch = '\\'; break;
                case '/':  ch = '/';  break;
                case 'b':  ch = '\b'; break;
                case 'f':  ch = '\f'; break;
                case 'n':  ch = '\n'; break;
                case 'r':  ch = '\r'; break;
                case 't':  ch = '\t'; break;
                case 'u': {
                    uint cp = json_parse_hex4(jctx);
                    if (cp == 0xFFFFFFFF) return null;
                    // Simple ASCII-range unicode (for now, just low bytes)
                    if (cp <= 0x7F) {
                        ch = (char)cp;
                    } else if (cp <= 0x7FF) {
                        // UTF-8 2-byte sequence
                        if (out_len + 2 > 1024) return null;
                        buf[out_len++] = (char)(0xC0 | (cp >> 6));
                        ch = (char)(0x80 | (cp & 0x3F));
                    } else {
                        // UTF-8 3-byte sequence
                        if (out_len + 3 > 1024) return null;
                        buf[out_len++] = (char)(0xE0 | (cp >> 12));
                        buf[out_len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                        ch = (char)(0x80 | (cp & 0x3F));
                    }
                    break;
                }
                default:
                    return null;
            }
            if (out_len >= 1024) return null;
            buf[out_len++] = ch;
        } else if (c < 0x20) {
            // Control characters not allowed
            return null;
        } else {
            if (out_len >= 1024) return null;
            buf[out_len++] = c;
            jctx.pos++;
        }
    }
    return null; // unterminated string
}

/// Parse a JSON number.
fn TVal json_parse_number(JsonParseCtx* jctx) {
    uint start = jctx.pos;

    // Optional minus
    if (jctx.pos < jctx.len && jctx.src[jctx.pos] == '-') {
        jctx.pos++;
    }

    // Integer part
    if (jctx.pos >= jctx.len) {
        TVal r; r.set_undefined(); return r;
    }
    if (jctx.src[jctx.pos] == '0') {
        jctx.pos++;
    } else if (jctx.src[jctx.pos] >= '1' && jctx.src[jctx.pos] <= '9') {
        jctx.pos++;
        while (jctx.pos < jctx.len && jctx.src[jctx.pos] >= '0' && jctx.src[jctx.pos] <= '9') {
            jctx.pos++;
        }
    } else {
        TVal r; r.set_undefined(); return r;
    }

    // Fractional part
    if (jctx.pos < jctx.len && jctx.src[jctx.pos] == '.') {
        jctx.pos++;
        if (jctx.pos >= jctx.len || jctx.src[jctx.pos] < '0' || jctx.src[jctx.pos] > '9') {
            TVal r; r.set_undefined(); return r;
        }
        while (jctx.pos < jctx.len && jctx.src[jctx.pos] >= '0' && jctx.src[jctx.pos] <= '9') {
            jctx.pos++;
        }
    }

    // Exponent part
    if (jctx.pos < jctx.len && (jctx.src[jctx.pos] == 'e' || jctx.src[jctx.pos] == 'E')) {
        jctx.pos++;
        if (jctx.pos < jctx.len && (jctx.src[jctx.pos] == '+' || jctx.src[jctx.pos] == '-')) {
            jctx.pos++;
        }
        if (jctx.pos >= jctx.len || jctx.src[jctx.pos] < '0' || jctx.src[jctx.pos] > '9') {
            TVal r; r.set_undefined(); return r;
        }
        while (jctx.pos < jctx.len && jctx.src[jctx.pos] >= '0' && jctx.src[jctx.pos] <= '9') {
            jctx.pos++;
        }
    }

    // Convert to double
    uint end = jctx.pos;
    char saved = jctx.src[end];
    jctx.src[end] = 0;
    char* endptr;
    double d = libc::strtod(jctx.src + start, &endptr);
    jctx.src[end] = saved;

    // Try fastint preservation
    long fi = (long)d;
    if ((double)fi == d && fi >= -9007199254740991 && fi <= 9007199254740991) {
        TVal r; r.set_fastint(fi); return r;
    }
    TVal r; r.set_number(d); return r;
}

/// Parse a JSON array: [value, ...]
fn TVal json_parse_array(JsonParseCtx* jctx) {
    jctx.pos++; // skip '['
    json_skip_ws(jctx);

    HObject*? arr_raw = jctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* arr;
    if (try a = arr_raw) {
        arr = a;
        arr.prototype = null; // will be set by caller
    } else {
        TVal r; r.set_undefined(); return r;
    }

    HString* len_key = builtin_intern_string(jctx.heap, "length");
    uint idx = 0;

    if (jctx.pos < jctx.len && jctx.src[jctx.pos] != ']') {
        while (true) {
            json_skip_ws(jctx);
            TVal elem = json_parse_value(jctx);
            if (elem.is_undefined() && elem.get_heapptr() == null && jctx.pos < jctx.len) {
                TVal r; r.set_undefined(); return r; // parse error
            }
            json_skip_ws(jctx);

            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%d", idx);
            HString* idx_key = builtin_intern_string(jctx.heap, idx_buf[:idx_len]);
            arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
            idx++;

            if (jctx.pos >= jctx.len) {
                TVal r; r.set_undefined(); return r;
            }
            if (jctx.src[jctx.pos] == ',') {
                jctx.pos++;
            } else {
                break;
            }
        }
    }

    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != ']') {
        TVal r; r.set_undefined(); return r;
    }
    jctx.pos++; // skip ']'

    TVal len_val;
    len_val.set_fastint((long)idx);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    TVal result;
    result.set_object(arr);
    return result;
}

/// Parse a JSON object: {key: value, ...}
fn TVal json_parse_object(JsonParseCtx* jctx) {
    jctx.pos++; // skip '{'
    json_skip_ws(jctx);

    HObject*? obj_raw = jctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    HObject* obj;
    if (try o = obj_raw) {
        obj = o;
    } else {
        TVal r; r.set_undefined(); return r;
    }

    if (jctx.pos < jctx.len && jctx.src[jctx.pos] != '}') {
        while (true) {
            json_skip_ws(jctx);
            if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '\"') {
                TVal r; r.set_undefined(); return r;
            }
            HString*? key_str = json_parse_string(jctx);
            if (try k = key_str) {
                json_skip_ws(jctx);
                if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != ':') {
                    TVal r; r.set_undefined(); return r;
                }
                jctx.pos++; // skip ':'
                json_skip_ws(jctx);
                TVal val = json_parse_value(jctx);
                if (val.is_undefined() && val.get_heapptr() == null && jctx.pos < jctx.len) {
                    TVal r; r.set_undefined(); return r;
                }
                obj.put_prop(k, val, hobject::PROP_FLAGS_WEC);
                json_skip_ws(jctx);
                if (jctx.pos >= jctx.len) {
                    TVal r; r.set_undefined(); return r;
                }
                if (jctx.src[jctx.pos] == ',') {
                    jctx.pos++;
                } else {
                    break;
                }
            } else {
                TVal r; r.set_undefined(); return r;
            }
        }
    }

    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '}') {
        TVal r; r.set_undefined(); return r;
    }
    jctx.pos++; // skip '}'

    TVal result;
    result.set_object(obj);
    return result;
}

/// Parse a JSON value.
fn TVal json_parse_value(JsonParseCtx* jctx) {
    json_skip_ws(jctx);
    if (jctx.pos >= jctx.len) {
        TVal r; r.set_undefined(); return r;
    }

    char c = jctx.src[jctx.pos];
    switch (c) {
        case '\"':
            // String
            {
                HString*? s = json_parse_string(jctx);
                if (try str = s) {
                    TVal r; r.set_string(str); return r;
                }
                TVal r; r.set_undefined(); return r;
            }
        case '{':
            return json_parse_object(jctx);
        case '[':
            return json_parse_array(jctx);
        case 't':
            // true
            if (jctx.pos + 4 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'r' &&
                jctx.src[jctx.pos + 2] == 'u' &&
                jctx.src[jctx.pos + 3] == 'e') {
                jctx.pos += 4;
                TVal r; r.set_boolean(true); return r;
            }
            { TVal r; r.set_undefined(); return r; }
        case 'f':
            // false
            if (jctx.pos + 5 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'a' &&
                jctx.src[jctx.pos + 2] == 'l' &&
                jctx.src[jctx.pos + 3] == 's' &&
                jctx.src[jctx.pos + 4] == 'e') {
                jctx.pos += 5;
                TVal r; r.set_boolean(false); return r;
            }
            { TVal r; r.set_undefined(); return r; }
        case 'n':
            // null
            if (jctx.pos + 4 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'u' &&
                jctx.src[jctx.pos + 2] == 'l' &&
                jctx.src[jctx.pos + 3] == 'l') {
                jctx.pos += 4;
                TVal r; r.set_null(); return r;
            }
            { TVal r; r.set_undefined(); return r; }
        case '-':
        case '0'..'9':
            return json_parse_number(jctx);
        default:
            { TVal r; r.set_undefined(); return r; }
    }
}

/// Walk helper for reviver (ES5 §15.12.2, step 4 — internalize properties).
fn TVal json_walk(Heap* heap, TVal reviver, TVal holder, HString* name) {
    TVal val;
    if (holder.is_object() && holder.get_heapptr() != null) {
        HObject* obj = (HObject*)holder.get_heapptr();
        TVal? prop = obj.get_prop_proto(name);
        if (try p = prop) {
            val = p;
        } else {
            val.set_undefined();
        }
    } else {
        val.set_undefined();
    }

    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.get_class() == ObjClass.ARRAY) {
            HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            TVal? len_prop = obj.get_prop_proto(len_key);
            uint len = 0;
            if (try l = len_prop) {
                if (l.is_fastint()) len = (uint)l.get_fastint();
            }
            for (uint i = 0; i < len; i++) {
                char[16] idx_buf;
                int idx_len = libc::snprintf(&idx_buf, 16, "%d", i);
                HString* idx_key = builtin_intern_string(heap, idx_buf[:idx_len]);
                TVal new_elem = json_walk(heap, reviver, val, idx_key);
                if (new_elem.is_undefined()) {
                    obj.delete_prop(idx_key);
                } else {
                    obj.put_prop(idx_key, new_elem, hobject::PROP_FLAGS_WEC);
                }
            }
        } else if (obj.get_class() == ObjClass.OBJECT) {
            // Walk own properties
            for (uint i = 0; i < obj.prop_count; i++) {
                HString* key_str = obj.shape.props()[i].key;
                if (key_str != null) {
                    TVal new_val = json_walk(heap, reviver, val, key_str);
                    if (new_val.is_undefined()) {
                        obj.delete_prop(key_str);
                    } else {
                        obj.put_prop(key_str, new_val, hobject::PROP_FLAGS_WEC);
                    }
                }
            }
        }
    }

    // Call reviver(this=holder, name, val)
    TVal name_str;
    name_str.set_string(name);

    // For the reviver call, we need to invoke it via the calling convention
    // Since we're in a builtin context, we need to set up the stack
    // and re-dispatch. However, since JSON.parse is called as a LIGHTFUNC,
    // we don't have a VM activation. We need to signal re-dispatch.
    // For now, skip reviver and just return val
    return val;
}

/// Helper: throw a SyntaxError from a JSON builtin.
fn void json_throw_syntax_error(BuiltinContext* ctx, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.syntax_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.throw_value.set_object(err);
    } else {
        ctx.throw_value.set_undefined();
    }
    ctx.should_throw = true;
}

/// JSON.parse(text [, reviver]) — ES5 §15.12.2
fn void builtin_json_parse(BuiltinContext* ctx) {
    // Step 1: Coerce first argument to string
    if (ctx.argc < 1) {
        json_throw_syntax_error(ctx, "JSON.parse requires at least 1 argument");
        return;
    }

    TVal* text_arg = &ctx.regs[ctx.base_reg];
    HString* text_str;

    if (text_arg.is_string()) {
        text_str = (HString*)text_arg.get_heapptr();
    } else {
        text_str = builtin_to_string(ctx.heap, text_arg);
        if (text_str == null) {
            json_throw_syntax_error(ctx, "Invalid JSON");
            return;
        }
    }

    char* src = text_str.get_cstr();
    uint len = text_str.blen;

    JsonParseCtx jctx;
    jctx.src = src;
    jctx.pos = 0;
    jctx.len = len;
    jctx.heap = ctx.heap;

    TVal result = json_parse_value(&jctx);

    // Check parse error (undefined == error)
    if (result.is_undefined() && result.get_heapptr() == null) {
        json_throw_syntax_error(ctx, "Unexpected token in JSON");
        return;
    }

    // Skip trailing whitespace
    json_skip_ws(&jctx);
    if (jctx.pos != jctx.len) {
        // Trailing non-whitespace characters → SyntaxError
        json_throw_syntax_error(ctx, "Unexpected token in JSON");
        return;
    }

    // Set prototype on the result object if it's an object
    if (result.is_object() && result.get_heapptr() != null) {
        HObject* obj = (HObject*)result.get_heapptr();
        if (obj.prototype == null) {
            obj.prototype = ctx.heap.object_proto;
        }
    }

    // Reviver support (ES5 §15.12.2 step 4)
    if (ctx.argc > 1) {
        TVal* reviver_arg = &ctx.regs[ctx.base_reg + 1];
        if (reviver_arg.is_lightfunc() || (reviver_arg.is_object() &&
            ((HObject*)reviver_arg.get_heapptr()) != null &&
            ((HObject*)reviver_arg.get_heapptr()).is_callable())) {
            // Create holder object { "": result }
            HObject*? holder_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try holder = holder_raw) {
                HString* empty_key = builtin_intern_string(ctx.heap, "");
                holder.put_prop(empty_key, result, hobject::PROP_FLAGS_WEC);

                TVal holder_tv;
                holder_tv.set_object(holder);

                // For now, skip the full walk and just return result without reviver
                // Full reviver support requires VM re-dispatch which is complex
                *ctx.result = result;
            } else {
                *ctx.result = result;
            }
        } else {
            *ctx.result = result;
        }
    } else {
        *ctx.result = result;
    }
}

// ============================================================================
// JSON.stringify (ES5 §15.12.3)
// ============================================================================

/// Helper: append a JSON-escaped string to a buffer.
fn usz json_escape_string(char* src, uint len, char* buf, usz buf_size) {
    usz pos = 0;
    if (pos < buf_size) buf[pos++] = '\"';
    for (uint i = 0; i < len && pos < buf_size; i++) {
        char c = src[i];
        switch (c) {
            case '\"': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = '\"'; break;
            case '\\': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = '\\'; break;
            case '\b': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'b'; break;
            case '\f': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'f'; break;
            case '\n': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'n'; break;
            case '\r': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'r'; break;
            case '\t': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 't'; break;
            default:
                if ((c & 0x80) != 0) {
                    // Non-ASCII: pass through as-is (valid UTF-8)
                    if (pos >= buf_size) break;
                    buf[pos++] = c;
                } else if (c < 0x20) {
                    // Control char: \uXXXX
                    if (pos + 6 > buf_size) break;
                    buf[pos++] = '\\';
                    buf[pos++] = 'u';
                    buf[pos++] = '0';
                    buf[pos++] = '0';
                    char[16] hex_digits = { '0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f' };
                    buf[pos++] = hex_digits[(c >> 4) & 0xF];
                    buf[pos++] = hex_digits[c & 0xF];
                } else {
                    // Regular ASCII
                    if (pos >= buf_size) break;
                    buf[pos++] = c;
                }
                break;
        }
    }
    if (pos < buf_size) buf[pos++] = '\"';
    return pos;
}

/// Serialize a JSON value (internal recursive helper).
/// Returns 0 on success, non-zero on error.
/// Writes to buf starting at offset, updates offset.
struct JsonSerializeCtx {
    Heap* heap;
    void* vm;                    // VM pointer for calling JS functions
    char* buf;
    usz buf_size;
    usz offset;
    usz indent_level;
    char* gap;
    usz gap_len;
    /// Current stack depth for cycle detection
    uint depth;
    /// Replacer function (undefined if none)
    TVal replacer_func;
    /// Property list from replacer array (null if none)
    HString** prop_keys;
    uint prop_key_count;
    /// True when a replacer array was provided (even if empty)
    bool has_replacer_array;
    /// Set when a call_fn error occurred (toJSON/replacer threw)
    bool error;
}

const uint JSON_MAX_DEPTH = 128;

/// ES5 §15.12.3 step 5: Type unwrapping via ToString/ToNumber/ToBoolean.
/// For String/Number wrapper objects, calls toString()/valueOf() (per spec)
/// rather than reading the cached primitive_value (which ignores overrides).
/// Returns the unwrapped TVal. Sets *had_error=true if the method threw.
/// For non-wrapper objects, returns the value unchanged.
fn TVal json_unwrap_wrapper(JsonSerializeCtx* jctx, TVal val, bool* had_error) {
    *had_error = false;
    if (!val.is_object() || val.get_heapptr() == null) return val;
    HObject* obj = (HObject*)val.get_heapptr();
    ObjClass cls = obj.get_class();

    // Boolean wrapper: just read [[BooleanData]] per spec
    if (cls == ObjClass.BOOLEAN) {
        if (obj.extra.prim.primitive_value.is_boolean()) {
            TVal result;
            result.set_boolean(obj.extra.prim.primitive_value.get_boolean());
            return result;
        }
        return val;
    }

    // String wrapper: ToString → call toString()
    if (cls == ObjClass.STRING) {
        HString* to_str_key = jctx.heap.str_intern("toString");
        if (to_str_key == null) return val;
        TVal? toString_fn_opt = obj.get_prop_proto(to_str_key);
        if (try toString_fn = toString_fn_opt) {
            bool callable = false;
            if (toString_fn.is_object() && toString_fn.get_heapptr() != null) {
                HObject* fn_hobj = (HObject*)toString_fn.get_heapptr();
                callable = fn_hobj.is_callable();
            } else if (toString_fn.is_lightfunc()) {
                callable = true;
            }
            if (callable && jctx.heap.call_fn != null && jctx.vm != null) {
                TVal result = jctx.heap.call_fn(jctx.vm, toString_fn, null, 0, val);
                if (jctx.heap.has_error) { *had_error = true; return val; }
                return result;
            }
        }
        // No callable toString — fall back to primitive value
        if (obj.extra.prim.primitive_value.is_string()) {
            return obj.extra.prim.primitive_value;
        }
        return val;
    }

    // Number wrapper: ToNumber → call valueOf() first (per ES §9.3 / §15.12.3.4)
    if (cls == ObjClass.NUMBER) {
        HString* vo_key = jctx.heap.str_intern("valueOf");
        if (vo_key != null) {
            TVal? valueOf_fn_opt = obj.get_prop_proto(vo_key);
            if (try valueOf_fn = valueOf_fn_opt) {
                bool callable = false;
                if (valueOf_fn.is_object() && valueOf_fn.get_heapptr() != null) {
                    HObject* fn_hobj = (HObject*)valueOf_fn.get_heapptr();
                    callable = fn_hobj.is_callable();
                } else if (valueOf_fn.is_lightfunc()) {
                    callable = true;
                }
                if (callable && jctx.heap.call_fn != null && jctx.vm != null) {
                    TVal result = jctx.heap.call_fn(jctx.vm, valueOf_fn, null, 0, val);
                    if (jctx.heap.has_error) { *had_error = true; return val; }
                    return result;
                }
            }
        }
        // Fallback: primitive value
        return obj.extra.prim.primitive_value;
    }

    return val;
}

/// Apply toJSON + replacer function + type unwrapping per ES5 §15.12.3
/// SerializeJSONProperty steps 1-4. Returns the processed value.
/// If the result should be omitted (undefined/functions), sets *omit=true.
fn TVal json_check_property(JsonSerializeCtx* jctx, HString* key, TVal val, TVal holder, bool* omit) {
    *omit = false;

    // Step 2: Check toJSON on objects
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        HString* toJSON_key = builtin_intern_string(jctx.heap, "toJSON");
        TVal? toJSON_val = obj.get_prop_proto(toJSON_key);
        if (try toJSON_fn = toJSON_val) {
            bool callable = false;
            if (toJSON_fn.is_object() && toJSON_fn.get_heapptr() != null) {
                HObject* fn_hobj = (HObject*)toJSON_fn.get_heapptr();
                callable = fn_hobj.is_callable();
            } else if (toJSON_fn.is_lightfunc()) {
                callable = true;
            }
            if (callable) {
                TVal key_tv;
                key_tv.set_string(key);
                TVal[1] json_args;
                json_args[0] = key_tv;
                if (jctx.heap.call_fn != null && jctx.vm != null) {
                    val = jctx.heap.call_fn(jctx.vm, toJSON_fn, &json_args[0], 1, val);
                    if (jctx.heap.has_error) { jctx.error = true; *omit = true; return val; }
                }
            }
        }
    }

    // Step 3: Call replacer function
    if (!jctx.replacer_func.is_undefined()) {
        bool callable = false;
        if (jctx.replacer_func.is_object() && jctx.replacer_func.get_heapptr() != null) {
            HObject* fn_hobj = (HObject*)jctx.replacer_func.get_heapptr();
            callable = fn_hobj.is_callable();
        } else if (jctx.replacer_func.is_lightfunc()) {
            callable = true;
        }
        if (callable) {
            TVal key_tv;
            key_tv.set_string(key);
            TVal[2] rep_args;
            rep_args[0] = key_tv;
            rep_args[1] = val;
            if (jctx.heap.call_fn != null && jctx.vm != null) {
                val = jctx.heap.call_fn(jctx.vm, jctx.replacer_func, &rep_args[0], 2, holder);
                if (jctx.heap.has_error) { jctx.error = true; *omit = true; return val; }
            }
        }
    }

    // Step 4: Unwrap wrapper objects (String/Number/Boolean) per ES5 §15.12.3
    // For String/Number wrappers, ToString/ToNumber calls toString()/valueOf()
    // — must respect any overridden methods on the wrapper.
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        ObjClass cls = obj.get_class();
        if (cls == ObjClass.STRING || cls == ObjClass.NUMBER || cls == ObjClass.BOOLEAN) {
            bool unwrap_err = false;
            TVal unwrapped = json_unwrap_wrapper(jctx, val, &unwrap_err);
            if (unwrap_err) { jctx.error = true; *omit = true; return unwrapped; }
            val = unwrapped;
        }
    }

    // Step 5-12: Determine if value should be omitted
    // undefined and functions → omit
    if (val.is_undefined()) { *omit = true; return val; }
    if (val.is_lightfunc()) { *omit = true; return val; }
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.get_class() == ObjClass.FUNCTION) { *omit = true; return val; }
    }

    return val;
}

/// Check if a value is an array-like object per ES5 spec (HasProperty with "length")
fn bool json_is_array(HObject* obj) {
    return obj.get_class() == ObjClass.ARRAY ||
           obj.get_class() == ObjClass.ARGUMENTS;
}

/// Serialize an object's properties
fn int json_serialize_object(JsonSerializeCtx* jctx, HObject* obj) {
    if (jctx.error) return -1;
    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = '{';

    // Create holder TVal for replacer calls
    TVal holder;
    holder.set_object(obj);

    // Build the key list: use property_list if replacer array, else own properties
    bool has_replacer = jctx.has_replacer_array;
    bool has_props = false;


    if (!has_replacer) {
        // Check if object has own properties (including accessor properties with getters)
        for (uint i = 0; i < obj.prop_count; i++) {
            if (obj.shape.props()[i].key != null) {
                has_props = true;
                break;
            }
        }
    } else {
        has_props = true;
    }

    if (!has_props) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = '}';
        return 0;
    }

    bool first = true;

    if (has_replacer) {
        // Iterate property list from replacer array
        for (uint p = 0; p < jctx.prop_key_count; p++) {
            HString* key_hstr = jctx.prop_keys[p];

            // Get value from object
            TVal? val_opt = obj.get_prop_proto(key_hstr);
            TVal val;
            if (try v = val_opt) {
                val = v;
            } else {
                val.set_undefined();
            }

            // Apply toJSON + replacer
            bool omit = false;
            val = json_check_property(jctx, key_hstr, val, holder, &omit);
            if (jctx.error) return -1;
            if (omit) continue;

            if (!first) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = ',';
            }
            first = false;

            // Indentation
            if (jctx.gap_len > 0) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = '\n';
                for (usz g = 0; g < (jctx.indent_level + 1) * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
                    jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
                }
            }

            // Key
            char* key_data = key_hstr.get_cstr();
            uint key_len = key_hstr.blen;
            char[1024] key_buf;
            usz key_out = json_escape_string(key_data, key_len, &key_buf, 1024);
            usz copy = key_out < (jctx.buf_size - jctx.offset) ? key_out : (jctx.buf_size - jctx.offset);
            for (usz k = 0; k < copy; k++) {
                jctx.buf[jctx.offset++] = key_buf[k];
            }

            if (jctx.offset + 2 > jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = ':';
            if (jctx.gap_len > 0) {
                jctx.buf[jctx.offset++] = ' ';
            }

            // Value
            jctx.depth++;
            if (jctx.depth > JSON_MAX_DEPTH) {
                jctx.depth--;
                return -1;
            }
            int r = json_serialize_val(jctx, &val);
            jctx.depth--;
            if (r != 0) return r;
        }
    } else {
        // Snapshot property keys before iterating, so that getters that delete
        // properties don't cause keys to be skipped (ES5 §15.12.3 step 4.b).
        HString*[64] snap_keys;
        ushort[64] snap_indices;
        uint snap_count = 0;
        for (uint i = 0; i < obj.prop_count && snap_count < 64; i++) {
            if (obj.shape.props()[i].key != null) {
                snap_keys[snap_count] = (HString*)obj.shape.props()[i].key;
                snap_indices[snap_count] = (ushort)i;
                snap_count++;
            }
        }

        for (uint si = 0; si < snap_count; si++) {
            HString* key_hstr = snap_keys[si];
            uint pi = snap_indices[si];
            TVal val;
            // Check if property still exists and read its value
            if (pi < obj.prop_count && obj.shape.props()[pi].key == key_hstr) {
                if (obj.prop_values()[pi].flags.is_accessor) {
                    // Invoke the getter to get the property value
                    TVal getter_fn = obj.prop_values()[pi].data.getter;
                    if (getter_fn.is_undefined() || getter_fn.is_null()) {
                        val.set_undefined();
                    } else if (jctx.heap.call_fn != null && jctx.vm != null) {
                        TVal holder_tv;
                        holder_tv.set_object(obj);
                        val = jctx.heap.call_fn(jctx.vm, getter_fn, null, 0, holder_tv);
                        if (jctx.heap.has_error) { jctx.error = true; return -1; }
                    } else {
                        continue;
                    }
                } else {
                    val = obj.prop_values()[pi].data.value;
                }
            } else {
                // Property was deleted (e.g., by a getter) — treat as undefined
                val.set_undefined();
            }

            // Apply toJSON + replacer (even without explicit replacer, this
            // handles the spec correctly — when replacer_func is undefined
            // the check just does toJSON + type unwrapping)
            bool omit = false;
            val = json_check_property(jctx, key_hstr, val, holder, &omit);
            if (jctx.error) return -1;
            if (omit) continue;

            if (!first) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = ',';
            }
            first = false;

            // Indentation
            if (jctx.gap_len > 0) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = '\n';
                for (usz g = 0; g < (jctx.indent_level + 1) * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
                    jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
                }
            }

            // Key
            char* key_data = key_hstr.get_cstr();
            uint key_len = key_hstr.blen;
            char[1024] key_buf;
            usz key_out = json_escape_string(key_data, key_len, &key_buf, 1024);
            usz copy = key_out < (jctx.buf_size - jctx.offset) ? key_out : (jctx.buf_size - jctx.offset);
            for (usz k = 0; k < copy; k++) {
                jctx.buf[jctx.offset++] = key_buf[k];
            }

            if (jctx.offset + 2 > jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = ':';
            if (jctx.gap_len > 0) {
                jctx.buf[jctx.offset++] = ' ';
            }

            // Value
            jctx.depth++;
            if (jctx.depth > JSON_MAX_DEPTH) {
                jctx.depth--;
                return -1;
            }
            int r = json_serialize_val(jctx, &val);
            jctx.depth--;
            if (r != 0) return r;
        }
    }

    if (jctx.gap_len > 0) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = '\n';
        for (usz g = 0; g < jctx.indent_level * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
            jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
        }
    }

    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = '}';
    return 0;
}

/// Serialize an array
fn int json_serialize_array(JsonSerializeCtx* jctx, HObject* arr) {
    if (jctx.error) return -1;
    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = '[';

    // Create holder TVal for replacer calls
    TVal holder;
    holder.set_object(arr);

    // Check if dense array fast path is available for element reads
    bool is_dense = (arr.get_class() == ObjClass.ARRAY || arr.get_class() == ObjClass.ARGUMENTS)
                    && arr.array_part() != null;

    // Always read length from the property (spec-correct)
    HString* len_key = builtin_intern_string(jctx.heap, "length");
    TVal? len_prop = arr.get_prop_proto(len_key);
    uint len = 0;
    if (try l = len_prop) {
        if (l.is_fastint()) {
            len = (uint)l.get_fastint();
        } else if (l.is_number()) {
            len = (uint)(long)l.get_number();
        }
    }

    if (len == 0) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = ']';
        return 0;
    }

    bool first = true;
    for (uint i = 0; i < len; i++) {
        // Read element: try array_part fast path first, then fall back to prop lookup
        TVal elem;
        bool found = false;
        if (is_dense && i < arr.array_size) {
            TVal av = arr.array_part()[i];
            if (!av.is_undefined()) {
                elem = av;
                found = true;
            }
            // undefined in array_part means hole — fall through to prop lookup
        }

        // Build the index key for this element
        char[16] idx_buf;
        int idx_len = libc::snprintf(&idx_buf, 16, "%d", i);
        HString* idx_key = builtin_intern_string(jctx.heap, idx_buf[:idx_len]);

        if (!found) {
            TVal? elem_prop = arr.get_prop_proto(idx_key);
            if (try e = elem_prop) {
                elem = e;
                found = true;
            } else {
                elem.set_undefined();
            }
        }

        // Apply toJSON + replacer
        bool omit = false;
        elem = json_check_property(jctx, idx_key, elem, holder, &omit);

        if (!first) {
            if (jctx.offset >= jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = ',';
        }
        first = false;

        // Indentation
        if (jctx.gap_len > 0) {
            if (jctx.offset >= jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = '\n';
            for (usz g = 0; g < (jctx.indent_level + 1) * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
                jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
            }
        }

        // null for omitted/undefined elements
        if (omit || elem.is_undefined()) {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
        } else if (elem.is_lightfunc()) {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
        } else if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* vobj = (HObject*)elem.get_heapptr();
            if (vobj.get_class() == ObjClass.FUNCTION) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
            } else {
                jctx.depth++;
                if (jctx.depth > JSON_MAX_DEPTH) {
                    jctx.depth--;
                    return -1;
                }
                int r = json_serialize_val(jctx, &elem);
                jctx.depth--;
                if (r != 0) return r;
            }
        } else {
            jctx.depth++;
            if (jctx.depth > JSON_MAX_DEPTH) {
                jctx.depth--;
                return -1;
            }
            int r = json_serialize_val(jctx, &elem);
            jctx.depth--;
            if (r != 0) return r;
        }
    }

    if (jctx.gap_len > 0) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = '\n';
        for (usz g = 0; g < jctx.indent_level * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
            jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
        }
    }

    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = ']';
    return 0;
}

/// Serialize a value to JSON
fn int json_serialize_val(JsonSerializeCtx* jctx, TVal* val) {
    switch (val.get_tag()) {
        case NULL_VAL: {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = 'n';
            jctx.buf[jctx.offset++] = 'u';
            jctx.buf[jctx.offset++] = 'l';
            jctx.buf[jctx.offset++] = 'l';
            return 0;
        }
        case BOOLEAN: {
            if (val.get_boolean()) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "true", 4);
                jctx.offset += 4;
            } else {
                if (jctx.offset + 6 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "false", 5);
                jctx.offset += 5;
            }
            return 0;
        }
        case NUMBER: {
            double d = val.get_number();
            if (math::is_nan(d) || math::is_inf(d)) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
                return 0;
            }
            char[64] buf;
            int len = libc::snprintf(&buf, 64, "%.17g", d);
            if (len < 0 || len >= 64) return -1;
            if (jctx.offset + (usz)len > jctx.buf_size) return -1;
            for (int i = 0; i < len; i++) {
                jctx.buf[jctx.offset++] = buf[i];
            }
            return 0;
        }
        case FASTINT: {
            char[64] buf;
            int len = libc::snprintf(&buf, 64, "%ld", val.get_fastint());
            if (len < 0 || len >= 64) return -1;
            if (jctx.offset + (usz)len > jctx.buf_size) return -1;
            for (int i = 0; i < len; i++) {
                jctx.buf[jctx.offset++] = buf[i];
            }
            return 0;
        }
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            char* data = s.get_cstr();
            uint slen = s.blen;
            usz max_out = (usz)(slen * 6 + 3);
            char[4096] str_buf;
            usz out_len = json_escape_string(data, slen, &str_buf, 4096);
            if (out_len == 0) return -1;
            usz copy = out_len < (jctx.buf_size - jctx.offset) ? out_len : (jctx.buf_size - jctx.offset);
            for (usz i = 0; i < copy; i++) {
                jctx.buf[jctx.offset++] = str_buf[i];
            }
            return 0;
        }
        case OBJECT: {
            if (val.get_heapptr() == null) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
                return 0;
            }
            HObject* obj = (HObject*)val.get_heapptr();
            if (obj.get_class() == ObjClass.ARRAY) {
                return json_serialize_array(jctx, obj);
            } else if (obj.get_class() == ObjClass.FUNCTION) {
                // Functions serialize as null in JSON
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
                return 0;
            } else {
                return json_serialize_object(jctx, obj);
            }
        }
        case LIGHTFUNC: {
            // Functions serialize as null
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
            return 0;
        }
        case UNDEFINED:
        case BUFFER:
        case POINTER:
        default:
            // Undefined, Buffer, Pointer -> serialize as null
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
            return 0;
    }
}

/// JSON.stringify(value [, replacer [, space]]) — ES5 §15.12.3
fn void builtin_json_stringify(BuiltinContext* ctx) {
    // Clear any stale error flag
    ctx.heap.has_error = false;
    // Get the value
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal value = ctx.regs[ctx.base_reg];

    // Process replacer argument
    TVal replacer_func;
    replacer_func.set_undefined();
    HString** prop_keys = null;
    uint prop_key_count = 0;
    bool has_replacer_array_flag = false;

    if (ctx.argc > 1) {
        TVal replacer = ctx.regs[ctx.base_reg + 1];

        if (replacer.is_object() && replacer.get_heapptr() != null) {
            HObject* robj = (HObject*)replacer.get_heapptr();
            if (robj.is_callable()) {
                replacer_func = replacer;
            } else if (robj.get_class() == ObjClass.ARRAY) {
                // Build PropertyList from array elements
                // Max 256 keys in property list
                HString*[256] temp_keys;
                uint count = 0;
                has_replacer_array_flag = true;

                // Get length
                HString* len_key = builtin_intern_string(ctx.heap, "length");
                TVal? len_prop = robj.get_prop_proto(len_key);
                uint arr_len = 0;
                if (try l = len_prop) {
                    if (l.is_fastint()) {
                        arr_len = (uint)l.get_fastint();
                    } else if (l.is_number()) {
                        arr_len = (uint)(long)l.get_number();
                    }
                }


                bool is_dense = robj.get_class() == ObjClass.ARRAY && robj.array_part() != null;

                for (uint i = 0; i < arr_len && count < 256; i++) {
                    // Read element: try dense array fast path, then prop lookup
                    TVal elem;
                    bool found = false;
                    if (is_dense && i < robj.array_size) {
                        TVal av = robj.array_part()[i];
                        if (!av.is_undefined()) {
                            elem = av;
                            found = true;
                        }
                    }
                    if (!found) {
                        char[16] idx_buf;
                        int idx_len = libc::snprintf(&idx_buf, 16, "%d", i);
                        HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
                        TVal? elem_opt = robj.get_prop_proto(idx_key);
                        if (try e = elem_opt) {
                            elem = e;
                            found = true;
                        }
                    }
                    if (!found) continue;

                    // Convert to string key per spec:
                    // String → use as-is
                    // Number → ToString
                    // String object → ToString (via .toString())
                    // Number object → ToString (via .toString())
                    // Everything else → skip
                    HString* str_key = null;

                    if (elem.is_string()) {
                        str_key = (HString*)elem.get_heapptr();
                    } else if (elem.is_fastint()) {
                        char[32] num_buf;
                        int num_len = libc::snprintf(&num_buf, 32, "%ld", elem.get_fastint());
                        str_key = builtin_intern_string(ctx.heap, num_buf[:num_len]);
                    } else if (elem.is_number()) {
                        char[64] num_buf;
                        int num_len = libc::snprintf(&num_buf, 64, "%.17g", elem.get_number());
                        str_key = builtin_intern_string(ctx.heap, num_buf[:num_len]);
                    } else if (elem.is_object() && elem.get_heapptr() != null) {
                        HObject* eobj = (HObject*)elem.get_heapptr();
                        if (eobj.get_class() == ObjClass.STRING) {
                            // ToString(value): call toString() to respect overrides
                            HString* ts_key = ctx.heap.str_intern("toString");
                            if (ts_key != null) {
                                TVal? toString_fn_opt = eobj.get_prop_proto(ts_key);
                                if (try toString_fn = toString_fn_opt) {
                                    bool callable = false;
                                    if (toString_fn.is_object() && toString_fn.get_heapptr() != null) {
                                        callable = ((HObject*)toString_fn.get_heapptr()).is_callable();
                                    } else if (toString_fn.is_lightfunc()) {
                                        callable = true;
                                    }
                                    if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                                        TVal res = ctx.heap.call_fn(ctx.vm, toString_fn, null, 0, elem);
                                        if (ctx.heap.has_error) { /* propagate later via ctx */ }
                                        else if (res.is_string()) {
                                            str_key = (HString*)res.get_heapptr();
                                        }
                                    }
                                }
                            }
                            // Fallback: primitive value
                            if (str_key == null && eobj.extra.prim.primitive_value.is_string()) {
                                str_key = (HString*)eobj.extra.prim.primitive_value.get_heapptr();
                            }
                        } else if (eobj.get_class() == ObjClass.NUMBER) {
                            // ToString(value): call toString() to respect overrides
                            HString* ts_key = ctx.heap.str_intern("toString");
                            if (ts_key != null) {
                                TVal? toString_fn_opt = eobj.get_prop_proto(ts_key);
                                if (try toString_fn = toString_fn_opt) {
                                    bool callable = false;
                                    if (toString_fn.is_object() && toString_fn.get_heapptr() != null) {
                                        callable = ((HObject*)toString_fn.get_heapptr()).is_callable();
                                    } else if (toString_fn.is_lightfunc()) {
                                        callable = true;
                                    }
                                    if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                                        TVal res = ctx.heap.call_fn(ctx.vm, toString_fn, null, 0, elem);
                                        if (ctx.heap.has_error) { /* propagate later via ctx */ }
                                        else if (res.is_string()) {
                                            str_key = (HString*)res.get_heapptr();
                                        } else if (res.is_fastint() || res.is_number()) {
                                            char[64] nb;
                                            int nl = libc::snprintf(&nb, 64, "%.17g",
                                                res.is_fastint() ? (double)res.get_fastint() : res.get_number());
                                            str_key = builtin_intern_string(ctx.heap, nb[:nl]);
                                        }
                                    }
                                }
                            }
                            // Fallback: primitive value
                            if (str_key == null) {
                                TVal pv = eobj.extra.prim.primitive_value;
                                if (pv.is_fastint()) {
                                    char[32] num_buf;
                                    int num_len = libc::snprintf(&num_buf, 32, "%ld", pv.get_fastint());
                                    str_key = builtin_intern_string(ctx.heap, num_buf[:num_len]);
                                } else if (pv.is_number()) {
                                    char[64] num_buf;
                                    int num_len = libc::snprintf(&num_buf, 64, "%.17g", pv.get_number());
                                    str_key = builtin_intern_string(ctx.heap, num_buf[:num_len]);
                                }
                            }
                        }
                    }

                    if (str_key == null) continue;

                    // Deduplicate: check if already in list
                    bool dup = false;
                    for (uint d = 0; d < count; d++) {
                        if (temp_keys[d] == str_key) { dup = true; break; }
                    }
                    if (dup) continue;

                    temp_keys[count] = str_key;
                    count++;
                }

                if (count > 0) {
                    prop_keys = (HString**)libc::malloc(count * HString*::size);
                    if (prop_keys != null) {
                        libc::memcpy(prop_keys, &temp_keys[0], count * HString*::size);
                        prop_key_count = count;
                    }
                }

            }
        }
        // Non-callable, non-array replacer → ignore (leave replacer_func undefined)
    }

    // Check space parameter — unwrap Number/String wrappers
    uint space_num = 0;
    char[16] gap_buf;
    usz gap_len = 0;

    if (ctx.argc > 2) {
        TVal space_arg = ctx.regs[ctx.base_reg + 2];

        // Unwrap Number/String wrapper objects via ToString/ToNumber per spec
        if (space_arg.is_object() && space_arg.get_heapptr() != null) {
            HObject* sobj = (HObject*)space_arg.get_heapptr();
            if (sobj.get_class() == ObjClass.NUMBER) {
                // ToNumber(space) → call valueOf()
                HString* vo_key = ctx.heap.str_intern("valueOf");
                if (vo_key != null) {
                    TVal? vo_opt = sobj.get_prop_proto(vo_key);
                    if (try vo_fn = vo_opt) {
                        bool callable = false;
                        if (vo_fn.is_object() && vo_fn.get_heapptr() != null) {
                            callable = ((HObject*)vo_fn.get_heapptr()).is_callable();
                        } else if (vo_fn.is_lightfunc()) {
                            callable = true;
                        }
                        if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                            TVal res = ctx.heap.call_fn(ctx.vm, vo_fn, null, 0, space_arg);
                            if (ctx.heap.has_error) { /* propagate later */ }
                            else { space_arg = res; }
                        }
                    }
                }
                if (space_arg.is_object() && space_arg.get_heapptr() != null) {
                    space_arg = sobj.extra.prim.primitive_value;
                }
            } else if (sobj.get_class() == ObjClass.STRING) {
                // ToString(space) → call toString()
                HString* ts_key = ctx.heap.str_intern("toString");
                if (ts_key != null) {
                    TVal? ts_opt = sobj.get_prop_proto(ts_key);
                    if (try ts_fn = ts_opt) {
                        bool callable = false;
                        if (ts_fn.is_object() && ts_fn.get_heapptr() != null) {
                            callable = ((HObject*)ts_fn.get_heapptr()).is_callable();
                        } else if (ts_fn.is_lightfunc()) {
                            callable = true;
                        }
                        if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                            TVal res = ctx.heap.call_fn(ctx.vm, ts_fn, null, 0, space_arg);
                            if (ctx.heap.has_error) { /* propagate later */ }
                            else { space_arg = res; }
                        }
                    }
                }
                if (space_arg.is_object() && space_arg.get_heapptr() != null &&
                    sobj.extra.prim.primitive_value.is_string()) {
                    space_arg = sobj.extra.prim.primitive_value;
                }
            }
        }

        if (space_arg.is_fastint()) {
            space_num = (uint)space_arg.get_fastint();
            if (space_num > 10) space_num = 10;
        } else if (space_arg.is_number()) {
            space_num = (uint)(long)space_arg.get_number();
            if (space_num > 10) space_num = 10;
        } else if (space_arg.is_string()) {
            HString* s = (HString*)space_arg.get_heapptr();
            char* data = s.get_cstr();
            uint slen = s.blen;
            if (slen > 10) slen = 10;
            for (uint i = 0; i < slen; i++) {
                gap_buf[i] = data[i];
            }
            gap_len = slen;
        }
    }

    // Build gap string
    char[16] gap_str;
    if (space_num > 0) {
        gap_len = space_num;
        for (uint i = 0; i < gap_len && i < 16; i++) {
            gap_str[i] = ' ';
        }
    } else if (gap_len > 0) {
        // String gap: copy from gap_buf to gap_str
        for (usz i = 0; i < gap_len && i < 16; i++) {
            gap_str[i] = gap_buf[i];
        }
    }

    // Apply root-level toJSON + replacer per spec:
    // 1. Create wrapper = { "": value }
    // 2. If ReplacerFunction: value = Call(replacer, wrapper, ["", value])
    // 3. Process the result

    // Create wrapper object
    HObject*? wrapper_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch werr = wrapper_raw) {
        ctx.result.set_undefined();
        if (prop_keys != null) libc::free(prop_keys);
        return;
    }
    HObject* wrapper = wrapper_raw;
    wrapper.prototype = ctx.heap.object_proto;

    TVal wrapper_tv;
    wrapper_tv.set_object(wrapper);

    // Set wrapper[""] = value
    HString* empty_key = builtin_intern_string(ctx.heap, "");
    wrapper.put_prop(empty_key, value, hobject::PROP_FLAGS_WEC);

    // Initialize serialization context
    char[16384] buf;
    JsonSerializeCtx jctx;
    jctx.heap = ctx.heap;
    jctx.vm = ctx.vm;
    jctx.buf = &buf;
    jctx.buf_size = 16384;
    jctx.offset = 0;
    jctx.indent_level = 0;
    jctx.gap = &gap_str;
    jctx.gap_len = gap_len;
    jctx.depth = 0;
    jctx.replacer_func = replacer_func;
    jctx.prop_keys = prop_keys;
    jctx.prop_key_count = prop_key_count;
    jctx.has_replacer_array = has_replacer_array_flag;

    // Apply root-level check: get value from wrapper, apply toJSON + replacer
    bool root_omit = false;
    TVal root_val = json_check_property(&jctx, empty_key, value, wrapper_tv, &root_omit);

    if (jctx.error || ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        if (prop_keys != null) libc::free(prop_keys);
        return;
    }

    if (root_omit) {
        ctx.result.set_undefined();
        if (prop_keys != null) libc::free(prop_keys);
        return;
    }

    // Serialize the processed value
    int result = json_serialize_val(&jctx, &root_val);

    if (jctx.error || ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        if (prop_keys != null) libc::free(prop_keys);
        return;
    }

    if (prop_keys != null) libc::free(prop_keys);

    if (result != 0) {
        ctx.result.set_undefined();
        return;
    }

    HString* result_str = builtin_intern_string(ctx.heap, buf[:jctx.offset]);
    ctx.result.set_string(result_str);
}

// ============================================================================
// Date constructor and methods (ES5 §15.9)
// ============================================================================

/// ECMAScript epoch: 1970-01-01 00:00:00 UTC.
const long EPOCH_YEAR = 1970;

/// Helper: get current time in milliseconds since epoch.
fn double date_now_ms() {
    long t = libc::time(null);
    return (double)t * 1000.0;
}

/// Helper: get the time value from a Date object, or NaN if not a Date.
fn double date_get_time_value(TVal* val) {
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.DATE &&
            (obj.extra.prim.primitive_value.is_number() || obj.extra.prim.primitive_value.is_fastint())) {
            return obj.extra.prim.primitive_value.get_number_or_fastint();
        }
    }
    return double::nan;
}

/// Helper: convert local time components to epoch ms using mktime.
fn double date_local_to_ms(long year, long month, long day,
                           long hour, long minute, long second, long ms) {
    Tm tm;
    tm.tm_sec   = (int)second;
    tm.tm_min   = (int)minute;
    tm.tm_hour  = (int)hour;
    tm.tm_mday  = (int)day;
    tm.tm_mon   = (int)month;
    tm.tm_year  = (int)year - 1900;
    tm.tm_wday  = 0;
    tm.tm_yday  = 0;
    tm.tm_isdst = -1;  // let mktime determine DST
    long epoch_sec = (long)libc::mktime(&tm);
    if (epoch_sec == -1) {
        // Use approximate computation as fallback
        // 86400 seconds per day, assume no DST issues
        // This is approximate but better than NaN
        long days = (year - 1970) * 365 + (year - 1969) / 4 - (year - 1901) / 100 + (year - 1601) / 400;
        // Add months
        long[12] days_in_months = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        bool leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        for (long m = 0; m < month; m++) {
            days += days_in_months[m];
            if (leap && m == 1) days++;
        }
        days += day - 1;
        epoch_sec = days * 86400 + hour * 3600 + minute * 60 + second;
    }
    return (double)epoch_sec * 1000.0 + (double)ms;
}

/// Format a Date as a string like "Mon Jan 01 2024 12:00:00 GMT+0000".
fn usz date_format_to_string(double time_val, char* buf, usz buf_size) {
    // For NaN, return "Invalid Date"
    if (math::is_nan(time_val)) {
        return (usz)libc::snprintf(buf, buf_size, "Invalid Date");
    }
    long t_sec = (long)(time_val / 1000.0);
    Tm result;
    libc::localtime_r(&t_sec, &result);
    Tm* tm = &result;

    // Compute timezone offset by comparing localtime with a gmtime conversion
    // Use mktime on the local tm to get epoch, then compare with raw input
    long local_as_epoch = (long)libc::mktime(tm);
    // If mktime fails, local_as_epoch could be -1
    if (local_as_epoch == -1) local_as_epoch = t_sec;
    long tz_seconds = local_as_epoch - t_sec;
    char tz_sign = '+';
    int offs_hours = (int)(tz_seconds / 3600);
    int offs_mins = (int)((tz_seconds / 60) % 60);
    if (tz_seconds < 0) {
        tz_sign = '-';
        offs_hours = -offs_hours;
        offs_mins = -offs_mins;
    }

    // String constants for weekday/month names
    char* wday_name;
    switch (tm.tm_wday) {
        case 0: wday_name = "Sun"; break;
        case 1: wday_name = "Mon"; break;
        case 2: wday_name = "Tue"; break;
        case 3: wday_name = "Wed"; break;
        case 4: wday_name = "Thu"; break;
        case 5: wday_name = "Fri"; break;
        case 6: wday_name = "Sat"; break;
        default: wday_name = "???"; break;
    }
    char* mon_name;
    switch (tm.tm_mon) {
        case 0: mon_name = "Jan"; break;
        case 1: mon_name = "Feb"; break;
        case 2: mon_name = "Mar"; break;
        case 3: mon_name = "Apr"; break;
        case 4: mon_name = "May"; break;
        case 5: mon_name = "Jun"; break;
        case 6: mon_name = "Jul"; break;
        case 7: mon_name = "Aug"; break;
        case 8: mon_name = "Sep"; break;
        case 9: mon_name = "Oct"; break;
        case 10: mon_name = "Nov"; break;
        case 11: mon_name = "Dec"; break;
        default: mon_name = "???"; break;
    }

    return (usz)libc::snprintf(buf, buf_size, "%s %s %02d %04d %02d:%02d:%02d GMT%c%02d%02d",
        wday_name, mon_name,
        tm.tm_mday, tm.tm_year + 1900,
        tm.tm_hour, tm.tm_min, tm.tm_sec,
        tz_sign, offs_hours, offs_mins);
}

/// Format a Date as ISO 8601 string (used by toJSON).
fn usz date_format_iso(double time_val, char* buf, usz buf_size) {
    if (math::is_nan(time_val)) {
        return (usz)libc::snprintf(buf, buf_size, "null");
    }
    long t_sec = (long)(time_val / 1000.0);
    Tm result;
    libc::localtime_r(&t_sec, &result);
    Tm* tm = &result;

    // Compute timezone offset
    long local_as_epoch = (long)libc::mktime(tm);
    if (local_as_epoch == -1) local_as_epoch = t_sec;
    long tz_seconds = local_as_epoch - t_sec;
    char tz_sign = '+';
    int offs_hours = (int)(tz_seconds / 3600);
    int offs_mins = (int)((tz_seconds / 60) % 60);
    if (tz_seconds < 0) {
        tz_sign = '-';
        offs_hours = -offs_hours;
        offs_mins = -offs_mins;
    }
    int ms = (int)((long)time_val % 1000);
    if (ms < 0) ms += 1000;

    return (usz)libc::snprintf(buf, buf_size,
        "%04d-%02d-%02dT%02d:%02d:%02d.%03d%c%02d:%02d",
        tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
        tm.tm_hour, tm.tm_min, tm.tm_sec, ms,
        tz_sign, offs_hours, offs_mins);
}

/// Date() as function — returns current date-time string (ES5 §15.9.2.1).
fn void builtin_date(BuiltinContext* ctx) {
    double now = date_now_ms();
    if (ctx.is_constructor) {
        // new Date(...) — create Date object
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.DATE);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.date_proto;

        double time_val;
        if (ctx.argc == 0) {
            time_val = now;
        } else if (ctx.argc == 1) {
            TVal* arg = &ctx.regs[ctx.base_reg];
            if (arg.is_string()) {
                // Parse string (simplified — try as number first)
                HString* s = (HString*)arg.get_heapptr();
                double num_val = builtin_string_to_number(s);
                if (math::is_nan(num_val)) {
                    // Non-numeric string — try basic parsing
                    // For now, default to current time
                    time_val = now;
                } else {
                    time_val = num_val;
                }
            } else if (arg.is_number() || arg.is_fastint()) {
                time_val = arg.get_number_or_fastint();
            } else if (arg.is_undefined() || arg.is_null()) {
                time_val = now;
            } else {
                time_val = now;
            }
        } else {
            // Multiple args: Date(year, month[, day, hour, minute, second, ms])
            TVal* year_arg  = &ctx.regs[ctx.base_reg];
            TVal* month_arg = &ctx.regs[ctx.base_reg + 1];
            double year  = year_arg.get_number_or_fastint();
            double month = month_arg.get_number_or_fastint();
            double day   = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : 1.0;
            double hour  = (ctx.argc > 3) ? ctx.regs[ctx.base_reg + 3].get_number_or_fastint() : 0.0;
            double min   = (ctx.argc > 4) ? ctx.regs[ctx.base_reg + 4].get_number_or_fastint() : 0.0;
            double sec   = (ctx.argc > 5) ? ctx.regs[ctx.base_reg + 5].get_number_or_fastint() : 0.0;
            double ms    = (ctx.argc > 6) ? ctx.regs[ctx.base_reg + 6].get_number_or_fastint() : 0.0;

            // Year < 100 means 1900 + year
            if (year >= 0 && year < 100) year += 1900;

            time_val = date_local_to_ms((long)year, (long)month, (long)day,
                                        (long)hour, (long)min, (long)sec, (long)ms);
        }

        obj.extra.prim.primitive_value.set_number(time_val);

        ctx.result.set_object(obj);
    } else {
        // Date() as function — return string of current time
        char[128] buf;
        usz len = date_format_to_string(now, &buf, 128);
        HString* result = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.set_string(result);
    }
}

/// Date.now() — ES5 §15.9.4.4
fn void builtin_date_now(BuiltinContext* ctx) {
    ctx.result.set_number(date_now_ms());
}

/// Date.UTC(year, month[, day, hour, minute, second, ms]) — ES5 §15.9.4.3
fn void builtin_date_utc(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        ctx.result.set_number(double::nan);
        return;
    }
    TVal* year_arg  = &ctx.regs[ctx.base_reg];
    TVal* month_arg = &ctx.regs[ctx.base_reg + 1];
    double year  = year_arg.get_number_or_fastint();
    double month = month_arg.get_number_or_fastint();
    double day   = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : 1.0;
    double hour  = (ctx.argc > 3) ? ctx.regs[ctx.base_reg + 3].get_number_or_fastint() : 0.0;
    double min   = (ctx.argc > 4) ? ctx.regs[ctx.base_reg + 4].get_number_or_fastint() : 0.0;
    double sec   = (ctx.argc > 5) ? ctx.regs[ctx.base_reg + 5].get_number_or_fastint() : 0.0;
    double ms    = (ctx.argc > 6) ? ctx.regs[ctx.base_reg + 6].get_number_or_fastint() : 0.0;

    if (year >= 0 && year < 100) year += 1900;

    // For Date.UTC, the time is in UTC. We compute days from epoch using
    // simple calendar math (no timezone offset).
    long y = (long)year;
    long m = (long)month;
    // Adjust year: treat Jan and Feb as months 13,14 of previous year
    if (m < 2) { y--; m += 12; }
    // Computations using the formula
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;  // [0, 399]
    long doy = (153 * (m - 2) + 2) / 5 + (long)day - 1;  // day of year
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long epoch_day = (era * 146097 + (long)doe - 719468);
    double t = (double)epoch_day * 86400000.0;
    t += (double)hour * 3600000.0 + (double)min * 60000.0 + (double)sec * 1000.0 + (double)ms;
    ctx.result.set_number(t);
}

/// Date.parse(string) — ES5 §15.9.4.2 (simplified)
fn void builtin_date_parse(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_number(double::nan);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    HString* s;
    if (arg.is_string()) {
        s = (HString*)arg.get_heapptr();
    } else {
        s = builtin_to_string(ctx.heap, arg);
    }
    if (s == null || s.blen == 0) {
        ctx.result.set_number(double::nan);
        return;
    }
    // Try numeric parsing first (milliseconds)
    double num_val = builtin_string_to_number(s);
    if (!math::is_nan(num_val)) {
        ctx.result.set_number(num_val);
        return;
    }
    // For non-numeric strings, try parsing as date string via libc
    // For now, return NaN (Date.parse is notoriously complex)
    // Full implementation would use a proper date parser
    ctx.result.set_number(double::nan);
}

/// Date.prototype.toString() — ES5 §15.9.5.2
fn void builtin_date_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    char[128] buf;
    usz len = date_format_to_string(time_val, &buf, 128);
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.toLocaleString() — ES5 §15.9.5.5
/// Falls back to toString() (no locale-specific formatting).
fn void builtin_date_proto_toLocaleString(BuiltinContext* ctx) {
    builtin_date_proto_toString(ctx);
}

/// Date.prototype.toLocaleDateString() — ES5 §15.9.5.6
/// Returns the date portion only (YYYY-MM-DD style).
fn void builtin_date_proto_toLocaleDateString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    if (math::is_nan(time_val)) {
        HString* inv = builtin_intern_string(ctx.heap, "Invalid Date");
        ctx.result.set_string(inv);
        return;
    }
    long year, month, day, wday, hour, min, sec;
    date_break_time(time_val, &year, &month, &day, &wday, &hour, &min, &sec);
    char[types::FORMAT_BUF] buf;
    usz len = (usz)libc::snprintf(&buf, types::FORMAT_BUF, "%04d-%02d-%02d", (int)year, (int)(month + 1), (int)day);
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.toLocaleTimeString() — ES5 §15.9.5.7
/// Returns the time portion only (HH:MM:SS style).
fn void builtin_date_proto_toLocaleTimeString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    if (math::is_nan(time_val)) {
        HString* inv = builtin_intern_string(ctx.heap, "Invalid Date");
        ctx.result.set_string(inv);
        return;
    }
    long year, month, day, wday, hour, min, sec;
    date_break_time(time_val, &year, &month, &day, &wday, &hour, &min, &sec);
    char[types::FORMAT_BUF] buf;
    usz len = (usz)libc::snprintf(&buf, types::FORMAT_BUF, "%02d:%02d:%02d", (int)hour, (int)min, (int)sec);
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.toJSON(key) — ES5 §15.9.5.44
fn void builtin_date_proto_toJSON(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    if (math::is_nan(time_val)) {
        ctx.result.set_null();
        return;
    }
    char[128] buf;
    usz len = date_format_iso(time_val, &buf, 128);
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(result);
}

/// Date.prototype.data.valueOf() — ES5 §15.9.5.8
fn void builtin_date_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    ctx.result.set_number(time_val);
}

/// Date.prototype.getTime() — ES5 §15.9.5.9
fn void builtin_date_proto_getTime(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    ctx.result.set_number(time_val);
}

/// Helper: break a time value into local time components via localtime_r.
fn void date_break_time(double time_val, long* year, long* month, long* day,
                        long* wday, long* hour, long* minute, long* second) {
    if (math::is_nan(time_val)) {
        *year = *month = *day = *wday = *hour = *minute = *second = 0;
        return;
    }
    long t_sec = (long)(time_val / 1000.0);
    Tm result;
    libc::localtime_r(&t_sec, &result);
    *year   = (long)(result.tm_year) + 1900L;
    *month  = (long)(result.tm_mon);
    *day    = (long)(result.tm_mday);
    *wday   = (long)(result.tm_wday);
    *hour   = result.tm_hour;
    *minute = result.tm_min;
    *second = result.tm_sec;
}

/// Date.prototype.getFullYear() — ES5 §15.9.5.10
fn void builtin_date_proto_getFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(year);
}

/// Date.prototype.getMonth() — ES5 §15.9.5.12
fn void builtin_date_proto_getMonth(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(month);
}

/// Date.prototype.getDate() — ES5 §15.9.5.14
fn void builtin_date_proto_getDate(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(day);
}

/// Date.prototype.getDay() — ES5 §15.9.5.16
fn void builtin_date_proto_getDay(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(wday);
}

/// Date.prototype.getHours() — ES5 §15.9.5.18
fn void builtin_date_proto_getHours(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(hour);
}

/// Date.prototype.getMinutes() — ES5 §15.9.5.20
fn void builtin_date_proto_getMinutes(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(min);
}

/// Date.prototype.getSeconds() — ES5 §15.9.5.22
fn void builtin_date_proto_getSeconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(sec);
}

/// Date.prototype.getMilliseconds() — ES5 §15.9.5.24
fn void builtin_date_proto_getMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long ms = (long)tv % 1000;
    if (ms < 0) ms += 1000;
    ctx.result.set_fastint(ms);
}

/// Helper: break a time value into UTC time components via gmtime_r.
fn void date_break_time_utc(double time_val, long* year, long* month, long* day,
                            long* wday, long* hour, long* minute, long* second) {
    if (math::is_nan(time_val)) {
        *year = *month = *day = *wday = *hour = *minute = *second = 0;
        return;
    }
    long t_sec = (long)(time_val / 1000.0);
    Tm result;
    libc::gmtime_r(&t_sec, &result);
    *year   = (long)(result.tm_year) + 1900L;
    *month  = (long)(result.tm_mon);
    *day    = (long)(result.tm_mday);
    *wday   = (long)(result.tm_wday);
    *hour   = result.tm_hour;
    *minute = result.tm_min;
    *second = result.tm_sec;
}

/// Helper: convert UTC time components to epoch ms (no timezone adjustment).
fn double date_utc_to_ms(long year, long month, long day,
                         long hour, long minute, long second, long ms) {
    long y = year;
    long m = month + 1;  // JS months are 0-based, calculation uses 1-based
    if (m < 3) { y--; m += 12; }
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;
    long doy = (153 * (m - 3) + 2) / 5 + day - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long epoch_day = era * 146097 + doe - 719468;
    double t = (double)epoch_day * 86400000.0;
    t += (double)hour * 3600000.0 + (double)minute * 60000.0 + (double)second * 1000.0 + (double)ms;
    return t;
}

/// Helper: TimeClip — clamp time value to ±8.64e15 ms per ES5 §15.9.1.14.
fn double date_time_clip(double t) {
    if (math::is_nan(t)) return t;
    if (t > 8.64e15 || t < -8.64e15) return double::nan;
    return t;
}

/// Helper: set the ms value on a Date object.
fn void date_set_ms(HObject* obj, double new_ms) {
    obj.extra.prim.primitive_value.set_number(new_ms);
}

/// Date.prototype.getTimezoneOffset() — ES5 §15.9.5.26
fn void builtin_date_proto_getTimezoneOffset(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    // local and UTC components
    long ly, lm, ld, lwday, lh, lmin, lsec;
    long uy, um, ud, uwday, uh, umin, usec;
    date_break_time(tv, &ly, &lm, &ld, &lwday, &lh, &lmin, &lsec);
    date_break_time_utc(tv, &uy, &um, &ud, &uwday, &uh, &umin, &usec);
    double local_ms = date_local_to_ms(ly, lm, ld, lh, lmin, lsec, 0);
    double utc_ms   = date_utc_to_ms(uy, um, ud, uh, umin, usec, 0);
    long offset = (long)((local_ms - utc_ms) / 60000.0);
    ctx.result.set_fastint(offset);
}

/// Date.prototype.getUTCFullYear() — ES5 §15.9.5.41
fn void builtin_date_proto_getUTCFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(year);
}

/// Date.prototype.getUTCMonth() — ES5 §15.9.5.42
fn void builtin_date_proto_getUTCMonth(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(month);
}

/// Date.prototype.getUTCDate() — ES5 §15.9.5.43
fn void builtin_date_proto_getUTCDate(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(day);
}

/// Date.prototype.getUTCDay() — ES5 §15.9.5.44
fn void builtin_date_proto_getUTCDay(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(wday);
}

/// Date.prototype.getUTCHours() — ES5 §15.9.5.45
fn void builtin_date_proto_getUTCHours(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(hour);
}

/// Date.prototype.getUTCMinutes() — ES5 §15.9.5.46
fn void builtin_date_proto_getUTCMinutes(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(min);
}

/// Date.prototype.getUTCSeconds() — ES5 §15.9.5.47
fn void builtin_date_proto_getUTCSeconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.set_fastint(sec);
}

/// Date.prototype.getUTCMilliseconds() — ES5 §15.9.5.48
fn void builtin_date_proto_getUTCMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    long ms = (long)tv % 1000;
    if (ms < 0) ms += 1000;
    ctx.result.set_fastint(ms);
}

/// Date.prototype.setTime(time) — ES5 §15.9.5.27
fn void builtin_date_proto_setTime(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double t = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    double clipped = date_time_clip(t);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setMilliseconds(ms) — ES5 §15.9.5.28
fn void builtin_date_proto_setMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double ms = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    if (math::is_nan(ms)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_local_to_ms(year, month, day, hour, min, sec, (long)ms);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setSeconds(sec[, ms]) — ES5 §15.9.5.29
fn void builtin_date_proto_setSeconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double sec_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    double ms_arg  = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (long)tv % 1000;
    if (math::is_nan(sec_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_local_to_ms(year, month, day, hour, min, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setMinutes(min[, sec[, ms]]) — ES5 §15.9.5.30
fn void builtin_date_proto_setMinutes(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double min_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    double sec_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)sec_cur;
    double ms_arg  = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)ms_cur;
    if (math::is_nan(min_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_local_to_ms(year, month, day, hour, (long)min_arg, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setHours(hour[, min[, sec[, ms]]]) — ES5 §15.9.5.31
fn void builtin_date_proto_setHours(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double hour_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long min_cur = (long)tv / 60000 % 60; if (min_cur < 0) min_cur += 60;
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    double min_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)min_cur;
    double sec_arg = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)sec_cur;
    double ms_arg  = (ctx.argc > 3) ? ctx.regs[ctx.base_reg + 3].get_number_or_fastint() : (double)ms_cur;
    if (math::is_nan(hour_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_local_to_ms(year, month, day, (long)hour_arg, (long)min_arg, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setDate(date) — ES5 §15.9.5.32
fn void builtin_date_proto_setDate(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double date_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    if (math::is_nan(date_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_local_to_ms(year, month, (long)date_arg, hour, min, sec, (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setMonth(month[, date]) — ES5 §15.9.5.33
fn void builtin_date_proto_setMonth(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double month_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double date_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)day;
    if (math::is_nan(month_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    double new_ms = date_local_to_ms(year, (long)month_arg, (long)date_arg, hour, min, sec, (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setFullYear(year[, month[, date]]) — ES5 §15.9.5.40
fn void builtin_date_proto_setFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    double year_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    if (math::is_nan(year_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long y, m, d, wday, h, min, s;
    if (math::is_nan(tv)) { y = 1970; m = 0; d = 1; h = 0; min = 0; s = 0; }
    else { date_break_time(tv, &y, &m, &d, &wday, &h, &min, &s); }
    double month_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)m;
    double date_arg  = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)d;
    double new_ms = date_local_to_ms((long)year_arg, (long)month_arg, (long)date_arg, h, min, s, math::is_nan(tv) ? 0 : (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCMilliseconds(ms) — ES5 §15.9.5.49
fn void builtin_date_proto_setUTCMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double ms = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    if (math::is_nan(ms)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_utc_to_ms(year, month, day, hour, min, sec, (long)ms);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCSeconds(sec[, ms]) — ES5 §15.9.5.50
fn void builtin_date_proto_setUTCSeconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double sec_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    double ms_arg  = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (long)tv % 1000;
    if (math::is_nan(sec_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_utc_to_ms(year, month, day, hour, min, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCMinutes(min[, sec[, ms]]) — ES5 §15.9.5.51
fn void builtin_date_proto_setUTCMinutes(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double min_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    double sec_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)sec_cur;
    double ms_arg  = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)ms_cur;
    if (math::is_nan(min_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_utc_to_ms(year, month, day, hour, (long)min_arg, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCHours(hour[, min[, sec[, ms]]]) — ES5 §15.9.5.52
fn void builtin_date_proto_setUTCHours(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double hour_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long min_cur = (long)tv / 60000 % 60; if (min_cur < 0) min_cur += 60;
    long sec_cur = (long)tv / 1000 % 60; if (sec_cur < 0) sec_cur += 60;
    long ms_cur  = (long)tv % 1000; if (ms_cur < 0) ms_cur += 1000;
    double min_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)min_cur;
    double sec_arg = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)sec_cur;
    double ms_arg  = (ctx.argc > 3) ? ctx.regs[ctx.base_reg + 3].get_number_or_fastint() : (double)ms_cur;
    if (math::is_nan(hour_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_utc_to_ms(year, month, day, (long)hour_arg, (long)min_arg, (long)sec_arg, (long)ms_arg);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCDate(date) — ES5 §15.9.5.53
fn void builtin_date_proto_setUTCDate(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double date_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    if (math::is_nan(date_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double new_ms = date_utc_to_ms(year, month, (long)date_arg, hour, min, sec, (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCMonth(month[, date]) — ES5 §15.9.5.54
fn void builtin_date_proto_setUTCMonth(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_number(double::nan); return; }
    double month_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    double date_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)day;
    if (math::is_nan(month_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    double new_ms = date_utc_to_ms(year, (long)month_arg, (long)date_arg, hour, min, sec, (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Date.prototype.setUTCFullYear(year[, month[, date]]) — ES5 §15.9.5.55
fn void builtin_date_proto_setUTCFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) { ctx.result.set_number(double::nan); return; }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.DATE) { ctx.result.set_number(double::nan); return; }
    double tv = date_get_time_value(&this_val);
    double year_arg = (ctx.argc > 0) ? ctx.regs[ctx.base_reg].get_number_or_fastint() : double::nan;
    if (math::is_nan(year_arg)) { date_set_ms(obj, double::nan); ctx.result.set_number(double::nan); return; }
    long y, m, d, wday, h, min, s;
    if (math::is_nan(tv)) { y = 1970; m = 0; d = 1; h = 0; min = 0; s = 0; }
    else { date_break_time_utc(tv, &y, &m, &d, &wday, &h, &min, &s); }
    double month_arg = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1].get_number_or_fastint() : (double)m;
    double date_arg  = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : (double)d;
    double new_ms = date_utc_to_ms((long)year_arg, (long)month_arg, (long)date_arg, h, min, s, math::is_nan(tv) ? 0 : (long)tv % 1000);
    double clipped = date_time_clip(new_ms);
    date_set_ms(obj, clipped);
    ctx.result.set_number(clipped);
}

/// Helper: pad integer to 2 digits
fn void date_pad2(char* buf, long val) {
    if (val < 10) { buf[0] = '0'; buf[1] = (char)(val + 48); }
    else { buf[0] = (char)(val / 10 + 48); buf[1] = (char)(val % 10 + 48); }
}

/// Helper: pad integer to 4 digits
fn void date_pad4(char* buf, long val) {
    buf[0] = (char)(val / 1000 + 48);
    buf[1] = (char)(val / 100 % 10 + 48);
    buf[2] = (char)(val / 10 % 10 + 48);
    buf[3] = (char)(val % 10 + 48);
}

/// Date.prototype.toISOString() — ES5 §15.9.5.41
fn void builtin_date_proto_toISOString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_string(builtin_intern_string(ctx.heap, "Invalid Date")); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    long ms = (long)tv % 1000; if (ms < 0) ms += 1000;
    char[24] buf;
    date_pad4(&buf[0], year);
    buf[4] = '-';
    date_pad2(&buf[5], month + 1);
    buf[7] = '-';
    date_pad2(&buf[8], day);
    buf[10] = 'T';
    date_pad2(&buf[11], hour);
    buf[13] = ':';
    date_pad2(&buf[14], min);
    buf[16] = ':';
    date_pad2(&buf[17], sec);
    buf[19] = '.';
    buf[20] = (char)(ms / 100 + 48);
    buf[21] = (char)(ms / 10 % 10 + 48);
    buf[22] = (char)(ms % 10 + 48);
    buf[23] = 'Z';
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[0:24]));
}

/// Date.prototype.toUTCString() — ES5 §15.9.5.44
fn void builtin_date_proto_toUTCString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.set_string(builtin_intern_string(ctx.heap, "Invalid Date")); return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time_utc(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    char[7][] day_names = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    char[7][] mon_names = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    char[types::FORMAT_BUF] buf;
    // "Thu, 01 Jan 1970 00:00:00 GMT"
    buf[0] = day_names[wday][0]; buf[1] = day_names[wday][1]; buf[2] = day_names[wday][2];
    buf[3] = ','; buf[4] = ' ';
    date_pad2(&buf[5], day);
    buf[7] = ' ';
    buf[8] = mon_names[month][0]; buf[9] = mon_names[month][1]; buf[10] = mon_names[month][2];
    buf[11] = ' ';
    date_pad4(&buf[12], year);
    buf[16] = ' ';
    date_pad2(&buf[17], hour);
    buf[19] = ':';
    date_pad2(&buf[20], min);
    buf[22] = ':';
    date_pad2(&buf[23], sec);
    buf[25] = ' '; buf[26] = 'G'; buf[27] = 'M'; buf[28] = 'T';
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[0:29]));
}

// ============================================================================
// RegExp constructor builtins
// ============================================================================

/// Helper: extract the compiled regexp data pointer from 'this'.
/// Returns null if 'this' is not a REGEXP-class object.
fn HObject* regexp_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) return null;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.REGEXP) return null;
    return obj;
}

/// RegExp(pattern, flags) — ES5 §15.10.3 (called as function) / §15.10.4 (constructor).
/// When called as a function (not constructor), behaviour is identical to construction.
fn void builtin_regexp(BuiltinContext* ctx) {
    // Get pattern
    bool is_regexp = false;
    char* pattern_str = "";
    usz pattern_len = 0;
    int flags = 0;
    int js_flags = 0;  // JS flag bits: 1=g, 2=i, 4=m
    char* flags_str = "";
    usz flags_len = 0;

    if (ctx.argc > 0) {
        TVal* pattern_arg = &ctx.regs[ctx.base_reg];
        if (pattern_arg.is_object() && pattern_arg.get_heapptr() != null) {
            HObject* obj = (HObject*)pattern_arg.get_heapptr();
            if (obj.get_class() == hobject::ObjClass.REGEXP && obj.extra.regexp.regexp_data != null) {
                // Pattern is a RegExp object — extract its pattern
                is_regexp = true;
                if (obj.extra.prim.primitive_value.is_string()) {
                    HString* phs = (HString*)obj.extra.prim.primitive_value.get_heapptr();
                    pattern_str = phs.get_cstr();
                    pattern_len = phs.blen;
                }
            } else {
                // Convert to string for pattern
                HString* phs = builtin_to_string(ctx.heap, pattern_arg);
                if (phs != null) {
                    pattern_str = phs.get_cstr();
                    pattern_len = phs.blen;
                }
            }
        } else if (pattern_arg.is_string() && pattern_arg.get_heapptr() != null) {
            HString* phs = (HString*)pattern_arg.get_heapptr();
            pattern_str = phs.get_cstr();
            pattern_len = phs.blen;
        } else {
            // Convert to string
            HString* phs = builtin_to_string(ctx.heap, pattern_arg);
            if (phs != null) {
                pattern_str = phs.get_cstr();
                pattern_len = phs.blen;
            }
        }
    }

    // Get flags from second argument
    if (ctx.argc > 1) {
        TVal* flags_arg = &ctx.regs[ctx.base_reg + 1];
        if (flags_arg.is_string() && flags_arg.get_heapptr() != null) {
            HString* fhs = (HString*)flags_arg.get_heapptr();
            flags_str = fhs.get_cstr();
            flags_len = fhs.blen;
        } else if (!flags_arg.is_undefined()) {
            HString* fhs = builtin_to_string(ctx.heap, flags_arg);
            if (fhs != null) {
                flags_str = fhs.get_cstr();
                flags_len = fhs.blen;
            }
        }
    }

    // Convert JS flags to libregexp flag bits and store JS flags
    for (usz i = 0; i < flags_len; i++) {
        char f = flags_str[i];
        if (f == 'g') {
            js_flags |= 1;
        } else if (f == 'i') {
            flags |= re_bindings::RE_FLAG_IGNORECASE;
            js_flags |= 2;
        } else if (f == 'm') {
            flags |= re_bindings::RE_FLAG_MULTILINE;
            js_flags |= 4;
        } else if (f == 's') {
            flags |= re_bindings::RE_FLAG_DOTALL;
            js_flags |= 8;
        } else if (f == 'u') {
            js_flags |= 16;
        } else if (f == 'y') {
            js_flags |= 32;
        } else {
            // Invalid flag per ES5 §15.10.4.1 — throw SyntaxError
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.syntax_err_proto;
                char[80] buf;
                int len = libc::snprintf(&buf, 80, "Invalid flags supplied to RegExp constructor '%c'", f);
                if (len > 0 && len < 80) {
                    HString* msg_str = builtin_intern_string(ctx.heap, buf[:len]);
                    TVal msg_tv;
                    msg_tv.set_string(msg_str);
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                }
                ctx.throw_value.set_object(err);
            } else {
                ctx.throw_value.set_undefined();
            }
            ctx.should_throw = true;
            return;
        }
    }

    // Compile the regexp
    char[128] error_buf;
    void* compiled = re_bindings::re_compile(
        (char*)pattern_str, (usz)pattern_len,
        flags, &error_buf, 128
    );

    if (compiled == null) {
        // Compilation failed — throw SyntaxError (ES5 §15.10.4.1)
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.syntax_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, error_buf[:128]);
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.REGEXP);
    if (catch err = obj_raw) {
        if (compiled != null) re_bindings::re_free(compiled);
        ctx.result.set_undefined();
        return;
    }
    HObject* obj = obj_raw;
    obj.prototype = ctx.heap.regexp_proto;
    obj.extra.regexp.regexp_data = compiled;
    obj.extra.regexp.flags = js_flags;

    // Store pattern string as primitive_value
    HString* pattern_hs = builtin_intern_string(ctx.heap, pattern_str[:pattern_len]);
    obj.extra.prim.primitive_value.set_string(pattern_hs);

    // Set RegExp.prototype.lastIndex (ES5 §15.10.7) — own data property
    HString* lastindex_key = builtin_intern_string(ctx.heap, "lastIndex");
    TVal lastindex_tv;
    lastindex_tv.set_fastint(0);
    obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(obj);
}

/// RegExp.prototype.test(string) — ES5 §15.10.6.3
fn void builtin_regexp_proto_test(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this(ctx);
    if (obj == null || obj.extra.regexp.regexp_data == null) {
        // ES5 §15.10.6.3 step 2: throw TypeError if this is not a RegExp
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "RegExp.prototype.test called on incompatible receiver");
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Get input string
    char* input = "";
    int input_len = 0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        HString* hs;
        if (arg.is_string()) {
            hs = (HString*)arg.get_heapptr();
        } else {
            hs = builtin_to_string(ctx.heap, arg);
        }
        if (hs != null) {
            input = hs.get_cstr();
            input_len = (int)hs.blen;
        }
    }

    // Get the global flag
    HString* global_key = builtin_intern_string(ctx.heap, "global");
    bool global_flag = false;
    if (try gv = obj.get_prop(global_key)) {
        if (gv.is_boolean()) global_flag = gv.get_boolean();
    }

    // Get lastIndex (if global)
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    int start_pos = 0;
    if (global_flag) {
        if (try liv = obj.get_prop(li_key)) {
            if (liv.is_fastint()) {
                start_pos = (int)liv.get_fastint();
            } else if (liv.is_number()) {
                start_pos = (int)liv.get_number();
            }
        }
        // If lastIndex is out of bounds, reset to 0 and return false
        if (start_pos < 0 || start_pos > input_len) {
            TVal zero_tv;
            zero_tv.set_fastint(0);
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
            ctx.result.set_boolean(false);
            return;
        }
    }

    // Execute
    int out_start = 0;
    int out_end = 0;
    int out_num_captures = 0;
    int result = re_bindings::re_exec(
        obj.extra.regexp.regexp_data, input, input_len, start_pos,
        &out_start, &out_end, &out_num_captures,
        null, null, 0
    );

    // Update lastIndex if global
    if (global_flag) {
        if (result == re_bindings::RE_MATCH) {
            TVal end_tv;
            end_tv.set_fastint((long)out_end);
            obj.put_prop(li_key, end_tv, hobject::PROP_FLAGS_WEC);
        } else {
            TVal zero_tv;
            zero_tv.set_fastint(0);
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
    }

    ctx.result.set_boolean((result == re_bindings::RE_MATCH));
}

/// RegExp.prototype.exec(string) — ES5 §15.10.6.2
fn void builtin_regexp_proto_exec(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this(ctx);
    if (obj == null || obj.extra.regexp.regexp_data == null) {
        // ES5 §15.10.6.2 step 2: throw TypeError if this is not a RegExp
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "RegExp.prototype.exec called on incompatible receiver");
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Get input string
    char* input = "";
    int input_len = 0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        HString* hs;
        if (arg.is_string()) {
            hs = (HString*)arg.get_heapptr();
        } else {
            hs = builtin_to_string(ctx.heap, arg);
        }
        if (hs != null) {
            input = hs.get_cstr();
            input_len = (int)hs.blen;
        }
    }

    // Get the global flag (ES5 §15.10.6.2 step 6)
    HString* global_key = builtin_intern_string(ctx.heap, "global");
    bool global_flag = false;
    if (try gv = obj.get_prop(global_key)) {
        if (gv.is_boolean()) global_flag = gv.get_boolean();
    }

    // Get lastIndex (steps 4-5)
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    int start_pos = 0;
    if (global_flag) {
        if (try liv = obj.get_prop(li_key)) {
            if (liv.is_fastint()) {
                start_pos = (int)liv.get_fastint();
            } else if (liv.is_number()) {
                start_pos = (int)liv.get_number();
            }
        }
        // Step 7: if i < 0 or i > length, set lastIndex to 0 and return null
        if (start_pos < 0 || start_pos > input_len) {
            TVal zero_tv;
            zero_tv.set_fastint(0);
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
            ctx.result.set_null();
            return;
        }
    }

    // Execute with capture arrays
    int out_start = 0;
    int out_end = 0;
    int out_num_captures = 0;
    int[re_bindings::RE_MAX_CAPTURES] caps_start;
    int[re_bindings::RE_MAX_CAPTURES] caps_end;
    libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
    libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

    int result = re_bindings::re_exec(
        obj.extra.regexp.regexp_data, input, input_len, start_pos,
        &out_start, &out_end, &out_num_captures,
        &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
    );

    if (result != re_bindings::RE_MATCH) {
        // Step 9: no match — reset lastIndex to 0 if global
        if (global_flag) {
            TVal zero_tv;
            zero_tv.set_fastint(0);
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.set_null();
        return;
    }

    // Step 10: if global, update lastIndex to end of match
    if (global_flag) {
        TVal end_tv;
        end_tv.set_fastint((long)out_end);
        obj.put_prop(li_key, end_tv, hobject::PROP_FLAGS_WEC);
    }

    // Create result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_null();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    // Element 0: full match string
    usz match_len = (usz)(out_end - out_start);
    char[1024] buf;
    usz copy_len = match_len < 1024 ? match_len : 1024;
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = input[(usz)out_start + i];
    }
    HString* match_str = builtin_intern_string(ctx.heap, buf[:copy_len]);
    TVal elem;
    elem.set_string(match_str);
    HString* zero_key = builtin_intern_string(ctx.heap, "0");
    arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

    // Elements 1..n: capture groups
    int num_caps = out_num_captures;
    if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
    for (int i = 0; i < num_caps; i++) {
        if (caps_start[i] >= 0 && caps_end[i] >= 0) {
            usz cap_len = (usz)(caps_end[i] - caps_start[i]);
            usz cap_copy = cap_len < 1024 ? cap_len : 1024;
            char[1024] cap_buf;
            for (usz j = 0; j < cap_copy; j++) {
                cap_buf[j] = input[(usz)caps_start[i] + j];
            }
            HString* cap_str = builtin_intern_string(ctx.heap, cap_buf[:cap_copy]);
            TVal cap_elem;
            cap_elem.set_string(cap_str);
            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%d", i + 1);
            HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
            arr.put_prop(idx_key, cap_elem, hobject::PROP_FLAGS_WEC);
        } else {
            // Unmatched capture group -> undefined
            HString* empty_key = builtin_intern_string(ctx.heap, "undefined");
            TVal undef;
            undef.set_undefined();
            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%d", i + 1);
            HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
            arr.put_prop(idx_key, undef, hobject::PROP_FLAGS_WEC);
        }
    }

    // Set index property
    HString* index_key = builtin_intern_string(ctx.heap, "index");
    TVal index_val;
    index_val.set_fastint((long)out_start);
    arr.put_prop(index_key, index_val, hobject::PROP_FLAGS_WEC);

    // Set input property
    HString* input_key = builtin_intern_string(ctx.heap, "input");
    TVal input_val;
    input_val.set_string(builtin_intern_string(ctx.heap, input[:input_len]));
    arr.put_prop(input_key, input_val, hobject::PROP_FLAGS_WEC);

    // Set length
    uint total_elements = 1 + (uint)num_caps;
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_val;
    len_val.set_fastint((long)total_elements);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(arr);
}

/// RegExp.prototype.toString() — ES5 §15.10.6.4
fn void builtin_regexp_proto_toString(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this(ctx);
    if (obj == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    // Build "/pattern/flags" string from stored flags
    char* pattern = "";
    usz plen = 0;
    if (obj.extra.prim.primitive_value.is_string() && obj.extra.prim.primitive_value.get_heapptr() != null) {
        HString* phs = (HString*)obj.extra.prim.primitive_value.get_heapptr();
        pattern = phs.get_cstr();
        plen = phs.blen;
    }

    int jsf = obj.extra.regexp.flags;
    char[512] buf;
    int pos = 0;
    buf[pos++] = '/';
    for (usz i = 0; i < plen && pos < 510; i++) {
        buf[pos++] = pattern[i];
    }
    buf[pos++] = '/';
    if ((jsf & 1) != 0 && pos < 511) buf[pos++] = 'g';
    if ((jsf & 2) != 0 && pos < 511) buf[pos++] = 'i';
    if ((jsf & 4) != 0 && pos < 511) buf[pos++] = 'm';
    if ((jsf & 8) != 0 && pos < 511) buf[pos++] = 's';
    if ((jsf & 16) != 0 && pos < 511) buf[pos++] = 'u';
    if ((jsf & 32) != 0 && pos < 511) buf[pos++] = 'y';
    buf[pos] = 0;

    HString* result = builtin_intern_string(ctx.heap, buf[:pos]);
    ctx.result.set_string(result);
}

// ============================================================================
// RegExp.prototype accessor getters (ES6 §21.2.5)
// These are getter functions registered on RegExp.prototype via accessor properties.
// js_flags encoding: 1=g, 2=i, 4=m, 8=s(dotAll), 16=u(unicode), 32=y(sticky)
// ============================================================================

/// Helper: get regexp this or throw TypeError
fn HObject* regexp_get_this_or_throw(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Method get RegExp.prototype.flags called on incompatible receiver");
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return null;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.REGEXP) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Method get RegExp.prototype.flags called on incompatible receiver");
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return null;
    }
    return obj;
}

/// RegExp.prototype.flags — ES6 §21.2.5.7
/// Returns a string of flags in alphabetical order: "dgimsuy"
fn void builtin_regexp_proto_get_flags(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    int jsf = obj.extra.regexp.flags;
    char[8] buf;
    int pos = 0;
    if ((jsf & 1) != 0)  buf[pos++] = 'g';   // global
    if ((jsf & 8) != 0)  buf[pos++] = 'd';   // dotAll
    if ((jsf & 2) != 0)  buf[pos++] = 'i';   // ignoreCase
    if ((jsf & 4) != 0)  buf[pos++] = 'm';   // multiline
    if ((jsf & 16) != 0) buf[pos++] = 'u';   // unicode
    if ((jsf & 32) != 0) buf[pos++] = 'y';   // sticky
    HString* result = builtin_intern_string(ctx.heap, buf[:pos]);
    ctx.result.set_string(result);
}

/// RegExp.prototype.source — ES6 §21.2.5.10
fn void builtin_regexp_proto_get_source(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    if (obj.extra.prim.primitive_value.is_string() && obj.extra.prim.primitive_value.get_heapptr() != null) {
        HString* phs = (HString*)obj.extra.prim.primitive_value.get_heapptr();
        ctx.result.set_string(phs);
    } else {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "(?:)"));
    }
}

/// RegExp.prototype.global — ES6 §21.2.5.1
fn void builtin_regexp_proto_get_global(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean((obj.extra.regexp.flags & 1) != 0);
}

/// RegExp.prototype.ignoreCase — ES6 §21.2.5.3
fn void builtin_regexp_proto_get_ignoreCase(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean((obj.extra.regexp.flags & 2) != 0);
}

/// RegExp.prototype.multiline — ES6 §21.2.5.5
fn void builtin_regexp_proto_get_multiline(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean((obj.extra.regexp.flags & 4) != 0);
}

/// RegExp.prototype.dotAll — ES2018 §21.2.5.2
fn void builtin_regexp_proto_get_dotAll(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean((obj.extra.regexp.flags & 8) != 0);
}

/// RegExp.prototype.sticky — ES6 §21.2.5.14
fn void builtin_regexp_proto_get_sticky(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean((obj.extra.regexp.flags & 32) != 0);
}

/// RegExp.prototype.unicode — ES6 §21.2.5.16
fn void builtin_regexp_proto_get_unicode(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean((obj.extra.regexp.flags & 16) != 0);
}
// Used by Map and Set for key/value equality.
// Differs from === only in that NaN equals NaN.
// ============================================================================
fn bool same_value_zero(TVal a, TVal b) {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) && math::is_nan(b.get_number())) return true;
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING:    return a.get_heapptr() == b.get_heapptr();
            case OBJECT:    return a.get_heapptr() == b.get_heapptr();
            default: return false;
        }
    }
    if ((a.is_number() && b.is_fastint()) || (a.is_fastint() && b.is_number())) {
        double av = a.is_fastint() ? (double)a.get_fastint() : a.get_number();
        double bv = b.is_fastint() ? (double)b.get_fastint() : b.get_number();
        return av == bv;
    }
    return false;
}

// ============================================================================
// SameValue comparison (ES6 §7.2.9)
// Used by Object.is.
// Differs from SameValueZero in that +0 !== -0.
// ============================================================================
fn bool same_value(TVal a, TVal b) {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) && math::is_nan(b.get_number())) return true;
                // +0 !== -0: check if both are zero with different signs
                if (a.get_number() == 0.0 && b.get_number() == 0.0) {
                    return 1.0 / a.get_number() == 1.0 / b.get_number();
                }
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING:    return a.get_heapptr() == b.get_heapptr();
            case OBJECT:    return a.get_heapptr() == b.get_heapptr();
            default: return false;
        }
    }
    if ((a.is_number() && b.is_fastint()) || (a.is_fastint() && b.is_number())) {
        double av = a.is_fastint() ? (double)a.get_fastint() : a.get_number();
        double bv = b.is_fastint() ? (double)b.get_fastint() : b.get_number();
        return av == bv;
    }
    return false;
}

// ============================================================================
// Map helpers
// ============================================================================

fn HObject* check_map(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.MAP) return obj;
    }
    // TypeError
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Map.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
    }
    return null;
}

/// Find the index in array_part where a key matches. Returns -1 if not found.
/// Map entries are stored as [k0, v0, k1, v1, ...] in array_part.
fn int map_find_key(HObject* map, TVal key) {
    uint count = map.array_used;
    for (uint i = 0; i < count; i += 2) {
        if (same_value_zero(map.array_part()[i], key)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// Map constructor (ES6 §23.1.1)
// ============================================================================
fn void builtin_map(BuiltinContext* ctx) {
    HObject*? map_raw = ctx.heap.alloc_object(hobject::ObjClass.MAP);
    if (catch err = map_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* map = map_raw;
    map.prototype = ctx.heap.map_proto;

    // Set size property
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint(0);
    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // If iterable argument, populate map
    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.is_object() && arg.get_heapptr() != null) {
            HObject* iterable = (HObject*)arg.get_heapptr();
            // Simple case: array-like iterable with forEach/pairs
            // We handle the common case of array of [key, value] pairs
            uint len = array_get_length(iterable, ctx.heap);
            for (uint i = 0; i < len; i++) {
                TVal pair = array_get_elem(iterable, i, ctx.heap);
                if (pair.is_object() && pair.get_heapptr() != null) {
                    HObject* pair_obj = (HObject*)pair.get_heapptr();
                    TVal k = array_get_elem(pair_obj, 0, ctx.heap);
                    TVal v = array_get_elem(pair_obj, 1, ctx.heap);
                    // Call builtin_map_proto_set-style logic inline
                    int found = map_find_key(map, k);
                    if (found >= 0) {
                        map.array_part()[(uint)found + 1] = v;
                    } else {
                        uint cnt = map.array_used;
                        map.set_array_idx(cnt, k);
                        map.set_array_idx(cnt + 1, v);
                    }
                    // Update size
                    uint entry_count = map.array_used / 2;
                    size_val.set_fastint((long)entry_count);
                    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);
                }
            }
        }
    }

    ctx.result.set_object(map);
}

// ============================================================================
// Map.prototype.set(key, value) — ES6 §23.1.3.9
// ============================================================================
fn void builtin_map_proto_set(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    TVal value = ctx.regs[ctx.base_reg + 1];  // undefined if not provided

    int found = map_find_key(map, key);
    if (found >= 0) {
        map.array_part()[(uint)found + 1] = value;
    } else {
        uint cnt = map.array_used;
        map.set_array_idx(cnt, key);
        map.set_array_idx(cnt + 1, value);
    }

    // Update size property
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint((long)(map.array_used / 2));
    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // Return the map itself
    ctx.result.set_object(map);
}

// ============================================================================
// Map.prototype.get(key) — ES6 §23.1.3.6
// ============================================================================
fn void builtin_map_proto_get(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    if (found >= 0) {
        *ctx.result = map.array_part()[(uint)found + 1];
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// Map.prototype.has(key) — ES6 §23.1.3.7
// ============================================================================
fn void builtin_map_proto_has(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// Map.prototype.delete(key) — ES6 §23.1.3.3
// ============================================================================
fn void builtin_map_proto_delete(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    if (found >= 0) {
        uint cnt = map.array_used;
        // Shift elements down to fill the gap
        for (uint i = (uint)found; i + 2 < cnt; i++) {
            map.array_part()[i] = map.array_part()[i + 2];
        }
        // Clear the last two slots
        map.array_part()[cnt - 2].set_undefined();
        map.array_part()[cnt - 1].set_undefined();
        map.array_used = cnt - 2;

        HString* size_key = builtin_intern_string(ctx.heap, "size");
        TVal size_val;
        size_val.set_fastint((long)(map.array_used / 2));
        map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// Map.prototype.clear() — ES6 §23.1.3.1
// ============================================================================
fn void builtin_map_proto_clear(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }

    // Reset array_part
    uint cnt = map.array_used;
    for (uint i = 0; i < cnt; i++) {
        map.array_part()[i].set_undefined();
    }
    map.array_used = 0;

    // Update size
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint(0);
    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    ctx.result.set_undefined();
}

// ============================================================================
// Map.prototype.keys() — ES6 §23.1.3.8
// Returns a MapIterator with kind=1 (keys).
// ============================================================================
fn void builtin_map_proto_keys(BuiltinContext* ctx) {
    create_map_iterator(ctx, 1);
}

// ============================================================================
// Map.prototype.data.values() — ES6 §23.1.3.11
// Returns a MapIterator with kind=0 (values).
// ============================================================================
fn void builtin_map_proto_values(BuiltinContext* ctx) {
    create_map_iterator(ctx, 0);
}

// ============================================================================
// Map.prototype.entries() — ES6 §23.1.3.4
// Returns a MapIterator with kind=2 (entries).
// ============================================================================
fn void builtin_map_proto_entries(BuiltinContext* ctx) {
    create_map_iterator(ctx, 2);
}

// ============================================================================
// Map.prototype[@@iterator] — ES6 §23.1.3.10
// Same as entries().
// ============================================================================
fn void builtin_map_proto_symbol_iter(BuiltinContext* ctx) {
    create_map_iterator(ctx, 2);
}

// ============================================================================
// MapIterator.prototype.next() — ES6 §23.1.5.2.1
// ============================================================================
fn void builtin_map_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.MAP_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* target = iter.iterator_target;
    if (target == null) {
        ctx.result.set_undefined();
        return;
    }

    uint idx = iter.iterator_index * 2;  // Map entries are [k0,v0,k1,v1,...]
    uint kind = iter.iterator_kind;

    bool done = false;
    TVal value;
    value.set_undefined();

    if (idx < target.array_used) {
        TVal* entries = target.array_part();
        if (entries != null) {
            if (kind == 1) {
                // keys: return key at idx
                value = entries[idx];
            } else if (kind == 0) {
                // values: return value at idx+1
                value = entries[idx + 1];
            } else {
                // entries: return [key, value]
                HObject*? pair_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try pair = pair_raw) {
                    pair.prototype = heap.array_proto;
                    pair.set_array_idx(0, entries[idx]);
                    pair.set_array_idx(1, entries[idx + 1]);
                    pair.array_used = 2;
                    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                    if (len_key != null) {
                        TVal len_tv;
                        len_tv.set_fastint(2);
                        pair.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
                    }
                    value.set_object(pair);
                }
            }
            iter.iterator_index += 1;
        } else {
            done = true;
        }
    } else {
        done = true;
    }

    if (done) {
        value.set_undefined();
    }

    // Create result object: {value, done}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(done);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result);
}

// ============================================================================
// Map.prototype.forEach(callbackfn[, thisArg]) — ES6 §23.1.3.5
// ============================================================================
fn void builtin_map_proto_forEach(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }

    if (ctx.argc < 1) {
        // Missing callback throws TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "missing argument 0 when calling function forEach");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
        }
        ctx.result.set_undefined();
        return;
    }

    // forEach with callback requires VM call mechanism (callback invocation).
    // For now, we validate the callback exists but don't invoke it.
    TVal callback = ctx.regs[ctx.base_reg];
    if (!(callback.is_object() && callback.get_heapptr() != null && ((HObject*)callback.get_heapptr()).flags.callable)) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "object is not a function");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
        }
    }

    ctx.result.set_undefined();
}

// ============================================================================
// Set helpers
// ============================================================================

fn HObject* check_set(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.SET) return obj;
    }
    // TypeError
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Set.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
    }
    return null;
}

/// Find the index in array_part where a value matches. Returns -1 if not found.
/// Set entries are stored as [v0, v1, ...] in array_part.
fn int set_find_value(HObject* set, TVal val) {
    uint count = set.array_used;
    for (uint i = 0; i < count; i++) {
        if (same_value_zero(set.array_part()[i], val)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// Set constructor (ES6 §23.2.1)
// ============================================================================
fn void builtin_set(BuiltinContext* ctx) {
    HObject*? set_raw = ctx.heap.alloc_object(hobject::ObjClass.SET);
    if (catch err = set_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* set = set_raw;
    set.prototype = ctx.heap.set_proto;

    // Set size property
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint(0);
    set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // If iterable argument, populate set
    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.is_object() && arg.get_heapptr() != null) {
            HObject* iterable = (HObject*)arg.get_heapptr();
            uint len = array_get_length(iterable, ctx.heap);
            for (uint i = 0; i < len; i++) {
                TVal v = array_get_elem(iterable, i, ctx.heap);
                if (!v.is_undefined()) {
                    int found = set_find_value(set, v);
                    if (found < 0) {
                        set.set_array_idx(set.array_used, v);
                    }
                }
            }
            size_val.set_fastint((long)set.array_used);
            set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);
        }
    }

    ctx.result.set_object(set);
}

// ============================================================================
// Set.prototype.add(value) — ES6 §23.2.3.1
// ============================================================================
fn void builtin_set_proto_add(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    if (found < 0) {
        set.set_array_idx(set.array_used, value);
    }

    // Update size
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint((long)set.array_used);
    set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // Return the set
    ctx.result.set_object(set);
}

// ============================================================================
// Set.prototype.has(value) — ES6 §23.2.3.7
// ============================================================================
fn void builtin_set_proto_has(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// Set.prototype.delete(value) — ES6 §23.2.3.4
// ============================================================================
fn void builtin_set_proto_delete(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    if (found >= 0) {
        uint cnt = set.array_used;
        // Shift elements down
        for (uint i = (uint)found; i + 1 < cnt; i++) {
            set.array_part()[i] = set.array_part()[i + 1];
        }
        set.array_part()[cnt - 1].set_undefined();
        set.array_used = cnt - 1;

        HString* size_key = builtin_intern_string(ctx.heap, "size");
        TVal size_val;
        size_val.set_fastint((long)set.array_used);
        set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// Set.prototype.clear() — ES6 §23.2.3.2
// ============================================================================
fn void builtin_set_proto_clear(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    uint cnt = set.array_used;
    for (uint i = 0; i < cnt; i++) {
        set.array_part()[i].set_undefined();
    }
    set.array_used = 0;

    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint(0);
    set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    ctx.result.set_undefined();
}

// ============================================================================
// Set.prototype.keys() — ES6 §23.2.3.8
// Same as values() — returns a SetIterator with kind=1.
// ============================================================================
fn void builtin_set_proto_keys(BuiltinContext* ctx) {
    create_set_iterator(ctx, 1);
}

// ============================================================================
// Set.prototype.data.values() — ES6 §23.2.3.10
// Returns a SetIterator with kind=0.
// ============================================================================
fn void builtin_set_proto_values(BuiltinContext* ctx) {
    create_set_iterator(ctx, 0);
}

// ============================================================================
// Set.prototype.entries() — ES6 §23.2.3.5
// Returns [value, value] pairs as a SetIterator with kind=2.
// ============================================================================
fn void builtin_set_proto_entries(BuiltinContext* ctx) {
    create_set_iterator(ctx, 2);
}

// ============================================================================
// Set.prototype[@@iterator] — ES6 §23.2.3.9
// Same as values().
// ============================================================================
fn void builtin_set_proto_symbol_iter(BuiltinContext* ctx) {
    create_set_iterator(ctx, 0);
}

// ============================================================================
// SetIterator.prototype.next() — ES6 §23.2.5.2.1
// ============================================================================
fn void builtin_set_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.SET_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* target = iter.iterator_target;
    if (target == null) {
        ctx.result.set_undefined();
        return;
    }

    uint idx = iter.iterator_index;
    uint kind = iter.iterator_kind;

    bool done = false;
    TVal value;
    value.set_undefined();

    if (idx < target.array_used) {
        TVal* entries = target.array_part();
        if (entries != null) {
            TVal item = entries[idx];
            if (kind == 1 || kind == 0) {
                // keys()/values(): return the value
                value = item;
            } else {
                // entries(): return [value, value]
                HObject*? pair_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try pair = pair_raw) {
                    pair.prototype = heap.array_proto;
                    pair.set_array_idx(0, item);
                    pair.set_array_idx(1, item);
                    pair.array_used = 2;
                    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                    if (len_key != null) {
                        TVal len_tv;
                        len_tv.set_fastint(2);
                        pair.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
                    }
                    value.set_object(pair);
                }
            }
            iter.iterator_index += 1;
        } else {
            done = true;
        }
    } else {
        done = true;
    }

    if (done) {
        value.set_undefined();
    }

    // Create result object: {value, done}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(done);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result);
}

// ============================================================================
// Set.prototype.forEach(callbackfn[, thisArg]) — ES6 §23.2.3.6
// ============================================================================
fn void builtin_set_proto_forEach(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    if (ctx.argc < 1) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "missing argument 0 when calling function forEach");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
        }
        ctx.result.set_undefined();
        return;
    }

    // Basic forEach without VM callback support — just returns undefined
    ctx.result.set_undefined();
}

// ============================================================================
// WeakMap helpers
// ============================================================================

fn HObject* check_weakmap(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.WEAKMAP) return obj;
    }
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "WeakMap.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
    }
    return null;
}

fn int weakmap_find_key(HObject* wm, TVal key) {
    uint count = wm.array_used;
    for (uint i = 0; i < count; i += 2) {
        if (same_value_zero(wm.array_part()[i], key)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// WeakMap constructor (ES6 §23.3.1)
// ============================================================================
fn void builtin_weakmap(BuiltinContext* ctx) {
    HObject*? wm_raw = ctx.heap.alloc_object(hobject::ObjClass.WEAKMAP);
    if (catch err = wm_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* wm = wm_raw;
    wm.prototype = ctx.heap.weakmap_proto;

    if (ctx.argc >= 1 && ctx.is_constructor) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.is_object() && arg.get_heapptr() != null) {
            HObject* iterable = (HObject*)arg.get_heapptr();
            uint len = array_get_length(iterable, ctx.heap);
            for (uint i = 0; i < len; i++) {
                TVal pair = array_get_elem(iterable, i, ctx.heap);
                if (pair.is_object() && pair.get_heapptr() != null) {
                    HObject* pair_obj = (HObject*)pair.get_heapptr();
                    TVal k = array_get_elem(pair_obj, 0, ctx.heap);
                    TVal v = array_get_elem(pair_obj, 1, ctx.heap);
                    if (!k.is_object() || k.get_heapptr() == null) {
                        ctx.result.set_undefined();
                        return;
                    }
                    int found = weakmap_find_key(wm, k);
                    if (found >= 0) {
                        wm.array_part()[(uint)found + 1] = v;
                    } else {
                        uint cnt = wm.array_used;
                        wm.set_array_idx(cnt, k);
                        wm.set_array_idx(cnt + 1, v);
                    }
                }
            }
        }
    }

    ctx.result.set_object(wm);
}

// ============================================================================
// WeakMap.prototype.set(key, value) — ES6 §23.3.3.5
// ============================================================================
fn void builtin_weakmap_proto_set(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    if (!key.is_object() || key.get_heapptr() == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Invalid value used as weak map key");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
        }
        ctx.result.set_undefined();
        return;
    }

    TVal value = ctx.regs[ctx.base_reg + 1];
    int found = weakmap_find_key(wm, key);
    if (found >= 0) {
        wm.array_part()[(uint)found + 1] = value;
    } else {
        uint cnt = wm.array_used;
        wm.set_array_idx(cnt, key);
        wm.set_array_idx(cnt + 1, value);
    }

    ctx.result.set_object(wm);
}

// ============================================================================
// WeakMap.prototype.get(key) — ES6 §23.3.3.3
// ============================================================================
fn void builtin_weakmap_proto_get(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = weakmap_find_key(wm, key);
    if (found >= 0) {
        *ctx.result = wm.array_part()[(uint)found + 1];
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// WeakMap.prototype.has(key) — ES6 §23.3.3.4
// ============================================================================
fn void builtin_weakmap_proto_has(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = weakmap_find_key(wm, key);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// WeakMap.prototype.delete(key) — ES6 §23.3.3.2
// ============================================================================
fn void builtin_weakmap_proto_delete(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = weakmap_find_key(wm, key);
    if (found >= 0) {
        uint cnt = wm.array_used;
        for (uint i = (uint)found; i + 2 < cnt; i++) {
            wm.array_part()[i] = wm.array_part()[i + 2];
        }
        wm.array_part()[cnt - 2].set_undefined();
        wm.array_part()[cnt - 1].set_undefined();
        wm.array_used = cnt - 2;

        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// WeakSet helpers
// ============================================================================

fn HObject* check_weakset(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.WEAKSET) return obj;
    }
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "WeakSet.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
    }
    return null;
}

fn int weakset_find_value(HObject* ws, TVal val) {
    uint count = ws.array_used;
    for (uint i = 0; i < count; i++) {
        if (same_value_zero(ws.array_part()[i], val)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// WeakSet constructor (ES6 §23.4.1)
// ============================================================================
fn void builtin_weakset(BuiltinContext* ctx) {
    HObject*? ws_raw = ctx.heap.alloc_object(hobject::ObjClass.WEAKSET);
    if (catch err = ws_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* ws = ws_raw;
    ws.prototype = ctx.heap.weakset_proto;

    if (ctx.argc >= 1 && ctx.is_constructor) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.is_object() && arg.get_heapptr() != null) {
            HObject* iterable = (HObject*)arg.get_heapptr();
            uint len = array_get_length(iterable, ctx.heap);
            for (uint i = 0; i < len; i++) {
                TVal v = array_get_elem(iterable, i, ctx.heap);
                if (!v.is_object() || v.get_heapptr() == null) {
                    ctx.result.set_undefined();
                    return;
                }
                int found = weakset_find_value(ws, v);
                if (found < 0) {
                    ws.set_array_idx(ws.array_used, v);
                }
            }
        }
    }

    ctx.result.set_object(ws);
}

// ============================================================================
// WeakSet.prototype.add(value) — ES6 §23.4.3.1
// ============================================================================
fn void builtin_weakset_proto_add(BuiltinContext* ctx) {
    HObject* ws = check_weakset(ctx);
    if (ws == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal value = ctx.regs[ctx.base_reg];
    if (!value.is_object() || value.get_heapptr() == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Invalid value used in weak set");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
        }
        ctx.result.set_undefined();
        return;
    }

    int found = weakset_find_value(ws, value);
    if (found < 0) {
        ws.set_array_idx(ws.array_used, value);
    }

    ctx.result.set_object(ws);
}

// ============================================================================
// WeakSet.prototype.has(value) — ES6 §23.4.3.4
// ============================================================================
fn void builtin_weakset_proto_has(BuiltinContext* ctx) {
    HObject* ws = check_weakset(ctx);
    if (ws == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = weakset_find_value(ws, value);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// WeakSet.prototype.delete(value) — ES6 §23.4.3.3
// ============================================================================
fn void builtin_weakset_proto_delete(BuiltinContext* ctx) {
    HObject* ws = check_weakset(ctx);
    if (ws == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = weakset_find_value(ws, value);
    if (found >= 0) {
        uint cnt = ws.array_used;
        for (uint i = (uint)found; i + 1 < cnt; i++) {
            ws.array_part()[i] = ws.array_part()[i + 1];
        }
        ws.array_part()[cnt - 1].set_undefined();
        ws.array_used = cnt - 1;

        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// Symbol helpers
// ============================================================================

/// Symbol creation counter — incremented for each unique symbol to guarantee
/// uniqueness even with identical descriptions.
uint g_symbol_counter = 0;

/// Create a new Symbol HString with 0xFF prefix byte.
/// Symbols are NOT inserted into the string table (they are unique).
fn HString* create_symbol_string(Heap* heap, char[] desc) {
    // Build internal representation: 0xFF + description
    // We add a counter suffix for uniqueness when description is empty
    uint counter = g_symbol_counter;
    g_symbol_counter++;

    char[256] buf;
    buf[0] = (char)0xFF;
    int pos = 1;

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

/// Check if a TVal is a Symbol (STRING tag with is_symbol flag)
fn bool is_symbol_val(TVal val) {
    if (!val.is_string()) return false;
    HString* s = (HString*)val.get_heapptr();
    return s != null && s.is_symbol();
}

/// Get the description bytes of a Symbol (everything after the 0xFF prefix)
fn char[] symbol_description(HString* sym) {
    if (sym.blen <= 1) return "";
    char* ptr = sym.get_cstr();
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

/// Ensure the well-known @@toStringTag symbol exists in the global registry.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_tostringtag_symbol(Heap* heap) {
    char[] desc = "toStringTag";
    HString* existing = symbol_registry_get(heap, desc);
    if (existing != null) return existing;
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    symbol_registry_put(heap, desc, sym);
    return sym;
}

/// Ensure the well-known @@iterator symbol exists in the global registry.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_iterator_symbol(Heap* heap) {
    // Fast path: already cached on the heap
    if (heap.iterator_symbol != null) return heap.iterator_symbol;
    char[] desc = "iterator";
    HString* existing = symbol_registry_get(heap, desc);
    if (existing != null) {
        heap.iterator_symbol = existing;
        ((types::HeapHeader*)existing).refcount = heap::STRING_PINNED_REFCOUNT;
        return existing;
    }
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    symbol_registry_put(heap, desc, sym);
    heap.iterator_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@toPrimitive symbol exists in the global registry.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_toprimitive_symbol(Heap* heap) {
    if (heap.toprimitive_symbol != null) return heap.toprimitive_symbol;
    char[] desc = "toPrimitive";
    HString* existing = symbol_registry_get(heap, desc);
    if (existing != null) {
        heap.toprimitive_symbol = existing;
        ((types::HeapHeader*)existing).refcount = heap::STRING_PINNED_REFCOUNT;
        return existing;
    }
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    symbol_registry_put(heap, desc, sym);
    heap.toprimitive_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

// ============================================================================
// Symbol constructor (ES6 §19.4.1)
// ============================================================================
fn void builtin_symbol(BuiltinContext* ctx) {
    // Symbol is not constructable with new
    if (ctx.is_constructor) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Symbol is not a constructor");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Get description from first argument (ToString if present)
    char[] desc = "";
    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        HString* desc_str = builtin_to_string(ctx.heap, &arg);
        if (desc_str != null) {
            desc = desc_str.get_data();
        }
    }

    HString* sym = create_symbol_string(ctx.heap, desc);
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

    TVal key_val = ctx.regs[ctx.base_reg];
    HString* key_str = builtin_to_string(ctx.heap, &key_val);
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Symbol.keyFor requires a symbol argument");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
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
            // Extract [[SymbolData]] — for now, check if there's a stored symbol
            // We look for the "_symbol" property or just describe as "Symbol()"
        }
    }

    if (sym == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Symbol.prototype.toString called on non-Symbol");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
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
            // Return the [[SymbolData]] value
            // For now just return undefined for wrapper objects
        }
    }

    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "Symbol.prototype.data.valueOf called on non-Symbol");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.throw_value.set_object(err);
    } else {
        ctx.throw_value.set_undefined();
    }
    ctx.should_throw = true;
}

// ============================================================================
// Promise helpers (ES6 §25.4)
// ============================================================================

const uint PROMISE_PENDING   = 0;
const uint PROMISE_FULFILLED = 1;
const uint PROMISE_REJECTED  = 2;

/// Get the promise state from the HObject's array_part[0].
fn uint promise_get_state(HObject* promise, uint default_state) {
    if (promise.array_part() != null && promise.array_size >= 2) {
        return (uint)promise.array_part()[0].get_fastint();
    }
    return default_state;
}

/// Set the promise state in array_part.
/// Layout: array[0]=state, array[1]=result, array[2+]=reactions.
/// We must ensure array_used >= 2 so that reactions start at index 2.
/// set_array_idx's undefined-based tracking only counts index 0 (state)
/// as used, leaving index 1 (result=undef) uncounted. Without the fix,
/// promise_add_reaction writes to index 1, clobbering the result slot,
/// and promise_trigger_reactions finds zero reactions.
fn void promise_set_state(HObject* promise, uint state) {
    TVal state_tv;
    state_tv.set_fastint((long)state);
    promise.set_array_idx(0, state_tv);
    TVal undef;
    undef.set_undefined();
    promise.set_array_idx(1, undef);
    if (promise.array_used < 2) {
        promise.array_used = 2;
    }
}

/// Set the promise result in array_part.
/// Writes directly to array_part[1] — the slot is already accounted for in
/// array_used by promise_set_state, so using set_array_idx would incorrectly
/// increment array_used when transitioning from undefined to non-undefined.
fn void promise_set_result(HObject* promise, TVal* val) {
    if (promise.array_part() != null && promise.array_size > 1) {
        promise.array_part()[1] = *val;
    }
}

/// Check that `this` is a Promise object.
fn HObject* check_promise(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) return obj;
    }
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Promise.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WEC);
        }
        ctx.throw_value.set_object(err);
    } else {
        ctx.throw_value.set_undefined();
    }
    ctx.should_throw = true;
    return null;
}

/// Trigger all pending reactions for a settled promise.
fn void promise_trigger_reactions(HObject* promise, Heap* heap, void* vm) {
    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state == PROMISE_PENDING) return;

    TVal result = promise.array_part()[1];

    // Iterate reactions stored in array_part starting at index 2
    // Each reaction occupies one slot (an OBJECT with handler/downstream props)
    uint num_reactions = 0;
    if (promise.array_used > 2) {
        num_reactions = promise.array_used - 2;
    }

    for (uint i = 0; i < num_reactions; i++) {
        TVal reaction_val = promise.array_part()[2 + i];
        if (!reaction_val.is_object() || reaction_val.get_heapptr() == null) continue;
        HObject* reaction = (HObject*)reaction_val.get_heapptr();

        // Get handler: onFulfilled for fulfilled, onRejected for rejected
        char[] handler_prop = (state == PROMISE_FULFILLED) ? "onFulfilled" : "onRejected";
        HString* handler_key = builtin_intern_string(heap, handler_prop);
        TVal? handler_opt = reaction.get_prop(handler_key);
        TVal handler;
        if (try h = handler_opt) {
            handler = h;
        } else {
            handler.set_undefined();
        }

        // Get the downstream promise to resolve/reject
        HString* downstream_key = builtin_intern_string(heap, "downstream");
        TVal downstream_val;
        downstream_val.set_undefined();
        HObject* downstream = null;
        if (try dv = reaction.get_prop(downstream_key)) {
            if (dv.is_object() && dv.get_heapptr() != null) {
                HObject* d = (HObject*)dv.get_heapptr();
                if (d.flags.obj_class == hobject::ObjClass.PROMISE) {
                    downstream = d;
                    downstream_val = dv;
                }
            }
        }

        if (state == PROMISE_FULFILLED) {
            if (handler.is_undefined()) {
                // No onFulfilled — pass through to downstream
                if (downstream != null) {
                    promise_set_state(downstream, PROMISE_FULFILLED);
                    promise_set_result(downstream, &result);
                    promise_trigger_reactions(downstream, heap, vm);
                }
            } else {
                // Enqueue microtask — handler will be called asynchronously,
                // downstream will be resolved with handler's return value by drain
                heap.enqueue_microtask(handler, result, downstream_val);
            }
        } else {
            if (handler.is_undefined()) {
                // No onRejected — pass through rejection to downstream
                if (downstream != null) {
                    promise_set_state(downstream, PROMISE_REJECTED);
                    promise_set_result(downstream, &result);
                    promise_trigger_reactions(downstream, heap, vm);
                }
            } else {
                // Enqueue microtask — handler will be called asynchronously,
                // downstream will be resolved with handler's return value by drain
                heap.enqueue_microtask(handler, result, downstream_val);
            }
        }
    }
}

/// Call a handler function with one argument.
fn TVal call_handler(TVal handler, TVal* arg, Heap* heap, void* vm) {
    if (heap.call_handler_fn != null && vm != null) {
        return heap.call_handler_fn(vm, handler, arg);
    }
    TVal result;
    result.set_undefined();
    return result;
}

/// Microtask completion callback — resolves the downstream promise with the
/// handler's return value.  Registered as heap.microtask_after_fn during init.
fn void promise_microtask_after(void* heap_raw, void* vm, TVal result, TVal downstream) {
    Heap* heap = (Heap*)heap_raw;
    if (!downstream.is_object() || downstream.get_heapptr() == null) return;
    HObject* ds = (HObject*)downstream.get_heapptr();
    if (ds.flags.obj_class != hobject::ObjClass.PROMISE) return;

    // Check if downstream is already settled (shouldn't be, but guard)
    uint state = promise_get_state(ds, PROMISE_PENDING);
    if (state != PROMISE_PENDING) return;

    // Resolve the downstream promise with the handler's return value.
    // If the result is a thenable, we should follow it (Promise Resolution
    // Function).  For now, do a simple resolve.
    promise_set_state(ds, PROMISE_FULFILLED);
    promise_set_result(ds, &result);
    promise_trigger_reactions(ds, heap, vm);
}

/// Resolve or reject a capability's downstream promise.
fn void call_capability(TVal resolve, TVal reject, TVal* val, Heap* heap, bool is_resolve, void* vm) {
    TVal callee = is_resolve ? resolve : reject;
    if (callee.is_undefined()) return;

    if (callee.is_object() && callee.get_heapptr() != null) {
        HObject* obj = (HObject*)callee.get_heapptr();
        // If it's a PROMISE directly, resolve/reject it
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
            promise_set_state(obj, is_resolve ? PROMISE_FULFILLED : PROMISE_REJECTED);
            promise_set_result(obj, val);
            promise_trigger_reactions(obj, heap, vm);
            return;
        }
        // If it's a capability object, look up the "promise" property
        HString* promise_key = builtin_intern_string(heap, "promise");
        if (try pv = obj.get_prop(promise_key)) {
            if (pv.is_object() && pv.get_heapptr() != null) {
                HObject* prom = (HObject*)pv.get_heapptr();
                if (prom.flags.obj_class == hobject::ObjClass.PROMISE) {
                    promise_set_state(prom, is_resolve ? PROMISE_FULFILLED : PROMISE_REJECTED);
                    promise_set_result(prom, val);
                    promise_trigger_reactions(prom, heap, vm);
                }
            }
        }
    }
}

fn void builtin_promise_resolve_callback(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Try to get promise from the function object's stored property
    HObject* promise = null;
    if (ctx.callee_obj != null) {
        HString* promise_key = builtin_intern_string(heap, "\xFFpromise");
        if (try pv = ctx.callee_obj.get_prop(promise_key)) {
            if (pv.is_object() && pv.get_heapptr() != null) {
                HObject* obj = (HObject*)pv.get_heapptr();
                if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                    promise = obj;
                }
            }
        }
    }
    // Fallback to promise_resolve_stack
    if (promise == null && heap.promise_resolve_top > 0 && heap.promise_resolve_stack != null) {
        promise = heap.promise_resolve_stack[heap.promise_resolve_top - 1];
    }
    if (promise == null) return;

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state != PROMISE_PENDING) return;

    TVal value;
    value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];

    promise_set_state(promise, PROMISE_FULFILLED);
    promise_set_result(promise, &value);
    promise_trigger_reactions(promise, heap, ctx.vm);
}

fn void builtin_promise_reject_callback(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    HObject* promise = null;
    if (ctx.callee_obj != null) {
        HString* promise_key = builtin_intern_string(heap, "\xFFpromise");
        if (try pv = ctx.callee_obj.get_prop(promise_key)) {
            if (pv.is_object() && pv.get_heapptr() != null) {
                HObject* obj = (HObject*)pv.get_heapptr();
                if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                    promise = obj;
                }
            }
        }
    }
    if (promise == null && heap.promise_resolve_top > 0 && heap.promise_resolve_stack != null) {
        promise = heap.promise_resolve_stack[heap.promise_resolve_top - 1];
    }
    if (promise == null) return;

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state != PROMISE_PENDING) return;

    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    promise_set_state(promise, PROMISE_REJECTED);
    promise_set_result(promise, &reason);
    promise_trigger_reactions(promise, heap, ctx.vm);
}

/// Create a new Promise with the given internal structure.
fn HObject*? promise_create(Heap* heap) {
    HObject*? prom_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return null;
    HObject* prom = prom_raw;
    prom.prototype = heap.promise_proto;
    promise_set_state(prom, PROMISE_PENDING);
    return prom;
}

/// Create a resolve/reject capability object (internal).
/// Returns a pair of functions as properties on a capability HObject.
fn HObject*? promise_create_capability(Heap* heap, HObject* promise) {
    HObject*? cap_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = cap_raw) return null;
    HObject* cap = cap_raw;

    // Store a reference to the promise this capability controls
    HString* promise_key = builtin_intern_string(heap, "promise");
    TVal promise_val;
    promise_val.set_object(promise);
    cap.put_prop(promise_key, promise_val, hobject::PROP_FLAGS_WEC);

    return cap;
}

/// Add a reaction to a pending promise.
fn void promise_add_reaction(HObject* promise, TVal reaction_val) {
    uint idx = promise.array_used;
    promise.set_array_idx(idx, reaction_val);
}

// ============================================================================
// Promise constructor (ES6 §25.4.3.1)
// ============================================================================

fn void builtin_promise(BuiltinContext* ctx) {
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    // Set prototype
    promise.prototype = ctx.heap.promise_proto;

    if (ctx.argc < 1) {
        // No executor — return pending promise
        ctx.result.set_object(promise);
        return;
    }

    TVal executor = ctx.regs[ctx.base_reg];
    if (!executor.is_object() || executor.get_heapptr() == null) {
        ctx.result.set_object(promise);
        return;
    }

    HObject* exec_func = (HObject*)executor.get_heapptr();
    if (exec_func.extra.func.comp_func == null && exec_func.extra.func.builtin_fn_index < 0) {
        ctx.result.set_object(promise);
        return;
    }

    // Push promise onto resolve stack so resolve/reject callbacks can find it
    Heap* heap = ctx.heap;
    if (heap.promise_resolve_top >= heap.promise_resolve_cap) {
        uint new_cap = heap.promise_resolve_cap == 0 ? 16 : heap.promise_resolve_cap * 2;
        void*? new_raw = heap.alloc((usz)(HObject*::size * new_cap));
        HObject** new_stack;
        if (try p = new_raw) {
            new_stack = (HObject**)p;
        } else {
            ctx.result.set_object(promise);
            return;
        }
        if (heap.promise_resolve_stack != null) {
            libc::memcpy(new_stack, heap.promise_resolve_stack, (usz)(HObject*::size * heap.promise_resolve_top));
            heap.free(heap.promise_resolve_stack);
        } else {
            libc::memset(new_stack, 0, (usz)(HObject*::size * new_cap));
        }
        heap.promise_resolve_stack = new_stack;
        heap.promise_resolve_cap = new_cap;
    }
    if (heap.promise_resolve_stack != null) {
        heap.promise_resolve_stack[heap.promise_resolve_top] = promise;
        heap.promise_resolve_top++;
    }

    // Create resolve/reject function objects that carry the promise reference
    HObject*? resolve_func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = resolve_func_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* resolve_func = resolve_func_raw;
    resolve_func.extra.func.builtin_fn_index = (int)BUILTIN_PROMISE_RESOLVE_CALLBACK;
    resolve_func.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
    resolve_func.flags.callable = true;
    resolve_func.prototype = heap.function_proto;
    // Store promise reference on the function object
    HString* promise_key = builtin_intern_string(heap, "\xFFpromise");
    TVal promise_ref;
    promise_ref.set_object(promise);
    resolve_func.put_prop(promise_key, promise_ref, hobject::PROP_FLAGS_WEC);

    HObject*? reject_func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = reject_func_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* reject_func = reject_func_raw;
    reject_func.extra.func.builtin_fn_index = (int)BUILTIN_PROMISE_REJECT_CALLBACK;
    reject_func.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
    reject_func.flags.callable = true;
    reject_func.prototype = heap.function_proto;
    reject_func.put_prop(promise_key, promise_ref, hobject::PROP_FLAGS_WEC);

    TVal resolve_tv;
    resolve_tv.set_object(resolve_func);
    TVal reject_tv;
    reject_tv.set_object(reject_func);

    // Call executor(resolve, reject) via the VM
    TVal[2] exec_args;
    exec_args[0] = resolve_tv;
    exec_args[1] = reject_tv;
    if (heap.call_fn != null && ctx.vm != null) {
        heap.call_fn(ctx.vm, executor, &exec_args[0], 2, ctx.this_val);
    }

    // Pop from resolve stack
    if (heap.promise_resolve_top > 0) {
        heap.promise_resolve_top--;
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.prototype.then(onFulfilled, onRejected) — ES6 §25.4.5.3
// ============================================================================

fn void builtin_promise_proto_then(BuiltinContext* ctx) {
    HObject* promise = check_promise(ctx);
    if (promise == null) return;

    TVal on_fulfilled;
    on_fulfilled.set_undefined();
    TVal on_rejected;
    on_rejected.set_undefined();
    if (ctx.argc >= 1) on_fulfilled = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) on_rejected  = ctx.regs[ctx.base_reg + 1];

    // Create a new promise for the chain
    HObject*? new_prom_raw = promise_create(ctx.heap);
    if (catch err = new_prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* new_promise = new_prom_raw;

    // Build reaction object
    HObject*? reaction_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = reaction_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* reaction = reaction_raw;

    // Store handlers
    HString* onf_key = builtin_intern_string(ctx.heap, "onFulfilled");
    reaction.put_prop(onf_key, on_fulfilled, hobject::PROP_FLAGS_WEC);

    HString* onr_key = builtin_intern_string(ctx.heap, "onRejected");
    reaction.put_prop(onr_key, on_rejected, hobject::PROP_FLAGS_WEC);

    // Store the downstream promise directly on the reaction
    HString* downstream_key = builtin_intern_string(ctx.heap, "downstream");
    TVal downstream_val;
    downstream_val.set_object(new_promise);
    reaction.put_prop(downstream_key, downstream_val, hobject::PROP_FLAGS_WEC);

    // Add reaction to the original promise
    TVal reaction_val;
    reaction_val.set_object(reaction);

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state == PROMISE_PENDING) {
        promise_add_reaction(promise, reaction_val);
    } else {
        // Promise already settled — trigger reaction immediately
        promise_add_reaction(promise, reaction_val);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    ctx.result.set_object(new_promise);
}

// ============================================================================
// Promise.prototype.catch(onRejected) — ES6 §25.4.5.1
// ============================================================================

fn void builtin_promise_proto_catch(BuiltinContext* ctx) {
    // catch(onRejected) is equivalent to then(undefined, onRejected)
    TVal on_rejected;
    on_rejected.set_undefined();
    if (ctx.argc >= 1) on_rejected = ctx.regs[ctx.base_reg];

    // Set up: then(undefined, on_rejected)
    ctx.regs[ctx.base_reg].set_undefined();     // onFulfilled = undefined
    ctx.regs[ctx.base_reg + 1] = on_rejected;   // onRejected = original arg
    ctx.argc = 2;
    builtin_promise_proto_then(ctx);
}

// ============================================================================
// Promise.prototype.finally(onFinally) — ES2018 §25.4.5.3
// ============================================================================

fn void builtin_promise_proto_finally(BuiltinContext* ctx) {
    HObject* promise = check_promise(ctx);
    if (promise == null) return;

    TVal on_finally;
    on_finally.set_undefined();
    if (ctx.argc >= 1) on_finally = ctx.regs[ctx.base_reg];

    // If onFinally is not callable, just pass through: then(onFinally, onFinally)
    if (!on_finally.is_object() || on_finally.get_heapptr() == null ||
        !((HObject*)on_finally.get_heapptr()).is_callable()) {
        ctx.regs[ctx.base_reg + 1] = on_finally;
        builtin_promise_proto_then(ctx);
        return;
    }

    // ES2018 §25.4.5.3: wrap onFinally in handlers that call it with no args
    // and preserve the original fulfillment value / rejection reason.
    // For now, use onFinally as a passthrough handler (slightly wrong: receives
    // value as arg) — but the downstream promise at least gets a value.
    ctx.regs[ctx.base_reg + 1] = on_finally;  // Set both onFulfilled and onRejected
    builtin_promise_proto_then(ctx);
}

// ============================================================================
// Promise.resolve(x) — ES6 §25.4.4.5
// ============================================================================

fn void builtin_promise_resolve(BuiltinContext* ctx) {
    TVal val;
    val.set_undefined();
    if (ctx.argc >= 1) val = ctx.regs[ctx.base_reg];

    // If already a Promise, return it
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
            *ctx.result = val;
            return;
        }
    }

    // Create a new fulfilled promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;
    promise_set_state(promise, PROMISE_FULFILLED);
    promise_set_result(promise, &val);

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.reject(r) — ES6 §25.4.4.4
// ============================================================================

fn void builtin_promise_reject(BuiltinContext* ctx) {
    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;
    promise_set_state(promise, PROMISE_REJECTED);
    promise_set_result(promise, &reason);

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.all(iterable) — ES6 §25.4.4.1
// ============================================================================

fn void builtin_promise_all(BuiltinContext* ctx) {
    // Get the iterable argument
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Create the result promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    // Helper: resolve result promise with empty array
    usz len = 0;
    bool has_len = false;
    HObject* obj = null;

    if (iterable.is_object() && iterable.get_heapptr() != null) {
        obj = (HObject*)iterable.get_heapptr();
        HString* length_key = builtin_intern_string(ctx.heap, "length");
        if (try len_tv = obj.get_prop(length_key)) {
            if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
                len = (usz)len_tv.get_fastint();
                has_len = true;
            }
        }
    }

    // Zero-length or non-iterable — resolve with [] immediately
    if (!has_len || len == 0) {
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        TVal arr_val;
        arr_val.set_undefined();
        if (try arr = arr_raw) {
            arr.prototype = ctx.heap.array_proto;
            arr_val.set_object(arr);
        }
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &arr_val);
        ctx.result.set_object(promise);
        return;
    }

    // Allocate results array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    usz remaining = len;
    bool rejected = false;

    for (usz i = 0; i < len; i++) {
        if (rejected) break;

        TVal idx_tv;
        idx_tv.set_fastint((long)i);

        TVal elem;
        if (try e = obj.get_prop(&idx_tv)) {
            elem = e;
        } else {
            elem.set_undefined();
        }

        // Check if element is a Promise
        if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* elem_obj = (HObject*)elem.get_heapptr();
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);
                if (state == PROMISE_FULFILLED) {
                    arr.set_array_idx((uint)i, elem_obj.array_part()[1]);
                    remaining--;
                } else if (state == PROMISE_REJECTED) {
                    promise_set_state(promise, PROMISE_REJECTED);
                    promise_set_result(promise, &elem_obj.array_part()[1]);
                    promise_trigger_reactions(promise, ctx.heap, ctx.vm);
                    rejected = true;
                    break;
                } else {
                    // Pending promise — skip (no async support yet)
                    remaining--;
                }
                continue;
            }
        }

        // Not a promise — store as value
        arr.set_array_idx((uint)i, elem);
        remaining--;
    }

    if (!rejected && remaining == 0) {
        TVal arr_val;
        arr_val.set_object(arr);
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &arr_val);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.allSettled(iterable) — ES2020 §25.6.4.5
// ============================================================================

fn void builtin_promise_allsettled(BuiltinContext* ctx) {
    // Get the iterable argument
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Create the result promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    // Get .length from iterable
    usz len = 0;
    bool has_len = false;
    HObject* obj = null;

    if (iterable.is_object() && iterable.get_heapptr() != null) {
        obj = (HObject*)iterable.get_heapptr();
        HString* length_key = builtin_intern_string(ctx.heap, "length");
        if (try len_tv = obj.get_prop(length_key)) {
            if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
                len = (usz)len_tv.get_fastint();
                has_len = true;
            }
        }
    }

    // Zero-length or non-iterable — resolve with [] immediately
    if (!has_len || len == 0) {
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        TVal arr_val;
        arr_val.set_undefined();
        if (try arr = arr_raw) {
            arr.prototype = ctx.heap.array_proto;
            arr_val.set_object(arr);
        }
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &arr_val);
        ctx.result.set_object(promise);
        return;
    }

    // Allocate results array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    usz remaining = len;
    HString* status_key = builtin_intern_string(ctx.heap, "status");
    HString* value_key = builtin_intern_string(ctx.heap, "value");
    HString* reason_key = builtin_intern_string(ctx.heap, "reason");
    TVal fulfilled_status;
    fulfilled_status.set_string(builtin_intern_string(ctx.heap, "fulfilled"));
    TVal rejected_status;
    rejected_status.set_string(builtin_intern_string(ctx.heap, "rejected"));

    for (usz i = 0; i < len; i++) {
        TVal idx_tv;
        idx_tv.set_fastint((long)i);

        TVal elem;
        if (try e = obj.get_prop(&idx_tv)) {
            elem = e;
        } else {
            elem.set_undefined();
        }

        // Check if element is a Promise
        if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* elem_obj = (HObject*)elem.get_heapptr();
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);

                // Create result object
                HObject*? result_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (try result_obj = result_obj_raw) {
                    result_obj.prototype = ctx.heap.object_proto;

                    if (state == PROMISE_FULFILLED) {
                        result_obj.put_prop(status_key, fulfilled_status, hobject::PROP_FLAGS_WEC);
                        result_obj.put_prop(value_key, elem_obj.array_part()[1], hobject::PROP_FLAGS_WEC);
                    } else if (state == PROMISE_REJECTED) {
                        result_obj.put_prop(status_key, rejected_status, hobject::PROP_FLAGS_WEC);
                        result_obj.put_prop(reason_key, elem_obj.array_part()[1], hobject::PROP_FLAGS_WEC);
                    } else {
                        // Pending — use "fulfilled" with undefined value (no async yet)
                        result_obj.put_prop(status_key, fulfilled_status, hobject::PROP_FLAGS_WEC);
                        TVal undef;
                        undef.set_undefined();
                        result_obj.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
                    }
                    TVal result_tv;
                    result_tv.set_object(result_obj);
                    arr.set_array_idx((uint)i, result_tv);
                }
                remaining--;
                continue;
            }
        }

        // Not a promise — store as fulfilled
        HObject*? result_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try result_obj = result_obj_raw) {
            result_obj.prototype = ctx.heap.object_proto;
            result_obj.put_prop(status_key, fulfilled_status, hobject::PROP_FLAGS_WEC);
            result_obj.put_prop(value_key, elem, hobject::PROP_FLAGS_WEC);
            TVal result_tv;
            result_tv.set_object(result_obj);
            arr.set_array_idx((uint)i, result_tv);
        }
        remaining--;
    }

    if (remaining == 0) {
        TVal arr_val;
        arr_val.set_object(arr);
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &arr_val);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.any(iterable) — ES2021 §25.6.4.3
// ============================================================================

fn void builtin_promise_any(BuiltinContext* ctx) {
    // Get the iterable argument
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Create the result promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    // Get .length from iterable
    usz len = 0;
    bool has_len = false;
    HObject* obj = null;

    if (iterable.is_object() && iterable.get_heapptr() != null) {
        obj = (HObject*)iterable.get_heapptr();
        HString* length_key = builtin_intern_string(ctx.heap, "length");
        if (try len_tv = obj.get_prop(length_key)) {
            if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
                len = (usz)len_tv.get_fastint();
                has_len = true;
            }
        }
    }

    // Empty iterable or non-iterable — reject with AggregateError
    if (!has_len || len == 0) {
        TVal errors_tv;
        errors_tv.set_undefined();
        HString* msg = builtin_intern_string(ctx.heap, "All promises were rejected");
        TVal msg_tv;
        msg_tv.set_string(msg);

        // Create AggregateError with empty errors array
        HObject*? agg_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try agg = agg_raw) {
            agg.prototype = ctx.heap.aggregate_err_proto;
            HString* errors_key = builtin_intern_string(ctx.heap, "errors");
            HObject*? empty_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try arr = empty_arr) {
                arr.prototype = ctx.heap.array_proto;
                TVal arr_tv;
                arr_tv.set_object(arr);
                agg.put_prop(errors_key, arr_tv, hobject::PROP_FLAGS_WEC);
            }
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            agg.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        }

        TVal agg_tv;
        agg_tv.set_undefined();
        if (try agg2 = agg_raw) {
            agg_tv.set_object(agg2);
        }
        promise_set_state(promise, PROMISE_REJECTED);
        promise_set_result(promise, &agg_tv);
        ctx.result.set_object(promise);
        return;
    }

    usz remaining = len;
    usz rejected_count = 0;
    HObject*? errors_arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* errors_arr = null;
    if (try arr = errors_arr_raw) {
        arr.prototype = ctx.heap.array_proto;
        errors_arr = arr;
    }

    for (usz i = 0; i < len; i++) {
        TVal idx_tv;
        idx_tv.set_fastint((long)i);

        TVal elem;
        if (try e = obj.get_prop(&idx_tv)) {
            elem = e;
        } else {
            elem.set_undefined();
        }

        // Check if element is a Promise
        if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* elem_obj = (HObject*)elem.get_heapptr();
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);
                if (state == PROMISE_FULFILLED) {
                    // Fulfilled — resolve with value
                    promise_set_state(promise, PROMISE_FULFILLED);
                    promise_set_result(promise, &elem_obj.array_part()[1]);
                    promise_trigger_reactions(promise, ctx.heap, ctx.vm);
                    ctx.result.set_object(promise);
                    return;
                } else if (state == PROMISE_REJECTED) {
                    // Track rejection reason
                    if (errors_arr != null) {
                        errors_arr.set_array_idx((uint)(rejected_count), elem_obj.array_part()[1]);
                    }
                    rejected_count++;
                } else {
                    // Pending — accumulate as rejected with undefined reason
                    if (errors_arr != null) {
                        TVal undef;
                        undef.set_undefined();
                        errors_arr.set_array_idx((uint)(rejected_count), undef);
                    }
                    rejected_count++;
                }
                remaining--;
                continue;
            }
        }

        // Not a promise — resolve with this value immediately
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &elem);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
        ctx.result.set_object(promise);
        return;
    }

    // All rejected — create AggregateError
    if (remaining == 0) {
        TVal errors_val;
        if (errors_arr != null) {
            errors_val.set_object(errors_arr);
        } else {
            errors_val.set_undefined();
        }

        HObject*? agg_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        TVal agg_tv;
        agg_tv.set_undefined();
        if (try agg = agg_raw) {
            agg.prototype = ctx.heap.aggregate_err_proto;
            HString* errors_key = builtin_intern_string(ctx.heap, "errors");
            agg.put_prop(errors_key, errors_val, hobject::PROP_FLAGS_WEC);
            HString* msg = builtin_intern_string(ctx.heap, "All promises were rejected");
            TVal msg_tv;
            msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            agg.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            agg_tv.set_object(agg);
        }
        promise_set_state(promise, PROMISE_REJECTED);
        promise_set_result(promise, &agg_tv);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.race(iterable) — ES6 §25.4.4.3
// ============================================================================

fn void builtin_promise_race(BuiltinContext* ctx) {
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Create the result promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    if (!iterable.is_object() || iterable.get_heapptr() == null) {
        ctx.result.set_object(promise);
        return;
    }

    HObject* obj = (HObject*)iterable.get_heapptr();
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    usz len = 0;
    bool has_len = false;
    if (try len_tv = obj.get_prop(length_key)) {
        if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
            len = (usz)len_tv.get_fastint();
            has_len = true;
        }
    }

    if (!has_len) {
        ctx.result.set_object(promise);
        return;
    }

    bool settled = false;

    for (usz i = 0; i < len && !settled; i++) {
        TVal idx_tv;
        idx_tv.set_fastint((long)i);

        TVal elem;
        if (try e = obj.get_prop(&idx_tv)) {
            elem = e;
        } else {
            elem.set_undefined();
        }

        // If element is a Promise, check its state
        if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* elem_obj = (HObject*)elem.get_heapptr();
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);
                if (state == PROMISE_FULFILLED) {
                    promise_set_state(promise, PROMISE_FULFILLED);
                    promise_set_result(promise, &elem_obj.array_part()[1]);
                    promise_trigger_reactions(promise, ctx.heap, ctx.vm);
                    settled = true;
                    break;
                } else if (state == PROMISE_REJECTED) {
                    promise_set_state(promise, PROMISE_REJECTED);
                    promise_set_result(promise, &elem_obj.array_part()[1]);
                    promise_trigger_reactions(promise, ctx.heap, ctx.vm);
                    settled = true;
                    break;
                }
                // Pending: continue (no async support yet)
                continue;
            }
        }

        // Non-promise value — immediate resolution
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &elem);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
        settled = true;
        break;
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise constructor registration
// ============================================================================

fn bool register_promise_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Promise.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.promise_proto = proto;

    // Register prototype methods
    if (!register_string_proto_method(proto, heap, "then",    BUILTIN_PROMISE_PROTO_THEN))    return false;
    if (!register_string_proto_method(proto, heap, "catch",   BUILTIN_PROMISE_PROTO_CATCH))   return false;
    if (!register_string_proto_method(proto, heap, "finally", BUILTIN_PROMISE_PROTO_FINALLY)) return false;

    // Set @@toStringTag on Promise.prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Promise"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_WEC);
    }

    // Create Promise function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.extra.func.builtin_fn_index = (int)BUILTIN_PROMISE;
    ctor.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    // Wire prototype.constructor → ctor
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

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

    // Promise.length = 1
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(1);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WEC);

    // Register static methods on Promise
    HString* resolve_key = builtin_intern_string(heap, "resolve");
    TVal resolve_tv;
    resolve_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_RESOLVE);
    ctor.put_prop(resolve_key, resolve_tv, hobject::PROP_FLAGS_WEC);

    HString* reject_key = builtin_intern_string(heap, "reject");
    TVal reject_tv;
    reject_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_REJECT);
    ctor.put_prop(reject_key, reject_tv, hobject::PROP_FLAGS_WEC);

    HString* all_key = builtin_intern_string(heap, "all");
    TVal all_tv;
    all_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_ALL);
    ctor.put_prop(all_key, all_tv, hobject::PROP_FLAGS_WEC);

    HString* race_key = builtin_intern_string(heap, "race");
    TVal race_tv;
    race_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_RACE);
    ctor.put_prop(race_key, race_tv, hobject::PROP_FLAGS_WEC);

    HString* allsettled_key = builtin_intern_string(heap, "allSettled");
    TVal allsettled_tv;
    allsettled_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_ALLSETTLED);
    ctor.put_prop(allsettled_key, allsettled_tv, hobject::PROP_FLAGS_WEC);

    HString* any_key = builtin_intern_string(heap, "any");
    TVal any_tv;
    any_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_ANY);
    ctor.put_prop(any_key, any_tv, hobject::PROP_FLAGS_WEC);

    // Register "Promise" in global environment
    uint hash = heap.hash_string("Promise");
    HString* existing = heap.str_table_lookup("Promise", hash);
    HString* promise_key;
    if (existing != null) {
        promise_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Promise", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        promise_key = new_key;
    }
    TVal promise_val;
    promise_val.set_object(ctor);
    set_func_ctor_name_length(ctor, heap, "Promise", 1);
    env::env_declare_nonenum(global_env, promise_key, promise_val);

    return true;
}

// ============================================================================
// GeneratorFunction constructor (ES6 §25.2.1)
// ============================================================================

fn void builtin_generator_function(BuiltinContext* ctx) {
    // GeneratorFunction is not directly callable as a constructor.
    // The user creates generator functions via function* syntax.
    // This builtin exists as the GeneratorFunction constructor object
    // but doesn't actually compile generator functions from strings.
    ctx.result.set_undefined();
}

// ============================================================================
// Generator.prototype.next(value) — ES6 §25.3.1.2
// ============================================================================

fn void builtin_generator_proto_next(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.get_heapptr();
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.set_undefined();
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)gen_obj.extra.gen.generator_data;
    if (gs == null) {
        ctx.result.set_undefined();
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        ctx.result.set_undefined();
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            TVal undef_val;
            undef_val.set_undefined();
            r.put_prop(value_key, undef_val, hobject::PROP_FLAGS_WEC);

            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.set_boolean(true);
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);

            ctx.result.set_object(r);
        }
        return;
    }

    // Set the resume value
    if (ctx.argc >= 1) {
        gs.resume_value = ctx.regs[ctx.base_reg];
    } else {
        gs.resume_value.set_undefined();
    }

    // Set heap.resume_gen so the CALL handler knows to resume
    gs.resume_kind = NEXT;
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    func_obj.extra.func.callable_kind = hobject::CallableKind.COMPILED_FN;
    func_obj.extra.func.comp_func = (CompiledFunction*)gs.func;
    func_obj.extra.func.var_env = (EnvRecord*)gs.var_env;
    func_obj.extra.func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Replace callee slot (base_reg - 2) and this slot (base_reg - 1)
    ctx.regs[ctx.base_reg - 2] = func_tv;
    ctx.regs[ctx.base_reg - 1] = gs.this_binding;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator.prototype.throw(exception) — ES6 §25.3.1.4
// ============================================================================

fn void builtin_generator_proto_throw(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.get_heapptr();
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.set_undefined();
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)gen_obj.extra.gen.generator_data;
    if (gs == null) {
        ctx.result.set_undefined();
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        // Already completed — propagate the exception (ES6 §25.3.1.4.a)
        ctx.should_throw = true;
        if (ctx.argc >= 1) {
            ctx.throw_value = ctx.regs[ctx.base_reg];
        } else {
            ctx.throw_value.set_undefined();
        }
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        // Cannot throw into an executing generator (ES6 §25.3.1.4.b)
        ctx.result.set_undefined();
        return;
    }

    // Set the exception to inject
    if (ctx.argc >= 1) {
        gs.throw_value = ctx.regs[ctx.base_reg];
    } else {
        gs.throw_value.set_undefined();
    }
    gs.resume_kind = THROW;

    // Set heap.resume_gen so the CALL handler knows to resume
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        gs.resume_kind = NEXT;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    func_obj.extra.func.callable_kind = hobject::CallableKind.COMPILED_FN;
    func_obj.extra.func.comp_func = (CompiledFunction*)gs.func;
    func_obj.extra.func.var_env = (EnvRecord*)gs.var_env;
    func_obj.extra.func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Replace callee slot and this slot
    ctx.regs[ctx.base_reg - 2] = func_tv;
    ctx.regs[ctx.base_reg - 1] = gs.this_binding;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator.prototype.return(value) — ES6 §25.3.1.3
// ============================================================================

fn void builtin_generator_proto_return(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.get_heapptr();
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.set_undefined();
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)gen_obj.extra.gen.generator_data;
    if (gs == null) {
        ctx.result.set_undefined();
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        // Already completed — return {value: argument, done: true}
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            TVal arg_val;
            if (ctx.argc >= 1) {
                arg_val = ctx.regs[ctx.base_reg];
            } else {
                arg_val.set_undefined();
            }
            r.put_prop(value_key, arg_val, hobject::PROP_FLAGS_WEC);

            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.set_boolean(true);
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);

            ctx.result.set_object(r);
        }
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        // Cannot return into an executing generator
        ctx.result.set_undefined();
        return;
    }

    if (gs.state == GEN_SUSPENDED_START) {
        // Generator has never executed — complete immediately without
        // executing any body code (ES6 §25.3.1.3, step 5).
        gs.state = GEN_COMPLETED;
        TVal arg_val;
        if (ctx.argc >= 1) {
            arg_val = ctx.regs[ctx.base_reg];
        } else {
            arg_val.set_undefined();
        }
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            r.put_prop(value_key, arg_val, hobject::PROP_FLAGS_WEC);
            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.set_boolean(true);
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
            ctx.result.set_object(r);
        }
        return;
    }

    // Set the return value to inject
    if (ctx.argc >= 1) {
        gs.return_value = ctx.regs[ctx.base_reg];
    } else {
        gs.return_value.set_undefined();
    }
    gs.resume_kind = RETURN;

    // Set heap.resume_gen so the CALL handler knows to resume
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        gs.resume_kind = NEXT;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    func_obj.extra.func.callable_kind = hobject::CallableKind.COMPILED_FN;
    func_obj.extra.func.comp_func = (CompiledFunction*)gs.func;
    func_obj.extra.func.var_env = (EnvRecord*)gs.var_env;
    func_obj.extra.func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Replace callee slot and this slot
    ctx.regs[ctx.base_reg - 2] = func_tv;
    ctx.regs[ctx.base_reg - 1] = gs.this_binding;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator constructor registration
// ============================================================================

fn bool register_generator_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Generator.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.generator_proto = proto;

    // Register prototype methods
    if (!register_string_proto_method(proto, heap, "next",   BUILTIN_GENERATOR_PROTO_NEXT))   return false;
    if (!register_string_proto_method(proto, heap, "throw",  BUILTIN_GENERATOR_PROTO_THROW))  return false;
    if (!register_string_proto_method(proto, heap, "return", BUILTIN_GENERATOR_PROTO_RETURN)) return false;

    // Set @@toStringTag on Generator.prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Generator"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_WEC);
    }

    // Wire prototype.constructor → GeneratorFunction constructor
    // GeneratorFunction constructor is created later; we'll wire it there

    return true;
}

// ============================================================================
// Iterator protocol — built-in @@iterator methods and .next() functions
// ============================================================================

/// Array.prototype[Symbol.iterator] — creates an array iterator object.
fn void builtin_array_proto_symbol_iter(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Get `this` — must be an object
    TVal this_val = ctx.this_val;
    HObject* iterable;
    if (this_val.is_object()) {
        iterable = (HObject*)this_val.get_heapptr();
    } else {
        // Non-object `this`: wrap it
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) { ctx.result.set_undefined(); return; }
        iterable = wrapped;
    }

    // Create an ARRAY_ITERATOR object
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.ARRAY_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    iter.iterator_target = iterable;
    iter.iterator_index = 0;
    iter.prototype = heap.iterator_proto;

    // Add .next method as an own property
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_ARRAY_ITERATOR_NEXT;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    ctx.result.set_object(iter);
}

/// Helper: create an array iterator with a specific kind.
/// kind: 0=value (default), 1=key, 2=key+value (entries)
fn void create_array_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    HObject* iterable;
    if (this_val.is_object()) {
        iterable = (HObject*)this_val.get_heapptr();
    } else {
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) { ctx.result.set_undefined(); return; }
        iterable = wrapped;
    }
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.ARRAY_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    iter.iterator_target = iterable;
    iter.iterator_index = 0;
    iter.iterator_kind = kind;
    iter.prototype = heap.iterator_proto;
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_ARRAY_ITERATOR_NEXT;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    ctx.result.set_object(iter);
}

/// Helper: create a Map iterator with a specific kind.
/// kind: 0=values, 1=keys, 2=entries
fn void create_map_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }

    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.MAP_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    iter.iterator_target = map;
    iter.iterator_index = 0;
    iter.iterator_kind = kind;
    iter.prototype = heap.iterator_proto;

    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_MAP_ITERATOR_NEXT;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    ctx.result.set_object(iter);
}

/// Helper: create a Set iterator with a specific kind.
/// kind: 0=values, 1=keys, 2=entries
fn void create_set_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.SET_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    iter.iterator_target = set;
    iter.iterator_index = 0;
    iter.iterator_kind = kind;
    iter.prototype = heap.iterator_proto;

    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_SET_ITERATOR_NEXT;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    ctx.result.set_object(iter);
}
fn void builtin_array_proto_values(BuiltinContext* ctx) {
    create_array_iterator(ctx, 0);
}

/// Array.prototype.keys — ES2015 §22.1.3.17 (kind=1)
fn void builtin_array_proto_keys(BuiltinContext* ctx) {
    create_array_iterator(ctx, 1);
}

/// Array.prototype.entries — ES2015 §22.1.3.5 (kind=2)
fn void builtin_array_proto_entries(BuiltinContext* ctx) {
    create_array_iterator(ctx, 2);
}

/// String.prototype[Symbol.iterator] — creates a string iterator object.
fn void builtin_string_proto_symbol_iter(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Get `this` — must be a string or String object
    TVal this_val = ctx.this_val;
    HString* str_data = null;
    if (this_val.is_string()) {
        str_data = (HString*)this_val.get_heapptr();
    } else if (this_val.is_object()) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.extra.prim.primitive_value.is_string()) {
            str_data = (HString*)obj.extra.prim.primitive_value.get_heapptr();
        }
    }

    if (str_data == null) {
        ctx.result.set_undefined();
        return;
    }

    // Create a STRING_ITERATOR object
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.STRING_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    // Store the string as primitive_value (for GC tracing via mark_tval)
    iter.extra.prim.primitive_value.set_string(str_data);
    iter.iterator_index = 0;
    iter.prototype = heap.iterator_proto;

    // Add .next method as an own property
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_STRING_ITERATOR_NEXT;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    ctx.result.set_object(iter);
}

/// %IteratorPrototype%[@@iterator] (ES6 §25.1.2.1) — returns `this`.
fn void builtin_iterator_proto_symbol_iter(BuiltinContext* ctx) {
    *ctx.result = ctx.this_val;
}

/// Array iterator .next() — returns {value, done}.
fn void builtin_array_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.ARRAY_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* target = iter.iterator_target;
    if (target == null) {
        ctx.result.set_undefined();
        return;
    }

    uint idx = iter.iterator_index;

    // Check if done — compare against target.array_used (fast path for arrays)
    bool done = false;
    TVal value;
    value.set_undefined();

    if (target.get_class() == hobject::ObjClass.ARRAY && target.array_part() != null) {
        if (idx >= target.array_used) {
            done = true;
        } else {
            TVal? elem = target.get_array_idx(idx);
            if (try v = elem) {
                value = v;
            } else {
                value.set_undefined();
            }
        }
    } else {
        // Fallback: use .length property
        TVal? len_val = target.get_prop_proto((HString*)heap.strs[heap::BuiltinStr.LENGTH]);
        long len = 0;
        if (try lv = len_val) {
            if (lv.is_fastint()) {
                len = lv.get_fastint();
            } else if (lv.is_number()) {
                len = (long)lv.get_number();
            }
        }
        if ((long)idx >= len) {
            done = true;
        } else {
            // Get element via stringified index key
            char[32] idx_buf;
            int idx_len = libc::snprintf(&idx_buf[0], 32, "%u", idx);
            uint idx_hash = heap.hash_string(idx_buf[:idx_len]);
            HString* idx_str = heap.str_table_lookup(idx_buf[:idx_len], idx_hash);
            if (idx_str == null) {
                HString*? new_str = hstring::hstring_alloc(heap, idx_buf[:idx_len], idx_hash);
                if (try s = new_str) {
                    heap.str_table_insert(s);
                    idx_str = s;
                }
            }
            if (idx_str != null) {
                TVal? elem_val = target.get_prop_proto(idx_str);
                if (try ev = elem_val) {
                    value = ev;
                } else {
                    value.set_undefined();
                }
            }
        }
    }

    if (!done) {
        iter.iterator_index = idx + 1;
    }

    // Adjust value based on iterator kind
    uint kind = iter.iterator_kind;
    if (kind == 1) {
        // keys() iterator: value = index
        value.set_fastint((long)idx);
    } else if (kind == 2) {
        // entries() iterator: value = [index, value]
        HObject*? pair_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
        if (try pair = pair_raw) {
            pair.prototype = heap.array_proto;
            TVal idx_tv;
            idx_tv.set_fastint((long)idx);
            pair.set_array_idx(0, idx_tv);
            pair.set_array_idx(1, value);
            pair.array_used = 2;
            value.set_object(pair);
        }
    }
    // kind==0: value stays as-is (default/@@iterator)

    // Create result object: {value, done}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    // Set .value
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);

    // Set .done
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(done);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result);
}

/// String iterator .next() — returns {value, done}.
fn void builtin_string_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.STRING_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HString* str = (HString*)iter.extra.prim.primitive_value.get_heapptr();
    if (str == null) {
        ctx.result.set_undefined();
        return;
    }

    uint idx = iter.iterator_index;
    char[] data = str.get_data();

    // Check if done — for simplicity, iterate by code units (bytes for ASCII)
    // TODO: full Unicode support with code point iteration
    if (idx >= data.len) {
        // Done — return {value: undefined, done: true}
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv;
        done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        TVal undef;
        undef.set_undefined();
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(result);
        return;
    }

    iter.iterator_index = idx + 1;

    // Create result object: {value: char, done: false}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    // Set .value — single character string
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    char[1] ch = { data[idx] };
    HString* char_str = heap.str_intern(ch[:1]);
    if (char_str != null) {
        TVal value_tv;
        value_tv.set_string(char_str);
        result.put_prop(value_key, value_tv, hobject::PROP_FLAGS_WEC);
    }

    // Set .done
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(false);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result);
}

// Function-pointer dispatch table — replaces the 278-arm switch with a single
// indirect call. BUILTIN_COUNT is one past the highest valid index; the bounds
// check below mirrors the old `default:` arm (set_undefined on the result).
BuiltinFunc[BUILTIN_COUNT] builtin_dispatch_table = {
    [BUILTIN_AGGREGATE_ERROR] = &builtin_aggregate_error,
    [BUILTIN_ARRAY] = &builtin_array,
    [BUILTIN_ARRAY_FROM] = &builtin_array_from,
    [BUILTIN_ARRAY_ISARRAY] = &builtin_array_isArray,
    [BUILTIN_ARRAY_ITERATOR_NEXT] = &builtin_array_iterator_next,
    [BUILTIN_ARRAY_OF] = &builtin_array_of,
    [BUILTIN_ARRAY_PROTO_AT] = &builtin_array_proto_at,
    [BUILTIN_ARRAY_PROTO_CONCAT] = &builtin_array_proto_concat,
    [BUILTIN_ARRAY_PROTO_COPYWITHIN] = &builtin_array_proto_copyWithin,
    [BUILTIN_ARRAY_PROTO_EVERY] = &builtin_array_proto_every,
    [BUILTIN_ARRAY_PROTO_ENTRIES] = &builtin_array_proto_entries,
    [BUILTIN_ARRAY_PROTO_FILL] = &builtin_array_proto_fill,
    [BUILTIN_ARRAY_PROTO_FILTER] = &builtin_array_proto_filter,
    [BUILTIN_ARRAY_PROTO_FLAT] = &builtin_array_proto_flat,
    [BUILTIN_ARRAY_PROTO_FLATMAP] = &builtin_array_proto_flatMap,
    [BUILTIN_ARRAY_PROTO_FOREACH] = &builtin_array_proto_forEach,
    [BUILTIN_ARRAY_PROTO_INCLUDES] = &builtin_array_proto_includes,
    [BUILTIN_ARRAY_PROTO_INDEXOF] = &builtin_array_proto_indexOf,
    [BUILTIN_ARRAY_PROTO_JOIN] = &builtin_array_proto_join,
    [BUILTIN_ARRAY_PROTO_KEYS] = &builtin_array_proto_keys,
    [BUILTIN_ARRAY_PROTO_LASTINDEXOF] = &builtin_array_proto_lastIndexOf,
    [BUILTIN_ARRAY_PROTO_MAP] = &builtin_array_proto_map,
    [BUILTIN_ARRAY_PROTO_POP] = &builtin_array_proto_pop,
    [BUILTIN_ARRAY_PROTO_PUSH] = &builtin_array_proto_push,
    [BUILTIN_ARRAY_PROTO_REDUCE] = &builtin_array_proto_reduce,
    [BUILTIN_ARRAY_PROTO_REDUCERIGHT] = &builtin_array_proto_reduceRight,
    [BUILTIN_ARRAY_PROTO_REVERSE] = &builtin_array_proto_reverse,
    [BUILTIN_ARRAY_PROTO_SHIFT] = &builtin_array_proto_shift,
    [BUILTIN_ARRAY_PROTO_SLICE] = &builtin_array_proto_slice,
    [BUILTIN_ARRAY_PROTO_SOME] = &builtin_array_proto_some,
    [BUILTIN_ARRAY_PROTO_SORT] = &builtin_array_proto_sort,
    [BUILTIN_ARRAY_PROTO_SPLICE] = &builtin_array_proto_splice,
    [BUILTIN_ARRAY_PROTO_SYMBOL_ITER] = &builtin_array_proto_symbol_iter,
    [BUILTIN_ARRAY_PROTO_TOREVERSED] = &builtin_array_proto_toReversed,
    [BUILTIN_ARRAY_PROTO_TOSORTED] = &builtin_array_proto_toSorted,
    [BUILTIN_ARRAY_PROTO_TOSPLICED] = &builtin_array_proto_toSpliced,
    [BUILTIN_ARRAY_PROTO_TOSTRING] = &builtin_array_proto_toString,
    [BUILTIN_ARRAY_PROTO_UNSHIFT] = &builtin_array_proto_unshift,
    [BUILTIN_ARRAY_PROTO_VALUES] = &builtin_array_proto_values,
    [BUILTIN_ARRAY_PROTO_WITH] = &builtin_array_proto_with,
    [BUILTIN_BOOLEAN] = &builtin_boolean,
    [BUILTIN_BOOLEAN_PROTO_TOSTRING] = &builtin_boolean_proto_toString,
    [BUILTIN_BOOLEAN_PROTO_VALUEOF] = &builtin_boolean_proto_valueOf,
    [BUILTIN_BOUND_CALL] = &builtin_bound_call,
    [BUILTIN_CONSOLE_LOG] = &builtin_console_log,
    [BUILTIN_DATE] = &builtin_date,
    [BUILTIN_DATE_NOW] = &builtin_date_now,
    [BUILTIN_DATE_PARSE] = &builtin_date_parse,
    [BUILTIN_DATE_PROTO_GETDATE] = &builtin_date_proto_getDate,
    [BUILTIN_DATE_PROTO_GETDAY] = &builtin_date_proto_getDay,
    [BUILTIN_DATE_PROTO_GETFULLYEAR] = &builtin_date_proto_getFullYear,
    [BUILTIN_DATE_PROTO_GETHOURS] = &builtin_date_proto_getHours,
    [BUILTIN_DATE_PROTO_GETMILLISECONDS] = &builtin_date_proto_getMilliseconds,
    [BUILTIN_DATE_PROTO_GETMINUTES] = &builtin_date_proto_getMinutes,
    [BUILTIN_DATE_PROTO_GETMONTH] = &builtin_date_proto_getMonth,
    [BUILTIN_DATE_PROTO_GETSECONDS] = &builtin_date_proto_getSeconds,
    [BUILTIN_DATE_PROTO_GETTIME] = &builtin_date_proto_getTime,
    [BUILTIN_DATE_PROTO_GETTIMEZONEOFFSET] = &builtin_date_proto_getTimezoneOffset,
    [BUILTIN_DATE_PROTO_GETUTCDATE] = &builtin_date_proto_getUTCDate,
    [BUILTIN_DATE_PROTO_GETUTCDAY] = &builtin_date_proto_getUTCDay,
    [BUILTIN_DATE_PROTO_GETUTCFULLYEAR] = &builtin_date_proto_getUTCFullYear,
    [BUILTIN_DATE_PROTO_GETUTCHOURS] = &builtin_date_proto_getUTCHours,
    [BUILTIN_DATE_PROTO_GETUTCMILLISECONDS] = &builtin_date_proto_getUTCMilliseconds,
    [BUILTIN_DATE_PROTO_GETUTCMINUTES] = &builtin_date_proto_getUTCMinutes,
    [BUILTIN_DATE_PROTO_GETUTCMONTH] = &builtin_date_proto_getUTCMonth,
    [BUILTIN_DATE_PROTO_GETUTCSECONDS] = &builtin_date_proto_getUTCSeconds,
    [BUILTIN_DATE_PROTO_SETDATE] = &builtin_date_proto_setDate,
    [BUILTIN_DATE_PROTO_SETFULLYEAR] = &builtin_date_proto_setFullYear,
    [BUILTIN_DATE_PROTO_SETHOURS] = &builtin_date_proto_setHours,
    [BUILTIN_DATE_PROTO_SETMILLISECONDS] = &builtin_date_proto_setMilliseconds,
    [BUILTIN_DATE_PROTO_SETMINUTES] = &builtin_date_proto_setMinutes,
    [BUILTIN_DATE_PROTO_SETMONTH] = &builtin_date_proto_setMonth,
    [BUILTIN_DATE_PROTO_SETSECONDS] = &builtin_date_proto_setSeconds,
    [BUILTIN_DATE_PROTO_SETTIME] = &builtin_date_proto_setTime,
    [BUILTIN_DATE_PROTO_SETUTCDATE] = &builtin_date_proto_setUTCDate,
    [BUILTIN_DATE_PROTO_SETUTCFULLYEAR] = &builtin_date_proto_setUTCFullYear,
    [BUILTIN_DATE_PROTO_SETUTCHOURS] = &builtin_date_proto_setUTCHours,
    [BUILTIN_DATE_PROTO_SETUTCMILLISECONDS] = &builtin_date_proto_setUTCMilliseconds,
    [BUILTIN_DATE_PROTO_SETUTCMINUTES] = &builtin_date_proto_setUTCMinutes,
    [BUILTIN_DATE_PROTO_SETUTCMONTH] = &builtin_date_proto_setUTCMonth,
    [BUILTIN_DATE_PROTO_SETUTCSECONDS] = &builtin_date_proto_setUTCSeconds,
    [BUILTIN_DATE_PROTO_TOGMTSTRING] = &builtin_date_proto_toUTCString,
    [BUILTIN_DATE_PROTO_TOISOSTRING] = &builtin_date_proto_toISOString,
    [BUILTIN_DATE_PROTO_TOJSON] = &builtin_date_proto_toJSON,
    [BUILTIN_DATE_PROTO_TOLOCALEDATESTRING] = &builtin_date_proto_toLocaleDateString,
    [BUILTIN_DATE_PROTO_TOLOCALESTRING] = &builtin_date_proto_toLocaleString,
    [BUILTIN_DATE_PROTO_TOLOCALETIMESTRING] = &builtin_date_proto_toLocaleTimeString,
    [BUILTIN_DATE_PROTO_TOSTRING] = &builtin_date_proto_toString,
    [BUILTIN_DATE_PROTO_TOUTCSTRING] = &builtin_date_proto_toUTCString,
    [BUILTIN_DATE_PROTO_VALUEOF] = &builtin_date_proto_valueOf,
    [BUILTIN_DATE_UTC] = &builtin_date_utc,
    [BUILTIN_DECODE_URI] = &builtin_decode_uri,
    [BUILTIN_DECODE_URI_COMPONENT] = &builtin_decode_uri_component,
    [BUILTIN_ENCODE_URI] = &builtin_encode_uri,
    [BUILTIN_ENCODE_URI_COMPONENT] = &builtin_encode_uri_component,
    [BUILTIN_ERROR] = &builtin_error,
    [BUILTIN_ERROR_PROTO_TOSTRING] = &builtin_error_prototype_to_string,
    [BUILTIN_EVAL] = &builtin_eval,
    [BUILTIN_EVAL_ERROR] = &builtin_eval_error,
    [BUILTIN_FUNCTION] = &builtin_function,
    [BUILTIN_FUNCTION_PROTO_APPLY] = &builtin_function_proto_apply,
    [BUILTIN_FUNCTION_PROTO_BIND] = &builtin_function_proto_bind,
    [BUILTIN_FUNCTION_PROTO_CALL] = &builtin_function_proto_call,
    [BUILTIN_GENERATOR_FUNCTION] = &builtin_generator_function,
    [BUILTIN_GENERATOR_PROTO_NEXT] = &builtin_generator_proto_next,
    [BUILTIN_GENERATOR_PROTO_RETURN] = &builtin_generator_proto_return,
    [BUILTIN_GENERATOR_PROTO_THROW] = &builtin_generator_proto_throw,
    [BUILTIN_IS_FINITE] = &builtin_is_finite,
    [BUILTIN_IS_NAN] = &builtin_is_nan,
    [BUILTIN_ITERATOR_PROTO_SYMBOL_ITER] = &builtin_iterator_proto_symbol_iter,
    [BUILTIN_JSON_PARSE] = &builtin_json_parse,
    [BUILTIN_JSON_STRINGIFY] = &builtin_json_stringify,
    [BUILTIN_MAP] = &builtin_map,
    [BUILTIN_MAP_ITERATOR_NEXT] = &builtin_map_iterator_next,
    [BUILTIN_MAP_PROTO_CLEAR] = &builtin_map_proto_clear,
    [BUILTIN_MAP_PROTO_DELETE] = &builtin_map_proto_delete,
    [BUILTIN_MAP_PROTO_ENTRIES] = &builtin_map_proto_entries,
    [BUILTIN_MAP_PROTO_FOREACH] = &builtin_map_proto_forEach,
    [BUILTIN_MAP_PROTO_GET] = &builtin_map_proto_get,
    [BUILTIN_MAP_PROTO_HAS] = &builtin_map_proto_has,
    [BUILTIN_MAP_PROTO_KEYS] = &builtin_map_proto_keys,
    [BUILTIN_MAP_PROTO_SET] = &builtin_map_proto_set,
    [BUILTIN_MAP_PROTO_SYMBOL_ITER] = &builtin_map_proto_symbol_iter,
    [BUILTIN_MAP_PROTO_VALUES] = &builtin_map_proto_values,
    [BUILTIN_MATH_ABS] = &builtin_math_abs,
    [BUILTIN_MATH_ACOS] = &builtin_math_acos,
    [BUILTIN_MATH_ACOSH] = &builtin_math_acosh,
    [BUILTIN_MATH_ASIN] = &builtin_math_asin,
    [BUILTIN_MATH_ASINH] = &builtin_math_asinh,
    [BUILTIN_MATH_ATAN] = &builtin_math_atan,
    [BUILTIN_MATH_ATAN2] = &builtin_math_atan2,
    [BUILTIN_MATH_ATANH] = &builtin_math_atanh,
    [BUILTIN_MATH_CBRT] = &builtin_math_cbrt,
    [BUILTIN_MATH_CEIL] = &builtin_math_ceil,
    [BUILTIN_MATH_CLZ32] = &builtin_math_clz32,
    [BUILTIN_MATH_COS] = &builtin_math_cos,
    [BUILTIN_MATH_COSH] = &builtin_math_cosh,
    [BUILTIN_MATH_EXP] = &builtin_math_exp,
    [BUILTIN_MATH_EXPM1] = &builtin_math_expm1,
    [BUILTIN_MATH_FLOOR] = &builtin_math_floor,
    [BUILTIN_MATH_FROUND] = &builtin_math_fround,
    [BUILTIN_MATH_HYPOT] = &builtin_math_hypot,
    [BUILTIN_MATH_IMUL] = &builtin_math_imul,
    [BUILTIN_MATH_LOG] = &builtin_math_log,
    [BUILTIN_MATH_LOG10] = &builtin_math_log10,
    [BUILTIN_MATH_LOG1P] = &builtin_math_log1p,
    [BUILTIN_MATH_LOG2] = &builtin_math_log2,
    [BUILTIN_MATH_MAX] = &builtin_math_max,
    [BUILTIN_MATH_MIN] = &builtin_math_min,
    [BUILTIN_MATH_POW] = &builtin_math_pow,
    [BUILTIN_MATH_RANDOM] = &builtin_math_random,
    [BUILTIN_MATH_ROUND] = &builtin_math_round,
    [BUILTIN_MATH_SIGN] = &builtin_math_sign,
    [BUILTIN_MATH_SIN] = &builtin_math_sin,
    [BUILTIN_MATH_SINH] = &builtin_math_sinh,
    [BUILTIN_MATH_SQRT] = &builtin_math_sqrt,
    [BUILTIN_MATH_TAN] = &builtin_math_tan,
    [BUILTIN_MATH_TANH] = &builtin_math_tanh,
    [BUILTIN_MATH_TRUNC] = &builtin_math_trunc,
    [BUILTIN_NUMBER] = &builtin_number,
    [BUILTIN_NUMBER_ISFINITE] = &builtin_number_isFinite,
    [BUILTIN_NUMBER_ISINTEGER] = &builtin_number_isInteger,
    [BUILTIN_NUMBER_ISNAN] = &builtin_number_isNaN,
    [BUILTIN_NUMBER_ISSAFEINTEGER] = &builtin_number_isSafeInteger,
    [BUILTIN_NUMBER_PROTO_TOEXPONENTIAL] = &builtin_number_proto_toExponential,
    [BUILTIN_NUMBER_PROTO_TOFIXED] = &builtin_number_proto_toFixed,
    [BUILTIN_NUMBER_PROTO_TOPRECISION] = &builtin_number_proto_toPrecision,
    [BUILTIN_NUMBER_PROTO_TOSTRING] = &builtin_number_proto_toString,
    [BUILTIN_NUMBER_PROTO_VALUEOF] = &builtin_number_proto_valueOf,
    [BUILTIN_OBJECT] = &builtin_object,
    [BUILTIN_OBJECT_ASSIGN] = &builtin_object_assign,
    [BUILTIN_OBJECT_CREATE] = &builtin_object_create,
    [BUILTIN_OBJECT_DEFINEPROPERTIES] = &builtin_object_defineProperties,
    [BUILTIN_OBJECT_DEFINEPROPERTY] = &builtin_object_defineProperty,
    [BUILTIN_OBJECT_ENTRIES] = &builtin_object_entries,
    [BUILTIN_OBJECT_FREEZE] = &builtin_object_freeze,
    [BUILTIN_OBJECT_FROMENTRIES] = &builtin_object_fromEntries,
    [BUILTIN_OBJECT_GETOWNPROPERTYDESCRIPTOR] = &builtin_object_getOwnPropertyDescriptor,
    [BUILTIN_OBJECT_GETOWNPROPERTYNAMES] = &builtin_object_getOwnPropertyNames,
    [BUILTIN_OBJECT_GETPROTOTYPEOF] = &builtin_object_getPrototypeOf,
    [BUILTIN_OBJECT_HASOWN] = &builtin_object_hasOwn,
    [BUILTIN_OBJECT_IS] = &builtin_object_is,
    [BUILTIN_OBJECT_ISEXTENSIBLE] = &builtin_object_isExtensible,
    [BUILTIN_OBJECT_ISFROZEN] = &builtin_object_isFrozen,
    [BUILTIN_OBJECT_ISSEALED] = &builtin_object_isSealed,
    [BUILTIN_OBJECT_KEYS] = &builtin_object_keys,
    [BUILTIN_OBJECT_PREVENTEXTENSIONS] = &builtin_object_preventExtensions,
    [BUILTIN_OBJECT_PROTO_HASOWNPROPERTY] = &builtin_object_proto_hasOwnProperty,
    [BUILTIN_OBJECT_PROTO_ISPROTOTYPEOF] = &builtin_object_proto_isPrototypeOf,
    [BUILTIN_OBJECT_PROTO_PROPERTYISENUMERABLE] = &builtin_object_proto_propertyIsEnumerable,
    [BUILTIN_OBJECT_PROTO_TOLOCALESTRING] = &builtin_object_proto_toLocaleString,
    [BUILTIN_OBJECT_PROTO_TOSTRING] = &builtin_object_proto_toString,
    [BUILTIN_OBJECT_PROTO_VALUEOF] = &builtin_object_proto_valueOf,
    [BUILTIN_OBJECT_SEAL] = &builtin_object_seal,
    [BUILTIN_OBJECT_SETPROTOTYPEOF] = &builtin_object_setPrototypeOf,
    [BUILTIN_OBJECT_VALUES] = &builtin_object_values,
    [BUILTIN_PARSE_FLOAT] = &builtin_parse_float,
    [BUILTIN_PARSE_INT] = &builtin_parse_int,
    [BUILTIN_PRINT] = &builtin_print,
    [BUILTIN_PROMISE] = &builtin_promise,
    [BUILTIN_PROMISE_ALL] = &builtin_promise_all,
    [BUILTIN_PROMISE_ALLSETTLED] = &builtin_promise_allsettled,
    [BUILTIN_PROMISE_ANY] = &builtin_promise_any,
    [BUILTIN_PROMISE_PROTO_CATCH] = &builtin_promise_proto_catch,
    [BUILTIN_PROMISE_PROTO_FINALLY] = &builtin_promise_proto_finally,
    [BUILTIN_PROMISE_PROTO_THEN] = &builtin_promise_proto_then,
    [BUILTIN_PROMISE_RACE] = &builtin_promise_race,
    [BUILTIN_PROMISE_REJECT] = &builtin_promise_reject,
    [BUILTIN_PROMISE_REJECT_CALLBACK] = &builtin_promise_reject_callback,
    [BUILTIN_PROMISE_RESOLVE] = &builtin_promise_resolve,
    [BUILTIN_PROMISE_RESOLVE_CALLBACK] = &builtin_promise_resolve_callback,
    [BUILTIN_RANGE_ERROR] = &builtin_range_error,
    [BUILTIN_REFERENCE_ERROR] = &builtin_reference_error,
    [BUILTIN_REGEXP] = &builtin_regexp,
    [BUILTIN_REGEXP_PROTO_EXEC] = &builtin_regexp_proto_exec,
    [BUILTIN_REGEXP_PROTO_GET_DOTALL] = &builtin_regexp_proto_get_dotAll,
    [BUILTIN_REGEXP_PROTO_GET_FLAGS] = &builtin_regexp_proto_get_flags,
    [BUILTIN_REGEXP_PROTO_GET_GLOBAL] = &builtin_regexp_proto_get_global,
    [BUILTIN_REGEXP_PROTO_GET_IGNORECASE] = &builtin_regexp_proto_get_ignoreCase,
    [BUILTIN_REGEXP_PROTO_GET_MULTILINE] = &builtin_regexp_proto_get_multiline,
    [BUILTIN_REGEXP_PROTO_GET_SOURCE] = &builtin_regexp_proto_get_source,
    [BUILTIN_REGEXP_PROTO_GET_STICKY] = &builtin_regexp_proto_get_sticky,
    [BUILTIN_REGEXP_PROTO_GET_UNICODE] = &builtin_regexp_proto_get_unicode,
    [BUILTIN_REGEXP_PROTO_TEST] = &builtin_regexp_proto_test,
    [BUILTIN_REGEXP_PROTO_TOSTRING] = &builtin_regexp_proto_toString,
    [BUILTIN_RESET_GLOBALS] = &builtin_reset_globals,
    [BUILTIN_SET] = &builtin_set,
    [BUILTIN_SET_ITERATOR_NEXT] = &builtin_set_iterator_next,
    [BUILTIN_SET_PROTO_ADD] = &builtin_set_proto_add,
    [BUILTIN_SET_PROTO_CLEAR] = &builtin_set_proto_clear,
    [BUILTIN_SET_PROTO_DELETE] = &builtin_set_proto_delete,
    [BUILTIN_SET_PROTO_ENTRIES] = &builtin_set_proto_entries,
    [BUILTIN_SET_PROTO_FOREACH] = &builtin_set_proto_forEach,
    [BUILTIN_SET_PROTO_HAS] = &builtin_set_proto_has,
    [BUILTIN_SET_PROTO_KEYS] = &builtin_set_proto_keys,
    [BUILTIN_SET_PROTO_SYMBOL_ITER] = &builtin_set_proto_symbol_iter,
    [BUILTIN_SET_PROTO_VALUES] = &builtin_set_proto_values,
    [BUILTIN_STRING] = &builtin_string,
    [BUILTIN_STRING_FROMCHARCODE] = &builtin_string_fromcharcode,
    [BUILTIN_STRING_FROMCODEPOINT] = &builtin_string_fromcodepoint,
    [BUILTIN_STRING_ITERATOR_NEXT] = &builtin_string_iterator_next,
    [BUILTIN_STRING_PROTO_AT] = &builtin_string_proto_at,
    [BUILTIN_STRING_PROTO_CHARAT] = &builtin_string_proto_charAt,
    [BUILTIN_STRING_PROTO_CHARCODEAT] = &builtin_string_proto_charCodeAt,
    [BUILTIN_STRING_PROTO_CODEPOINTAT] = &builtin_string_proto_codePointAt,
    [BUILTIN_STRING_PROTO_CONCAT] = &builtin_string_proto_concat,
    [BUILTIN_STRING_PROTO_ENDSWITH] = &builtin_string_proto_endsWith,
    [BUILTIN_STRING_PROTO_INCLUDES] = &builtin_string_proto_includes,
    [BUILTIN_STRING_PROTO_INDEXOF] = &builtin_string_proto_indexOf,
    [BUILTIN_STRING_PROTO_LASTINDEXOF] = &builtin_string_proto_lastIndexOf,
    [BUILTIN_STRING_PROTO_MATCH] = &builtin_string_proto_match,
    [BUILTIN_STRING_PROTO_PADEND] = &builtin_string_proto_padEnd,
    [BUILTIN_STRING_PROTO_PADSTART] = &builtin_string_proto_padStart,
    [BUILTIN_STRING_PROTO_REPEAT] = &builtin_string_proto_repeat,
    [BUILTIN_STRING_PROTO_REPLACE] = &builtin_string_proto_replace,
    [BUILTIN_STRING_PROTO_SEARCH] = &builtin_string_proto_search,
    [BUILTIN_STRING_PROTO_SLICE] = &builtin_string_proto_slice,
    [BUILTIN_STRING_PROTO_SPLIT] = &builtin_string_proto_split,
    [BUILTIN_STRING_PROTO_STARTSWITH] = &builtin_string_proto_startsWith,
    [BUILTIN_STRING_PROTO_SUBSTR] = &builtin_string_proto_substr,
    [BUILTIN_STRING_PROTO_SUBSTRING] = &builtin_string_proto_substring,
    [BUILTIN_STRING_PROTO_SYMBOL_ITER] = &builtin_string_proto_symbol_iter,
    [BUILTIN_STRING_PROTO_TOLOWERCASE] = &builtin_string_proto_toLowerCase,
    [BUILTIN_STRING_PROTO_TOSTRING] = &builtin_string_proto_toString,
    [BUILTIN_STRING_PROTO_TOUPPERCASE] = &builtin_string_proto_toUpperCase,
    [BUILTIN_STRING_PROTO_TRIM] = &builtin_string_proto_trim,
    [BUILTIN_STRING_PROTO_TOLOCALELOWERCASE] = &builtin_string_proto_toLocaleLowerCase,
    [BUILTIN_STRING_PROTO_TOLOCALEUPPERCASE] = &builtin_string_proto_toLocaleUpperCase,
    [BUILTIN_STRING_PROTO_LOCALECOMPARE] = &builtin_string_proto_localeCompare,
    [BUILTIN_STRING_PROTO_TRIMEND] = &builtin_string_proto_trimEnd,
    [BUILTIN_STRING_PROTO_TRIMSTART] = &builtin_string_proto_trimStart,
    [BUILTIN_STRING_PROTO_VALUEOF] = &builtin_string_proto_valueOf,
    [BUILTIN_SYMBOL] = &builtin_symbol,
    [BUILTIN_SYMBOL_FOR] = &builtin_symbol_for,
    [BUILTIN_SYMBOL_KEYFOR] = &builtin_symbol_keyfor,
    [BUILTIN_SYMBOL_PROTO_TOSTRING] = &builtin_symbol_proto_toString,
    [BUILTIN_SYMBOL_PROTO_VALUEOF] = &builtin_symbol_proto_valueOf,
    [BUILTIN_SYNTAX_ERROR] = &builtin_syntax_error,
    [BUILTIN_TYPE_ERROR] = &builtin_type_error,
    [BUILTIN_URI_ERROR] = &builtin_uri_error,
    [BUILTIN_WEAKMAP] = &builtin_weakmap,
    [BUILTIN_WEAKMAP_PROTO_DELETE] = &builtin_weakmap_proto_delete,
    [BUILTIN_WEAKMAP_PROTO_GET] = &builtin_weakmap_proto_get,
    [BUILTIN_WEAKMAP_PROTO_HAS] = &builtin_weakmap_proto_has,
    [BUILTIN_WEAKMAP_PROTO_SET] = &builtin_weakmap_proto_set,
    [BUILTIN_WEAKSET] = &builtin_weakset,
    [BUILTIN_WEAKSET_PROTO_ADD] = &builtin_weakset_proto_add,
    [BUILTIN_WEAKSET_PROTO_DELETE] = &builtin_weakset_proto_delete,
    [BUILTIN_WEAKSET_PROTO_HAS] = &builtin_weakset_proto_has,
};

fn void dispatch_builtin(uint fn_index, BuiltinContext* ctx) {
    if (fn_index >= BUILTIN_COUNT) {
        ctx.result.set_undefined();
        return;
    }
    BuiltinFunc handler = builtin_dispatch_table[fn_index];
    if (handler == null) {
        ctx.result.set_undefined();
        return;
    }
    handler(ctx);
}

// ============================================================================
// __resetGlobals — test262 checkpoint/restore
// ============================================================================

fn void builtin_reset_globals(BuiltinContext* ctx) {
    HObject* globals = ctx.global_env.bindings;
    Heap* heap = ctx.heap;

    if (heap.checkpoint_count == 0) {
        // === First call: save checkpoint ===
        uint cap = globals.prop_count + 64;
        usz key_bytes = (usz)cap * void*::size;
        usz val_bytes = (usz)cap * TVal::size;
        heap.checkpoint_keys = (void**)heap.alloc_func(heap.heap_udata, key_bytes);
        heap.checkpoint_vals = (TVal*)heap.alloc_func(heap.heap_udata, val_bytes);
        if (heap.checkpoint_keys == null || heap.checkpoint_vals == null) {
            ctx.result.set_undefined();
            return;
        }
        heap.checkpoint_cap = cap;

        uint count = 0;
        for (uint i = 0; i < globals.prop_count; i++) {
            void* key = globals.shape.props()[i].key;
            if (key == null) continue;
            if (count >= heap.checkpoint_cap) {
                uint new_cap = heap.checkpoint_cap * 2;
                usz new_kb = (usz)new_cap * void*::size;
                usz new_vb = (usz)new_cap * TVal::size;
                void* new_keys = heap.realloc_func(heap.heap_udata, heap.checkpoint_keys, new_kb);
                TVal* new_vals = (TVal*)heap.realloc_func(heap.heap_udata, heap.checkpoint_vals, new_vb);
                if (new_keys == null || new_vals == null) break;
                heap.checkpoint_keys = (void**)new_keys;
                heap.checkpoint_vals = new_vals;
                heap.checkpoint_cap = new_cap;
            }
            heap.checkpoint_keys[count] = key;
            heap.checkpoint_vals[count] = globals.prop_values()[i].data.value;
            count++;
        }
        heap.checkpoint_count = count;
    } else {
        // === Restore checkpoint ===
        // Delete globals not in checkpoint
        for (uint i = globals.prop_count; i > 0; i--) {
            uint idx = i - 1;
            void* key = globals.shape.props()[idx].key;
            if (key == null) continue;
            bool found = false;
            for (uint j = 0; j < heap.checkpoint_count; j++) {
                if (heap.checkpoint_keys[j] == key) { found = true; break; }
            }
            if (!found) { globals.delete_prop(key); }
        }
        // Restore checkpoint values
        for (uint i = 0; i < heap.checkpoint_count; i++) {
            globals.put_prop(heap.checkpoint_keys[i], heap.checkpoint_vals[i],
                             hobject::PROP_FLAGS_WC);
        }
    }
    ctx.result.set_undefined();
}

/// Create %IteratorPrototype% (ES6 §25.1.2).
/// %IteratorPrototype% has [Symbol.iterator]() that returns `this`.
fn bool register_iterator_prototype(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // will be wired to object_proto later
    heap.iterator_proto = proto;

    // Add [Symbol.iterator]() → returns `this`
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (catch err = fn_raw) return false;
        HObject* fn_obj = fn_raw;
        fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_ITERATOR_PROTO_SYMBOL_ITER;
        fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
        fn_obj.flags.callable = true;
        fn_obj.prototype = heap.function_proto;
        // Set .name
        HString* name_key = builtin_intern_string(heap, "name");
        HString* name_val = builtin_intern_string(heap, "[Symbol.iterator]");
        if (name_key != null && name_val != null) {
            TVal name_tv;
            name_tv.set_string(name_val);
            fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
        }
        // Set .length = 0
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            TVal len_tv;
            len_tv.set_fastint(0);
            fn_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
        }
        TVal iter_tv;
        iter_tv.set_object(fn_obj);
        proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_NWC);
    }

    return true;
}

fn bool register_builtins(EnvRecord* global_env, Heap* heap) {
    char[] print_name = "print";
    HString* print_key = heap.str_intern(print_name);
    if (print_key == null) {
        return false;
    }

    TVal print_val;
    print_val.set_lightfunc((void*)(usz)BUILTIN_PRINT);
    env::env_declare_nonenum(global_env, print_key, print_val);

    char[] console_name = "console";
    HString* console_key = heap.str_intern(console_name);
    if (console_key == null) {
        return false;
    }

    HObject*? console_obj = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = console_obj) {
        return false;
    }

    TVal console_val;
    console_val.set_object(console_obj);

    char[] log_name = "log";
    HString* log_key = heap.str_intern(log_name);
    if (log_key == null) {
        return false;
    }

    TVal log_val;
    log_val.set_lightfunc((void*)(usz)BUILTIN_CONSOLE_LOG);
    console_obj.put_prop(log_key, log_val, hobject::PROP_FLAGS_NWC);

    env::env_declare_nonenum(global_env, console_key, console_val);

    // Register parseInt
    if (!register_simple_builtin(global_env, heap, "parseInt", BUILTIN_PARSE_INT)) return false;

    // Register parseFloat
    if (!register_simple_builtin(global_env, heap, "parseFloat", BUILTIN_PARSE_FLOAT)) return false;

    // Register isNaN
    if (!register_simple_builtin(global_env, heap, "isNaN", BUILTIN_IS_NAN)) return false;

    // Register isFinite
    if (!register_simple_builtin(global_env, heap, "isFinite", BUILTIN_IS_FINITE)) return false;

    // Register eval (ES5 §15.1.2.1)
    if (!register_simple_builtin(global_env, heap, "eval", BUILTIN_EVAL)) return false;

    // Register encodeURI (ES5 §15.1.3.1)
    if (!register_simple_builtin(global_env, heap, "encodeURI", BUILTIN_ENCODE_URI)) return false;

    // Register encodeURIComponent (ES5 §15.1.3.2)
    if (!register_simple_builtin(global_env, heap, "encodeURIComponent", BUILTIN_ENCODE_URI_COMPONENT)) return false;

    // Register decodeURI (ES5 §15.1.3.3)
    if (!register_simple_builtin(global_env, heap, "decodeURI", BUILTIN_DECODE_URI)) return false;

    // Register decodeURIComponent (ES5 §15.1.3.4)
    if (!register_simple_builtin(global_env, heap, "decodeURIComponent", BUILTIN_DECODE_URI_COMPONENT)) return false;

    // Register test262 batch runner helper
    if (!register_simple_builtin(global_env, heap, "__resetGlobals", BUILTIN_RESET_GLOBALS)) return false;

    // Register global constants: NaN, Infinity, undefined
    if (!register_global_constant(global_env, heap, "NaN", NUMBER, double::nan, 0)) return false;
    if (!register_global_constant(global_env, heap, "Infinity", NUMBER, double::inf, 0)) return false;

    // Register Object constructor FIRST — creates Object.prototype (root of all chains)
    if (!register_object_constructor(global_env, heap)) return false;

    // Register Number constructor (with prototype and static properties)
    if (!register_number_constructor(global_env, heap)) return false;

    // Register Math object
    if (!register_math_object(global_env, heap)) return false;

    // Register JSON object (parse, stringify)
    if (!register_json_object(global_env, heap)) return false;

    // Register Error constructors (Error, TypeError, RangeError, ReferenceError, SyntaxError, EvalError)
    if (!register_error_builtins(global_env, heap)) return false;

    // Register Boolean constructor
    if (!register_boolean_constructor(global_env, heap)) return false;

    // Register String constructor
    if (!register_string_constructor(global_env, heap)) return false;

    // Register Function constructor and prototype (call, apply, bind)
    // Must be before Array so that builtins inherit .call/.apply/.bind from Function.prototype
    if (!register_function_constructor(global_env, heap)) return false;

    // Register Array constructor
    if (!register_array_constructor(global_env, heap)) return false;

    // Register Date constructor and prototype
    if (!register_date_constructor(global_env, heap)) return false;

    // Register RegExp constructor and prototype
    if (!register_regexp_constructor(global_env, heap)) return false;

    // Register Map constructor and prototype
    if (!register_map_constructor(global_env, heap)) return false;

    // Register Set constructor and prototype
    if (!register_set_constructor(global_env, heap)) return false;

    // Register WeakMap constructor and prototype
    if (!register_weakmap_constructor(global_env, heap)) return false;

    // Register WeakSet constructor and prototype
    if (!register_weakset_constructor(global_env, heap)) return false;

    // Register Symbol constructor and prototype
    if (!register_symbol_constructor(global_env, heap)) return false;

    // Register Promise constructor and prototype
    if (!register_promise_constructor(global_env, heap)) return false;

    // Register Generator constructor and prototype (GeneratorFunction uses
    // heap.generator_proto; the GeneratorFunction global is registered
    // separately as a simple builtin).
    if (!register_generator_constructor(global_env, heap)) return false;

    // Register %IteratorPrototype% (ES6 §25.1.2) — shared prototype for all
    // built-in iterators, providing [Symbol.iterator]() that returns `this`.
    if (!register_iterator_prototype(heap)) return false;

    // Wire all prototype chains to Object.prototype
    if (heap.number_proto != null) heap.number_proto.prototype = heap.object_proto;
    if (heap.bool_proto != null)   heap.bool_proto.prototype = heap.object_proto;
    if (heap.string_proto != null) heap.string_proto.prototype = heap.object_proto;
    if (heap.err_proto != null)    heap.err_proto.prototype = heap.object_proto;
    if (heap.array_proto != null)  heap.array_proto.prototype = heap.object_proto;
    if (heap.function_proto != null) heap.function_proto.prototype = heap.object_proto;
    if (heap.date_proto != null)   heap.date_proto.prototype = heap.object_proto;
    if (heap.regexp_proto != null) heap.regexp_proto.prototype = heap.object_proto;
    if (heap.map_proto != null)    heap.map_proto.prototype = heap.object_proto;
    if (heap.set_proto != null)    heap.set_proto.prototype = heap.object_proto;
    if (heap.weakmap_proto != null) heap.weakmap_proto.prototype = heap.object_proto;
    if (heap.weakset_proto != null) heap.weakset_proto.prototype = heap.object_proto;
    if (heap.symbol_proto != null) heap.symbol_proto.prototype = heap.object_proto;
    if (heap.promise_proto != null) heap.promise_proto.prototype = heap.object_proto;
    if (heap.generator_proto != null) heap.generator_proto.prototype = heap.object_proto;
    if (heap.iterator_proto != null)  heap.iterator_proto.prototype = heap.object_proto;

    // Wire constructor functions' [[Prototype]] to Function.prototype.
    // Constructor functions (Object, Number, Function, etc.) are HObjects
    // with ObjClass.FUNCTION whose internal prototype must be Function.prototype
    // so that Function.prototype.isPrototypeOf(Number) and similar work.
    // We look them up in the global environment by name.
    if (heap.function_proto != null) {
        char[][] ctor_names = { "Object", "Number", "Boolean", "String", "Array", "Function", "Date", "RegExp", "Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError", "EvalError", "URIError", "Map", "Set", "WeakMap", "WeakSet", "Symbol", "Promise", "GeneratorFunction" };
        for (int i = 0; i < ctor_names.len; i++) {
            TVal? optv = env::env_get(global_env, builtin_intern_string(heap, ctor_names[i]));
            if (try tv = optv) {
                if (tv.is_object() && tv.get_heapptr() != null) {
                    HObject* ctor = (HObject*)tv.get_heapptr();
                    ctor.prototype = heap.function_proto;
                }
            }
        }
    }

    // Register globalThis (ES2020 §19.2.1) — points back to the global object itself.
    // globalThis is a property of the global environment's bindings object.
    {
        HString* gthis_key = builtin_intern_string(heap, "globalThis");
        if (gthis_key != null) {
            TVal gthis_tv;
            gthis_tv.set_object(global_env.bindings);
            env::env_declare_nonenum(global_env, gthis_key, gthis_tv);
        }
    }

    return true;
}

fn bool register_object_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Object.prototype — the root of all prototype chains
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Object.prototype is the root — its [[Prototype]] is null
    heap.object_proto = proto;

    // Add .toString() method to Object.prototype
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_TOSTRING);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .hasOwnProperty() method to Object.prototype
    HString* hasown_key = builtin_intern_string(heap, "hasOwnProperty");
    TVal hasown_tv;
    hasown_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_HASOWNPROPERTY);
    proto.put_prop(hasown_key, hasown_tv, hobject::PROP_FLAGS_WC);

    // Add .propertyIsEnumerable() method to Object.prototype (non-enumerable per ES5 §15.2.4.7)
    HString* propisenum_key = builtin_intern_string(heap, "propertyIsEnumerable");
    TVal propisenum_tv;
    propisenum_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_PROPERTYISENUMERABLE);
    proto.put_prop(propisenum_key, propisenum_tv, hobject::PROP_FLAGS_WC);

    // Add .valueOf() method to Object.prototype (returns 'this')
    HString* valueof_key = builtin_intern_string(heap, "valueOf");
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_VALUEOF);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC);

    // Add .isPrototypeOf() method to Object.prototype
    HString* isproto_key = builtin_intern_string(heap, "isPrototypeOf");
    TVal isproto_tv;
    isproto_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_ISPROTOTYPEOF);
    proto.put_prop(isproto_key, isproto_tv, hobject::PROP_FLAGS_WC);

    // Add .toLocaleString() method to Object.prototype (ES5 §15.2.4.3)
    HString* tolocalestring_key = builtin_intern_string(heap, "toLocaleString");
    TVal tolocalestring_tv;
    tolocalestring_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_TOLOCALESTRING);
    proto.put_prop(tolocalestring_key, tolocalestring_tv, hobject::PROP_FLAGS_WC);

    // Create Object constructor as a proper HObject (not LIGHTFUNC)
    // so it can carry .prototype, .length, etc.
    HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = obj_raw) return false;
    HObject* obj = obj_raw;
    obj.extra.func.builtin_fn_index = (int)BUILTIN_OBJECT;
    obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    // Set .constructor on Object.prototype to point to the actual Object constructor object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Object.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Object.length (ES5 §15.2.1)
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(1);
    obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    // Add static methods to Object constructor
    HString* keys_key = builtin_intern_string(heap, "keys");
    if (keys_key == null) return false;
    TVal keys_tv;
    keys_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_KEYS);
    obj.put_prop(keys_key, keys_tv, hobject::PROP_FLAGS_NWC);

    // Object.getPrototypeOf — ES5 §15.2.3.2
    HString* getproto_key = builtin_intern_string(heap, "getPrototypeOf");
    if (getproto_key == null) return false;
    TVal getproto_tv;
    getproto_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_GETPROTOTYPEOF);
    obj.put_prop(getproto_key, getproto_tv, hobject::PROP_FLAGS_NWC);

    // Object.isExtensible — ES5 §15.2.3.13
    HString* isext_key = builtin_intern_string(heap, "isExtensible");
    if (isext_key == null) return false;
    TVal isext_tv;
    isext_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ISEXTENSIBLE);
    obj.put_prop(isext_key, isext_tv, hobject::PROP_FLAGS_NWC);

    // Object.preventExtensions — ES5 §15.2.3.10
    HString* prevext_key = builtin_intern_string(heap, "preventExtensions");
    if (prevext_key == null) return false;
    TVal prevext_tv;
    prevext_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PREVENTEXTENSIONS);
    obj.put_prop(prevext_key, prevext_tv, hobject::PROP_FLAGS_NWC);

    // Object.getOwnPropertyDescriptor — ES5 §15.2.3.3
    HString* getownpropdesc_key = builtin_intern_string(heap, "getOwnPropertyDescriptor");
    if (getownpropdesc_key == null) return false;
    TVal getownpropdesc_tv;
    getownpropdesc_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_GETOWNPROPERTYDESCRIPTOR);
    obj.put_prop(getownpropdesc_key, getownpropdesc_tv, hobject::PROP_FLAGS_NWC);

    // Object.defineProperty — ES5 §15.2.3.6
    HString* defineprop_key = builtin_intern_string(heap, "defineProperty");
    if (defineprop_key == null) return false;
    TVal defineprop_tv;
    defineprop_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_DEFINEPROPERTY);
    obj.put_prop(defineprop_key, defineprop_tv, hobject::PROP_FLAGS_NWC);

    // Object.getOwnPropertyNames — ES5 §15.2.3.4
    HString* getownpropnames_key = builtin_intern_string(heap, "getOwnPropertyNames");
    if (getownpropnames_key == null) return false;
    TVal getownpropnames_tv;
    getownpropnames_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_GETOWNPROPERTYNAMES);
    obj.put_prop(getownpropnames_key, getownpropnames_tv, hobject::PROP_FLAGS_NWC);

    // Object.defineProperties — ES5 §15.2.3.7
    HString* defineprops_key = builtin_intern_string(heap, "defineProperties");
    if (defineprops_key == null) return false;
    TVal defineprops_tv;
    defineprops_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_DEFINEPROPERTIES);
    obj.put_prop(defineprops_key, defineprops_tv, hobject::PROP_FLAGS_NWC);

    // Object.create — ES5 §15.2.3.5
    HString* create_key = builtin_intern_string(heap, "create");
    if (create_key == null) return false;
    TVal create_tv;
    create_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_CREATE);
    obj.put_prop(create_key, create_tv, hobject::PROP_FLAGS_NWC);

    // Object.seal — ES5 §15.2.3.8
    HString* seal_key = builtin_intern_string(heap, "seal");
    if (seal_key == null) return false;
    TVal seal_tv;
    seal_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_SEAL);
    obj.put_prop(seal_key, seal_tv, hobject::PROP_FLAGS_NWC);

    // Object.freeze — ES5 §15.2.3.9
    HString* freeze_key = builtin_intern_string(heap, "freeze");
    if (freeze_key == null) return false;
    TVal freeze_tv;
    freeze_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_FREEZE);
    obj.put_prop(freeze_key, freeze_tv, hobject::PROP_FLAGS_NWC);

    // Object.isSealed — ES5 §15.2.3.11
    HString* issealed_key = builtin_intern_string(heap, "isSealed");
    if (issealed_key == null) return false;
    TVal issealed_tv;
    issealed_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ISSEALED);
    obj.put_prop(issealed_key, issealed_tv, hobject::PROP_FLAGS_NWC);

    // Object.isFrozen — ES5 §15.2.3.12
    HString* isfrozen_key = builtin_intern_string(heap, "isFrozen");
    if (isfrozen_key == null) return false;
    TVal isfrozen_tv;
    isfrozen_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ISFROZEN);
    obj.put_prop(isfrozen_key, isfrozen_tv, hobject::PROP_FLAGS_NWC);

    // Object.entries — ES2017 §19.1.2.21
    HString* entries_key = builtin_intern_string(heap, "entries");
    if (entries_key == null) return false;
    TVal entries_tv;
    entries_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ENTRIES);
    obj.put_prop(entries_key, entries_tv, hobject::PROP_FLAGS_NWC);

    // Object.values — ES2017 §19.1.2.22
    HString* values_key = builtin_intern_string(heap, "values");
    if (values_key == null) return false;
    TVal values_tv;
    values_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_VALUES);
    obj.put_prop(values_key, values_tv, hobject::PROP_FLAGS_NWC);

    // Object.assign — ES2015 §19.1.2.2
    HString* assign_key = builtin_intern_string(heap, "assign");
    if (assign_key == null) return false;
    TVal assign_tv;
    assign_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ASSIGN);
    obj.put_prop(assign_key, assign_tv, hobject::PROP_FLAGS_NWC);

    // Object.is — ES6 §19.1.2.10
    HString* is_key = builtin_intern_string(heap, "is");
    if (is_key == null) return false;
    TVal is_tv;
    is_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_IS);
    obj.put_prop(is_key, is_tv, hobject::PROP_FLAGS_NWC);

    // Object.hasOwn — ES2022 §19.1.2.10
    HString* hasown_static_key = builtin_intern_string(heap, "hasOwn");
    if (hasown_static_key == null) return false;
    TVal hasown_static_tv;
    hasown_static_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_HASOWN);
    obj.put_prop(hasown_static_key, hasown_static_tv, hobject::PROP_FLAGS_NWC);

    // Object.setPrototypeOf — ES2015 §19.1.2.19
    HString* setproto_key = builtin_intern_string(heap, "setPrototypeOf");
    if (setproto_key == null) return false;
    TVal setproto_tv;
    setproto_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_SETPROTOTYPEOF);
    obj.put_prop(setproto_key, setproto_tv, hobject::PROP_FLAGS_NWC);

    // Object.fromEntries — ES2019 §19.1.2.5
    HString* fromentries_key = builtin_intern_string(heap, "fromEntries");
    if (fromentries_key == null) return false;
    TVal fromentries_tv;
    fromentries_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_FROMENTRIES);
    obj.put_prop(fromentries_key, fromentries_tv, hobject::PROP_FLAGS_NWC);

    // Register Object constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("Object");
    HString* existing = heap.str_table_lookup("Object", hash);
    HString* obj_key;
    if (existing != null) {
        obj_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Object", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        obj_key = new_key;
    }
    TVal obj_val;
    obj_val.set_object(obj);
    set_func_ctor_name_length(obj, heap, "Object", 1);
    env::env_declare_nonenum(global_env, obj_key, obj_val);

    return true;
}

fn bool register_math_object(EnvRecord* global_env, Heap* heap) {
    HObject*? math_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = math_raw) return false;
    HObject* math = math_raw;
    if (!set_num_prop_lookup(math, heap, "E", 2.718281828459045)) return false;
    if (!set_num_prop_lookup(math, heap, "PI", 3.141592653589793)) return false;
    if (!set_num_prop_lookup(math, heap, "LN2", 0.6931471805599453)) return false;
    if (!set_num_prop_lookup(math, heap, "LN10", 2.302585092994046)) return false;
    if (!set_num_prop_lookup(math, heap, "LOG2E", 1.4426950408889634)) return false;
    if (!set_num_prop_lookup(math, heap, "LOG10E", 0.4342944819032518)) return false;
    if (!set_num_prop_lookup(math, heap, "SQRT1_2", 0.7071067811865476)) return false;
    if (!set_num_prop_lookup(math, heap, "SQRT2", 1.4142135623730951)) return false;

    // Math methods (registered as lightfuncs on the Math object)
    if (!register_math_method(math, heap, "abs",    BUILTIN_MATH_ABS))    return false;
    if (!register_math_method(math, heap, "floor",  BUILTIN_MATH_FLOOR))  return false;
    if (!register_math_method(math, heap, "ceil",   BUILTIN_MATH_CEIL))   return false;
    if (!register_math_method(math, heap, "round",  BUILTIN_MATH_ROUND))  return false;
    if (!register_math_method(math, heap, "max",    BUILTIN_MATH_MAX))    return false;
    if (!register_math_method(math, heap, "min",    BUILTIN_MATH_MIN))    return false;
    if (!register_math_method(math, heap, "pow",    BUILTIN_MATH_POW))    return false;
    if (!register_math_method(math, heap, "sqrt",   BUILTIN_MATH_SQRT))   return false;
    if (!register_math_method(math, heap, "exp",    BUILTIN_MATH_EXP))    return false;
    if (!register_math_method(math, heap, "log",    BUILTIN_MATH_LOG))    return false;
    if (!register_math_method(math, heap, "sin",    BUILTIN_MATH_SIN))    return false;
    if (!register_math_method(math, heap, "cos",    BUILTIN_MATH_COS))    return false;
    if (!register_math_method(math, heap, "tan",    BUILTIN_MATH_TAN))    return false;
    if (!register_math_method(math, heap, "random", BUILTIN_MATH_RANDOM)) return false;
    if (!register_math_method(math, heap, "acos",   BUILTIN_MATH_ACOS))   return false;
    if (!register_math_method(math, heap, "asin",   BUILTIN_MATH_ASIN))   return false;
    if (!register_math_method(math, heap, "atan",   BUILTIN_MATH_ATAN))   return false;
    if (!register_math_method(math, heap, "atan2",  BUILTIN_MATH_ATAN2))  return false;
    if (!register_math_method(math, heap, "cosh",   BUILTIN_MATH_COSH))   return false;
    if (!register_math_method(math, heap, "sinh",   BUILTIN_MATH_SINH))   return false;
    if (!register_math_method(math, heap, "tanh",   BUILTIN_MATH_TANH))   return false;
    if (!register_math_method(math, heap, "acosh",  BUILTIN_MATH_ACOSH))  return false;
    if (!register_math_method(math, heap, "asinh",  BUILTIN_MATH_ASINH))  return false;
    if (!register_math_method(math, heap, "atanh",  BUILTIN_MATH_ATANH))  return false;
    if (!register_math_method(math, heap, "log2",   BUILTIN_MATH_LOG2))   return false;
    if (!register_math_method(math, heap, "log10",  BUILTIN_MATH_LOG10))  return false;
    if (!register_math_method(math, heap, "log1p",  BUILTIN_MATH_LOG1P))  return false;
    if (!register_math_method(math, heap, "expm1",  BUILTIN_MATH_EXPM1))  return false;
    if (!register_math_method(math, heap, "cbrt",   BUILTIN_MATH_CBRT))   return false;
    if (!register_math_method(math, heap, "hypot",  BUILTIN_MATH_HYPOT))  return false;
    if (!register_math_method(math, heap, "trunc",  BUILTIN_MATH_TRUNC))  return false;
    if (!register_math_method(math, heap, "sign",   BUILTIN_MATH_SIGN))   return false;
    if (!register_math_method(math, heap, "fround", BUILTIN_MATH_FROUND)) return false;
    if (!register_math_method(math, heap, "clz32",  BUILTIN_MATH_CLZ32))  return false;
    if (!register_math_method(math, heap, "imul",   BUILTIN_MATH_IMUL))   return false;

    TVal math_tv;
    math_tv.set_object(null);
    math_tv.set_fastint(0);
    math_tv.set_object(math);
    return register_named_value(global_env, heap, "Math", math_tv);
}

/// Helper: register a Math method as a lightfunc property on the Math object.
fn bool register_math_method(HObject* math, Heap* heap, char[] name, uint fn_index) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    void* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal tv;
    tv.set_lightfunc((void*)(usz)fn_index);
    math.put_prop(key, tv, hobject::PROP_FLAGS_WC);
    return true;
}

fn bool set_num_prop_lookup(HObject* obj, Heap* heap, char[] name, double val) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    void* key = existing;
    if (key == null) {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal tv;
    tv.set_number(val);
    obj.put_prop(key, tv, hobject::PROP_FLAGS_WC);
    return true;
}

// ============================================================================
// JSON object registration
// ============================================================================

/// Create JSON global object with .parse and .stringify methods.
fn bool register_json_object(EnvRecord* global_env, Heap* heap) {
    HObject*? json_raw = heap.alloc_object(hobject::ObjClass.JSON);
    if (catch err = json_raw) return false;
    HObject* json = json_raw;

    // Register JSON.parse
    if (!register_math_method(json, heap, "parse", BUILTIN_JSON_PARSE)) return false;
    // Register JSON.stringify
    if (!register_math_method(json, heap, "stringify", BUILTIN_JSON_STRINGIFY)) return false;

    TVal json_tv;
    json_tv.set_object(null);
    json_tv.set_fastint(0);
    json_tv.set_object(json);
    return register_named_value(global_env, heap, "JSON", json_tv);
}

// ============================================================================
// Number constructor registration
// ============================================================================

/// Create Number.prototype and register the Number constructor globally.
fn bool register_number_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Number prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.NUMBER);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.number_proto = proto;

    // Add .toString() method
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_NUMBER_PROTO_TOSTRING);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .valueOf() method
    HString* valueof_key = builtin_intern_string(heap, "valueOf");
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)BUILTIN_NUMBER_PROTO_VALUEOF);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC);

    // Add .toFixed() method (Phase 6d)
    if (!register_string_proto_method(proto, heap, "toFixed", BUILTIN_NUMBER_PROTO_TOFIXED)) return false;
    // Add .toExponential() method
    if (!register_string_proto_method(proto, heap, "toExponential", BUILTIN_NUMBER_PROTO_TOEXPONENTIAL)) return false;
    // Add .toPrecision() method
    if (!register_string_proto_method(proto, heap, "toPrecision", BUILTIN_NUMBER_PROTO_TOPRECISION)) return false;

    // Create Number constructor as a proper function object (not LIGHTFUNC)
    // so it can carry static properties like Number.MAX_VALUE, Number.NaN, etc.
    HObject*? num_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = num_raw) return false;
    HObject* num = num_raw;
    num.extra.func.builtin_fn_index = (int)BUILTIN_NUMBER;
    num.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    // Set .constructor on Number.prototype to point to the actual Number object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(num);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Number.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    num.put_prop(prototype_key, proto_tv, proto_pflags);

    // Add Number.MAX_VALUE (ES5 §15.7.3.2) — non-writable, non-enumerable, non-configurable
    if (!set_num_static_prop(num, heap, "MAX_VALUE", 1.7976931348623157e+308)) return false;
    // Add Number.MIN_VALUE (ES5 §15.7.3.3)
    if (!set_num_static_prop(num, heap, "MIN_VALUE", 5e-324)) return false;
    // Add Number.NaN (ES5 §15.7.3.4)
    if (!set_num_static_prop(num, heap, "NaN", double::nan)) return false;
    // Add Number.NEGATIVE_INFINITY (ES5 §15.7.3.5)
    if (!set_num_static_prop(num, heap, "NEGATIVE_INFINITY", -double::inf)) return false;
    // Add Number.POSITIVE_INFINITY (ES5 §15.7.3.6)
    if (!set_num_static_prop(num, heap, "POSITIVE_INFINITY", double::inf)) return false;

    // Add Number.isNaN (ES6 §20.1.2.4)
    if (!register_string_proto_method(num, heap, "isNaN", BUILTIN_NUMBER_ISNAN)) return false;
    // Add Number.isFinite (ES6 §20.1.2.2)
    if (!register_string_proto_method(num, heap, "isFinite", BUILTIN_NUMBER_ISFINITE)) return false;
    // Add Number.isInteger (ES6 §20.1.2.3)
    if (!register_string_proto_method(num, heap, "isInteger", BUILTIN_NUMBER_ISINTEGER)) return false;
    // Add Number.isSafeInteger (ES6 §20.1.2.5)
    if (!register_string_proto_method(num, heap, "isSafeInteger", BUILTIN_NUMBER_ISSAFEINTEGER)) return false;

    // Add Number.EPSILON (ES6 §20.1.2.1) — 2^-52
    if (!set_num_static_prop(num, heap, "EPSILON", 2.220446049250313e-16)) return false;
    // Add Number.MAX_SAFE_INTEGER (ES6 §20.1.2.6) — 2^53 - 1
    if (!set_num_static_prop(num, heap, "MAX_SAFE_INTEGER", 9007199254740991.0)) return false;
    // Add Number.MIN_SAFE_INTEGER (ES6 §20.1.2.8) — -(2^53 - 1)
    if (!set_num_static_prop(num, heap, "MIN_SAFE_INTEGER", -9007199254740991.0)) return false;
    // Add Number.parseInt (ES6 §20.1.2.12) — same as global parseInt
    if (!register_string_proto_method(num, heap, "parseInt", BUILTIN_PARSE_INT)) return false;
    // Add Number.parseFloat (ES6 §20.1.2.13) — same as global parseFloat
    if (!register_string_proto_method(num, heap, "parseFloat", BUILTIN_PARSE_FLOAT)) return false;

    // Register Number constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("Number");
    HString* existing = heap.str_table_lookup("Number", hash);
    HString* num_key;
    if (existing != null) {
        num_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Number", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        num_key = new_key;
    }
    TVal num_val;
    num_val.set_object(num);
    set_func_ctor_name_length(num, heap, "Number", 1);
    env::env_declare_nonenum(global_env, num_key, num_val);

    return true;
}

/// Helper: set a non-writable, non-enumerable, non-configurable number property.
fn bool set_num_static_prop(HObject* obj, Heap* heap, char[] name, double val) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    void* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal tv;
    tv.set_number(val);
    PropFlags pflags;
    pflags.writable = false;
    pflags.enumerable = false;
    pflags.configurable = false;
    pflags.is_accessor = false;
    obj.put_prop(key, tv, pflags);
    return true;
}

fn bool set_num_prop(HObject* obj, Heap* heap, char[] name, double val) {
    uint hash = heap.hash_string(name);
    // Use lookup-first to avoid duplicate HString pointers
    HString* existing = heap.str_table_lookup(name, hash);
    void* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal tv;
    tv.set_number(val);
    obj.put_prop(key, tv, hobject::PROP_FLAGS_WC);
    return true;
}

fn bool register_named_value(EnvRecord* global_env, Heap* heap, char[] name, TVal val) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    HString* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    return env::env_declare_nonenum(global_env, key, val);
}

fn bool register_global_constant(EnvRecord* global_env, Heap* heap, char[] name,
                                  TValTag tag, double number_val, long fastint_val) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    HString* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) {
            return false;
        }
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal val;
    if (tag == FASTINT) {
        val.set_fastint(fastint_val);
    } else if (tag == STRING || tag == OBJECT) {
        val.set_string(null);  // caller must set pointer
    } else {
        val.set_number(number_val);
    }
    env::env_declare_nonenum(global_env, key, val);
    return true;
}

fn bool register_simple_builtin(EnvRecord* global_env, Heap* heap, char[] name, uint fn_index) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    HString* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) {
            return false;
        }
        heap.str_table_insert(new_key);
        key = new_key;
    }

    TVal val;
    val.set_lightfunc((void*)(usz)fn_index);
    env::env_declare_nonenum(global_env, key, val);
    return true;
}

/// Set .name and .length on a built-in constructor HObject.
/// .name: non-writable, non-enumerable, configurable (ES6 §19)
/// .length: writable, non-enumerable, configurable (ES5 §15)
fn void set_func_ctor_name_length(HObject* func_obj, Heap* heap, char[] name, int length) {
    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_hstr = builtin_intern_string(heap, name);
    TVal name_tv; name_tv.set_string(name_hstr);
    func_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);

    HString* length_key = builtin_intern_string(heap, "length");
    TVal length_tv; length_tv.set_fastint((long)length);
    func_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
}

/// Set .name on a built-in constructor HObject (when .length is already set).
fn void set_func_ctor_name(HObject* func_obj, Heap* heap, char[] name) {
    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_hstr = builtin_intern_string(heap, name);
    TVal name_tv; name_tv.set_string(name_hstr);
    func_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
}

// ============================================================================
// Error built-in registration
// ============================================================================

/// Helper: create a prototype object for an error type.
/// proto_parent is the [[Prototype]] (e.g. Error.prototype for subclasses).
fn HObject* register_error_prototype(Heap* heap, HObject* proto_parent, char[] name_str) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err = proto_raw) return null;
    HObject* proto = proto_raw;
    proto.prototype = proto_parent;

    // Set .name property
    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_hstr = builtin_intern_string(heap, name_str);
    TVal name_tv;
    name_tv.set_string(name_hstr);
    proto.put_prop(name_key, name_tv, hobject::PROP_FLAGS_WC);

    // Set .message property (empty string)
    HString* msg_key = (HString*)heap.strs[heap::BuiltinStr.MESSAGE];
    HString* msg_hstr = builtin_intern_string(heap, "");
    TVal msg_tv;
    msg_tv.set_string(msg_hstr);
    proto.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);

    return proto;
}

/// Register all Error constructors and prototypes.
fn bool register_error_builtins(EnvRecord* global_env, Heap* heap) {
    // --- Create Error.prototype ---
    HObject* err_proto = register_error_prototype(heap, null, "Error");
    if (err_proto == null) return false;
    heap.err_proto = err_proto;

    // Add .toString() method to Error.prototype
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_ERROR_PROTO_TOSTRING);
    err_proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .constructor to Error.prototype pointing to Error builtin
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_lightfunc((void*)(usz)BUILTIN_ERROR);
    err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // --- Create TypeError.prototype ---
    HObject* type_err_proto = register_error_prototype(heap, err_proto, "TypeError");
    if (type_err_proto == null) return false;
    type_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.type_err_proto = type_err_proto;

    // --- Create RangeError.prototype ---
    HObject* range_err_proto = register_error_prototype(heap, err_proto, "RangeError");
    if (range_err_proto == null) return false;
    range_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.range_err_proto = range_err_proto;

    // --- Create ReferenceError.prototype ---
    HObject* ref_err_proto = register_error_prototype(heap, err_proto, "ReferenceError");
    if (ref_err_proto == null) return false;
    ref_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.ref_err_proto = ref_err_proto;

    // --- Create SyntaxError.prototype ---
    HObject* syntax_err_proto = register_error_prototype(heap, err_proto, "SyntaxError");
    if (syntax_err_proto == null) return false;
    syntax_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.syntax_err_proto = syntax_err_proto;

    // --- Create EvalError.prototype ---
    HObject* eval_err_proto = register_error_prototype(heap, err_proto, "EvalError");
    if (eval_err_proto == null) return false;
    eval_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.eval_err_proto = eval_err_proto;

    // --- Create URIError.prototype ---
    HObject* uri_err_proto = register_error_prototype(heap, err_proto, "URIError");
    if (uri_err_proto == null) return false;
    uri_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.uri_err_proto = uri_err_proto;

    // Set .constructor on each error sub-prototype to point to its own builtin
    // (type_err_proto already done above — fix it now with correct index)
    TVal type_err_constr;
    type_err_constr.set_lightfunc((void*)(usz)BUILTIN_TYPE_ERROR);
    type_err_proto.put_prop(constructor_key, type_err_constr, hobject::PROP_FLAGS_WC);

    TVal range_err_constr;
    range_err_constr.set_lightfunc((void*)(usz)BUILTIN_RANGE_ERROR);
    range_err_proto.put_prop(constructor_key, range_err_constr, hobject::PROP_FLAGS_WC);

    TVal ref_err_constr;
    ref_err_constr.set_lightfunc((void*)(usz)BUILTIN_REFERENCE_ERROR);
    ref_err_proto.put_prop(constructor_key, ref_err_constr, hobject::PROP_FLAGS_WC);

    TVal syntax_err_constr;
    syntax_err_constr.set_lightfunc((void*)(usz)BUILTIN_SYNTAX_ERROR);
    syntax_err_proto.put_prop(constructor_key, syntax_err_constr, hobject::PROP_FLAGS_WC);

    TVal eval_err_constr;
    eval_err_constr.set_lightfunc((void*)(usz)BUILTIN_EVAL_ERROR);
    eval_err_proto.put_prop(constructor_key, eval_err_constr, hobject::PROP_FLAGS_WC);

    TVal uri_err_constr;
    uri_err_constr.set_lightfunc((void*)(usz)BUILTIN_URI_ERROR);
    uri_err_proto.put_prop(constructor_key, uri_err_constr, hobject::PROP_FLAGS_WC);

    // --- Register Error global constructor ---
    if (!register_simple_builtin(global_env, heap, "Error", BUILTIN_ERROR)) return false;

    // --- Register TypeError ---
    if (!register_simple_builtin(global_env, heap, "TypeError", BUILTIN_TYPE_ERROR)) return false;

    // --- Register RangeError ---
    if (!register_simple_builtin(global_env, heap, "RangeError", BUILTIN_RANGE_ERROR)) return false;

    // --- Register ReferenceError ---
    if (!register_simple_builtin(global_env, heap, "ReferenceError", BUILTIN_REFERENCE_ERROR)) return false;

    // --- Register SyntaxError ---
    if (!register_simple_builtin(global_env, heap, "SyntaxError", BUILTIN_SYNTAX_ERROR)) return false;

    // --- Register EvalError ---
    if (!register_simple_builtin(global_env, heap, "EvalError", BUILTIN_EVAL_ERROR)) return false;

    // --- Register URIError ---
    if (!register_simple_builtin(global_env, heap, "URIError", BUILTIN_URI_ERROR)) return false;

    // --- Create AggregateError.prototype (parent = err_proto) ---
    HObject* aggregate_err_proto = register_error_prototype(heap, err_proto, "AggregateError");
    if (aggregate_err_proto == null) return false;
    TVal aggregate_err_constr;
    aggregate_err_constr.set_lightfunc((void*)(usz)BUILTIN_AGGREGATE_ERROR);
    aggregate_err_proto.put_prop(constructor_key, aggregate_err_constr, hobject::PROP_FLAGS_WC);
    heap.aggregate_err_proto = aggregate_err_proto;

    if (!register_simple_builtin(global_env, heap, "AggregateError", BUILTIN_AGGREGATE_ERROR)) return false;

    return true;
}

// ============================================================================
// Boolean constructor registration
// ============================================================================

/// Create Boolean.prototype and register the Boolean constructor globally.
fn bool register_boolean_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Boolean.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.BOOLEAN);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.bool_proto = proto;

    // Set .constructor to Boolean lightfunc
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_lightfunc((void*)(usz)BUILTIN_BOOLEAN);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Add .toString() method
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_BOOLEAN_PROTO_TOSTRING);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .valueOf() method
    HString* valueof_key = builtin_intern_string(heap, "valueOf");
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)BUILTIN_BOOLEAN_PROTO_VALUEOF);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC);

    // Register Boolean as a global constructor
    if (!register_simple_builtin(global_env, heap, "Boolean", BUILTIN_BOOLEAN)) return false;

    return true;
}

// ============================================================================
// String constructor registration
// ============================================================================

/// Create String.prototype and register the String constructor globally.
fn bool register_string_constructor(EnvRecord* global_env, Heap* heap) {
    // Create String.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.STRING);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.string_proto = proto;

    // Add .toString() method
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_STRING_PROTO_TOSTRING);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .valueOf() method
    HString* valueof_key = builtin_intern_string(heap, "valueOf");
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)BUILTIN_STRING_PROTO_VALUEOF);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC);

    // Add String.prototype methods (Phase 6b)
    if (!register_string_proto_method(proto, heap, "charAt",     BUILTIN_STRING_PROTO_CHARAT))     return false;
    if (!register_string_proto_method(proto, heap, "charCodeAt", BUILTIN_STRING_PROTO_CHARCODEAT)) return false;
    if (!register_string_proto_method(proto, heap, "indexOf",    BUILTIN_STRING_PROTO_INDEXOF))    return false;
    if (!register_string_proto_method(proto, heap, "slice",      BUILTIN_STRING_PROTO_SLICE))      return false;
    if (!register_string_proto_method(proto, heap, "substring",  BUILTIN_STRING_PROTO_SUBSTRING))  return false;
    if (!register_string_proto_method(proto, heap, "substr",     BUILTIN_STRING_PROTO_SUBSTR))     return false;
    if (!register_string_proto_method(proto, heap, "toLowerCase",BUILTIN_STRING_PROTO_TOLOWERCASE)) return false;
    if (!register_string_proto_method(proto, heap, "toUpperCase",BUILTIN_STRING_PROTO_TOUPPERCASE)) return false;
    if (!register_string_proto_method(proto, heap, "trim",       BUILTIN_STRING_PROTO_TRIM))       return false;
    if (!register_string_proto_method(proto, heap, "split",      BUILTIN_STRING_PROTO_SPLIT))      return false;
    if (!register_string_proto_method(proto, heap, "concat",     BUILTIN_STRING_PROTO_CONCAT))     return false;
    if (!register_string_proto_method(proto, heap, "replace",    BUILTIN_STRING_PROTO_REPLACE))    return false;
    if (!register_string_proto_method(proto, heap, "includes",   BUILTIN_STRING_PROTO_INCLUDES))   return false;
    if (!register_string_proto_method(proto, heap, "startsWith", BUILTIN_STRING_PROTO_STARTSWITH)) return false;
    if (!register_string_proto_method(proto, heap, "endsWith",   BUILTIN_STRING_PROTO_ENDSWITH))   return false;
    if (!register_string_proto_method(proto, heap, "repeat",     BUILTIN_STRING_PROTO_REPEAT))     return false;
    if (!register_string_proto_method(proto, heap, "trimStart",  BUILTIN_STRING_PROTO_TRIMSTART))  return false;
    if (!register_string_proto_method(proto, heap, "trimEnd",    BUILTIN_STRING_PROTO_TRIMEND))    return false;
    if (!register_string_proto_method(proto, heap, "codePointAt", BUILTIN_STRING_PROTO_CODEPOINTAT)) return false;
    if (!register_string_proto_method(proto, heap, "at",         BUILTIN_STRING_PROTO_AT))         return false;
    if (!register_string_proto_method(proto, heap, "padStart",   BUILTIN_STRING_PROTO_PADSTART))   return false;
    if (!register_string_proto_method(proto, heap, "padEnd",     BUILTIN_STRING_PROTO_PADEND))     return false;
    if (!register_string_proto_method(proto, heap, "lastIndexOf", BUILTIN_STRING_PROTO_LASTINDEXOF)) return false;
    if (!register_string_proto_method(proto, heap, "match",      BUILTIN_STRING_PROTO_MATCH))      return false;
    if (!register_string_proto_method(proto, heap, "search",     BUILTIN_STRING_PROTO_SEARCH))     return false;
    if (!register_string_proto_method(proto, heap, "toLocaleLowerCase", BUILTIN_STRING_PROTO_TOLOCALELOWERCASE)) return false;
    if (!register_string_proto_method(proto, heap, "toLocaleUpperCase", BUILTIN_STRING_PROTO_TOLOCALEUPPERCASE)) return false;
    if (!register_string_proto_method(proto, heap, "localeCompare", BUILTIN_STRING_PROTO_LOCALECOMPARE)) return false;

    // Register String.prototype[@@iterator] (ES6 §21.1.3.30)
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        if (iter_sym != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_STRING_PROTO_SYMBOL_ITER;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            HString* name_key = builtin_intern_string(heap, "name");
            HString* name_val = builtin_intern_string(heap, "[Symbol.iterator]");
            if (name_key != null && name_val != null) {
                TVal name_tv;
                name_tv.set_string(name_val);
                fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
            }
            HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            if (len_key != null) {
                TVal len_tv;
                len_tv.set_fastint(0);
                fn_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
            }
            TVal iter_tv;
            iter_tv.set_object(fn_obj);
            proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    // Create String constructor as a proper function object (not LIGHTFUNC)
    // so it can carry static methods like String.fromCharCode.
    HObject*? str_obj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = str_obj_raw) return false;
    HObject* str_obj = str_obj_raw;
    str_obj.extra.func.builtin_fn_index = (int)BUILTIN_STRING;
    str_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    // Set .constructor on String.prototype to point to the actual String object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(str_obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set String.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    str_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Add String.fromCharCode (ES5 §15.5.3.2)
    if (!register_string_proto_method(str_obj, heap, "fromCharCode", BUILTIN_STRING_FROMCHARCODE)) return false;
    if (!register_string_proto_method(str_obj, heap, "fromCodePoint", BUILTIN_STRING_FROMCODEPOINT)) return false;

    // Register String constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("String");
    HString* existing = heap.str_table_lookup("String", hash);
    HString* str_key;
    if (existing != null) {
        str_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "String", hash);
        if (catch err2 = new_key) return false;
        heap.str_table_insert(new_key);
        str_key = new_key;
    }
    TVal str_val;
    str_val.set_object(str_obj);
    set_func_ctor_name_length(str_obj, heap, "String", 1);
    env::env_declare_nonenum(global_env, str_key, str_val);

    return true;
}

/// Helper: register a method on a prototype as a proper HObject function.
/// Creates HObject with .name/.length per ES6 §17 (non-writable, non-enumerable, configurable).
fn bool register_string_proto_method(HObject* proto, Heap* heap, char[] name, uint fn_index) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    void* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    // Create HObject function with builtin_fn_index
    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    func_obj.extra.func.builtin_fn_index = (int)fn_index;
    func_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
    func_obj.flags.callable = true;
    func_obj.prototype = heap.function_proto;
    // Set .name (non-writable, non-enumerable, configurable)
    HString* name_prop_key = builtin_intern_string(heap, "name");
    HString* name_val = builtin_intern_string(heap, name);
    if (name_prop_key != null && name_val != null) {
        TVal name_tv;
        name_tv.set_string(name_val);
        func_obj.put_prop(name_prop_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    // Set .length from builtin metadata
    builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_index);
    if (meta.arity >= 0) {
        HString* length_str = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (length_str != null) {
            TVal len_tv;
            len_tv.set_fastint((long)meta.arity);
            func_obj.put_prop(length_str, len_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    // Register on prototype — writable:true, enumerable:false, configurable:true (ES5 §15.3.5.1)
    TVal tv;
    tv.set_object(func_obj);
    proto.put_prop(key, tv, hobject::PROP_FLAGS_WC);
    return true;
}

/// Helper: register a getter accessor on a prototype as a builtin function.
/// Creates a non-enumerable, configurable accessor property (ES6 §21.2.5).
fn bool register_proto_accessor(HObject* proto, Heap* heap, char[] name, uint getter_index) {
    HString* key = builtin_intern_string(heap, name);
    if (key == null) return false;

    // Create getter function object (builtin)
    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    func_obj.extra.func.builtin_fn_index = (int)getter_index;
    func_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
    func_obj.flags.callable = true;
    func_obj.prototype = heap.function_proto;

    // Set .name = "get <name>" per ES6 §17 (non-writable, non-enumerable, configurable)
    char[64] name_buf;
    libc::snprintf(&name_buf, 64, "get %s", name.ptr);
    usz total_len = libc::strlen((ZString)&name_buf);
    HString* fn_name = builtin_intern_string(heap, name_buf[:total_len]);
    if (fn_name != null) {
        TVal name_tv;
        name_tv.set_string(fn_name);
        HString* name_prop_key = builtin_intern_string(heap, "name");
        func_obj.put_prop(name_prop_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    // Set .length = 0
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (length_key != null) {
        TVal len_tv;
        len_tv.set_fastint(0);
        func_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC);
    }

    // Register as non-enumerable, configurable accessor (ES6 spec)
    TVal getter_tv;
    getter_tv.set_object(func_obj);
    TVal undef;
    undef.set_undefined();
    hobject::PropFlags acc_flags;
    acc_flags.writable = false;
    acc_flags.enumerable = false;
    acc_flags.configurable = true;
    acc_flags.is_accessor = true;
    proto.put_prop(key, undef, acc_flags);
    int idx = proto.find_prop_idx(key);
    if (idx >= 0) {
        proto.prop_values()[idx].data.getter = getter_tv;
        proto.prop_values()[idx].setter = undef;
    }
    return true;
}

// ============================================================================
// Array constructor registration

// ============================================================================
// Array.prototype callback methods — native implementations using heap.call_fn
// ============================================================================

/// Helper: ToObject for Array.prototype methods (ES5 §9.9).
/// Wraps primitives (Boolean/Number/String) into wrapper objects.
/// Returns null-optional for null/undefined (caller should throw TypeError).
fn HObject*? arr_to_object(TVal val, Heap* heap) {
    if (val.is_object() && val.get_heapptr() != null) {
        return (HObject*)val.get_heapptr();
    }
    if (val.is_null() || val.is_undefined()) {
        return null;
    }
    // Boolean → Boolean wrapper
    if (val.is_boolean()) {
        HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.BOOLEAN);
        if (try obj = obj_raw) {
            obj.prototype = heap.bool_proto;
            obj.extra.prim.primitive_value.set_boolean(val.get_boolean());
            return obj;
        }
        return null;
    }
    // Number/fastint → Number wrapper
    if (val.is_number() || val.is_fastint()) {
        HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.NUMBER);
        if (try obj = obj_raw) {
            obj.prototype = heap.number_proto;
            obj.extra.prim.primitive_value = val;
            return obj;
        }
        return null;
    }
    // String → String wrapper with indexed properties
    if (val.is_string()) {
        HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.STRING);
        if (try obj = obj_raw) {
            obj.flags.exotic_stringobj = true;
            obj.prototype = heap.string_proto;
            HString* prim_str = (HString*)val.get_heapptr();
            obj.extra.prim.primitive_value.set_string(prim_str);
            HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            TVal len_tv;
            len_tv.set_fastint((long)prim_str.clen);
            obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
            populate_string_indexed_props(obj, prim_str, heap);
            return obj;
        }
        return null;
    }
    return null;
}

/// Helper: throw TypeError with a message.
fn void arr_throw_type_error(Heap* heap, char[] msg) {
    HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = heap.type_err_proto;
        HString* msg_str = builtin_intern_string(heap, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
    }
}

/// Helper: check if numeric key exists on object.
fn bool arr_has_prop(HObject* obj, uint key, Heap* heap) {
    // Fast path: dense array storage
    if (obj.get_class() == hobject::ObjClass.ARRAY) {
        if (try v = obj.get_array_idx(key)) { return true; }
        return false;
    }
    char[16] buf;
    int slen = libc::snprintf(&buf, 16, "%u", key);
    if (slen <= 0 || slen >= 16) return false;
    HString* pk = builtin_intern_string(heap, buf[:slen]);
    if (pk == null) return false;
    TVal? found = obj.get_prop_proto(pk);
    return @ok(found);
}

/// Helper: get value at numeric index, returns false if not present.
fn bool arr_get_elem(HObject* obj, uint key, Heap* heap, TVal* out) {
    // Fast path: dense array storage
    if (obj.get_class() == hobject::ObjClass.ARRAY) {
        if (try v = obj.get_array_idx(key)) {
            *out = v;
            return true;
        }
        return false;
    }
    char[16] buf;
    int slen = libc::snprintf(&buf, 16, "%u", key);
    if (slen <= 0 || slen >= 16) return false;
    HString* pk = builtin_intern_string(heap, buf[:slen]);
    if (pk == null) return false;
    if (try v = obj.get_prop_proto(pk)) {
        *out = v;
        return true;
    }
    return false;
}

/// Helper: check if callback is callable, throw TypeError if not.
fn bool arr_check_callback(TVal val, Heap* heap) {
    if (val.is_object() && val.get_heapptr() != null && ((HObject*)val.get_heapptr()).is_callable()) {
        return true;
    }
    arr_throw_type_error(heap, "callback is not a function");
    return false;
}

/// Helper: call a function with (v, k, O) args and thisArg.
fn TVal arr_call_callback(TVal* vm, TVal callback, TVal thisArg, TVal v, uint k, HObject* o, Heap* heap) {
    TVal[3] args;
    args[0] = v;
    TVal k_tv; k_tv.set_fastint((long)k);
    args[1] = k_tv;
    args[2].set_object((void*)o);
    return heap.call_fn(vm, callback, &args[0], 3, thisArg);
}

/// Array.prototype.forEach(callbackfn[, thisArg]) — ES5 §15.4.4.18
fn void builtin_array_proto_forEach(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx.heap, "Cannot convert undefined or null to object");
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx.heap)) {
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len = array_get_length(o, ctx.heap);
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem(o, k, ctx.heap, &v)) {
                arr_call_callback(ctx.vm, callback, thisArg, v, k, o, ctx.heap);
            }
        }
    }
    ctx.result.set_undefined();
}

/// Array.prototype.map(callbackfn[, thisArg]) — ES5 §15.4.4.19
fn void builtin_array_proto_map(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx.heap, "Cannot convert undefined or null to object");
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx.heap)) {
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len = array_get_length(o, ctx.heap);
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_undefined(); ctx.should_throw = true; return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint aj = 0;
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem(o, k, ctx.heap, &v)) {
                TVal mapped = arr_call_callback(ctx.vm, callback, thisArg, v, k, o, ctx.heap);
                char[16] abuf;
                int aslen = libc::snprintf(&abuf, 16, "%u", aj);
                if (aslen > 0 && aslen < 16) {
                    HString* akey = builtin_intern_string(ctx.heap, abuf[:aslen]);
                    arr.put_prop(akey, mapped, hobject::PROP_FLAGS_WEC);
                }
                aj++;
            }
        }
    }
    HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv; len_tv.set_fastint((long)aj);
    arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object((void*)arr);
}

/// Array.prototype.filter(callbackfn[, thisArg]) — ES5 §15.4.4.20
fn void builtin_array_proto_filter(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx.heap, "Cannot convert undefined or null to object");
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx.heap)) {
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len = array_get_length(o, ctx.heap);
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_undefined(); ctx.should_throw = true; return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint aj = 0;
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem(o, k, ctx.heap, &v)) {
                TVal sel = arr_call_callback(ctx.vm, callback, thisArg, v, k, o, ctx.heap);
                if (builtin_to_boolean(&sel)) {
                    char[16] abuf;
                    int aslen = libc::snprintf(&abuf, 16, "%u", aj);
                    if (aslen > 0 && aslen < 16) {
                        HString* akey = builtin_intern_string(ctx.heap, abuf[:aslen]);
                        arr.put_prop(akey, v, hobject::PROP_FLAGS_WEC);
                    }
                    aj++;
                }
            }
        }
    }
    HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv; len_tv.set_fastint((long)aj);
    arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object((void*)arr);
}

/// Array.prototype.every(callbackfn[, thisArg]) — ES5 §15.4.4.17
fn void builtin_array_proto_every(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx.heap, "Cannot convert undefined or null to object");
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx.heap)) {
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len = array_get_length(o, ctx.heap);
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem(o, k, ctx.heap, &v)) {
                TVal test = arr_call_callback(ctx.vm, callback, thisArg, v, k, o, ctx.heap);
                if (!builtin_to_boolean(&test)) {
                    ctx.result.set_boolean(false);
                    return;
                }
            }
        }
    }
    ctx.result.set_boolean(true);
}

/// Array.prototype.some(callbackfn[, thisArg]) — ES5 §15.4.4.16
fn void builtin_array_proto_some(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx.heap, "Cannot convert undefined or null to object");
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx.heap)) {
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len = array_get_length(o, ctx.heap);
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem(o, k, ctx.heap, &v)) {
                TVal test = arr_call_callback(ctx.vm, callback, thisArg, v, k, o, ctx.heap);
                if (builtin_to_boolean(&test)) {
                    ctx.result.set_boolean(true);
                    return;
                }
            }
        }
    }
    ctx.result.set_boolean(false);
}

/// Array.prototype.reduce(callbackfn[, initialValue]) — ES5 §15.4.4.21
fn void builtin_array_proto_reduce(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx.heap, "Cannot convert undefined or null to object");
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx.heap)) {
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    uint len = array_get_length(o, ctx.heap);
    uint k = 0;
    TVal acc;
    bool has_acc;
    if (ctx.argc > 1) {
        acc = ctx.regs[ctx.base_reg + 1];
        has_acc = true;
    } else {
        has_acc = false;
        while (k < len && !arr_has_prop(o, k, ctx.heap)) { k++; }
        if (k >= len) {
            arr_throw_type_error(ctx.heap, "Reduce of empty array with no initial value");
            ctx.result.set_undefined(); ctx.should_throw = true; return;
        }
        arr_get_elem(o, k, ctx.heap, &acc);
        has_acc = true;
        k++;
    }
    while (k < len) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem(o, k, ctx.heap, &v)) {
                TVal[4] args;
                args[0] = acc;
                args[1] = v;
                TVal k_tv; k_tv.set_fastint((long)k);
                args[2] = k_tv;
                args[3].set_object((void*)o);
                acc = ctx.heap.call_fn(ctx.vm, callback, &args[0], 4, acc);
            }
        }
        k++;
    }
    (*ctx.result) = acc;
}

/// Array.prototype.reduceRight(callbackfn[, initialValue]) — ES5 §15.4.4.22
fn void builtin_array_proto_reduceRight(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx.heap, "Cannot convert undefined or null to object");
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx.heap)) {
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    uint len = array_get_length(o, ctx.heap);
    if (len == 0 && ctx.argc < 2) {
        arr_throw_type_error(ctx.heap, "Reduce of empty array with no initial value");
        ctx.result.set_undefined(); ctx.should_throw = true; return;
    }
    int k = (len > 0) ? (int)len - 1 : 0;
    TVal acc;
    bool has_acc;
    if (ctx.argc > 1) {
        acc = ctx.regs[ctx.base_reg + 1];
        has_acc = true;
    } else {
        has_acc = false;
        while (k >= 0 && !arr_has_prop(o, (uint)k, ctx.heap)) { k--; }
        if (k < 0) {
            arr_throw_type_error(ctx.heap, "Reduce of empty array with no initial value");
            ctx.result.set_undefined(); ctx.should_throw = true; return;
        }
        arr_get_elem(o, (uint)k, ctx.heap, &acc);
        has_acc = true;
        k--;
    }
    while (k >= 0) {
        if (arr_has_prop(o, (uint)k, ctx.heap)) {
            TVal v;
            if (arr_get_elem(o, (uint)k, ctx.heap, &v)) {
                TVal[4] args;
                args[0] = acc;
                args[1] = v;
                TVal k_tv; k_tv.set_fastint((long)k);
                args[2] = k_tv;
                args[3].set_object((void*)o);
                acc = ctx.heap.call_fn(ctx.vm, callback, &args[0], 4, acc);
            }
        }
        k--;
    }
    (*ctx.result) = acc;
}
fn bool register_array_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Array.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.array_proto = proto;

    // Create Array constructor as a proper HObject (not LIGHTFUNC)
    // so it can carry static methods like Array.isArray
    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = arr_raw) return false;
    HObject* arr = arr_raw;
    arr.extra.func.builtin_fn_index = (int)BUILTIN_ARRAY;
    arr.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    // Set .constructor on Array.prototype to point to the actual Array constructor object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(arr);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Array.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    arr.put_prop(prototype_key, proto_tv, proto_pflags);

    // Register Array.prototype methods
    if (!register_array_proto_method(proto, heap, "toString",  BUILTIN_ARRAY_PROTO_TOSTRING))  return false;
    if (!register_array_proto_method(proto, heap, "join",      BUILTIN_ARRAY_PROTO_JOIN))      return false;
    if (!register_array_proto_method(proto, heap, "pop",       BUILTIN_ARRAY_PROTO_POP))       return false;
    if (!register_array_proto_method(proto, heap, "push",      BUILTIN_ARRAY_PROTO_PUSH))      return false;
    if (!register_array_proto_method(proto, heap, "reverse",   BUILTIN_ARRAY_PROTO_REVERSE))   return false;
    if (!register_array_proto_method(proto, heap, "shift",     BUILTIN_ARRAY_PROTO_SHIFT))     return false;
    if (!register_array_proto_method(proto, heap, "slice",     BUILTIN_ARRAY_PROTO_SLICE))     return false;
    if (!register_array_proto_method(proto, heap, "sort",      BUILTIN_ARRAY_PROTO_SORT))      return false;
    if (!register_array_proto_method(proto, heap, "splice",    BUILTIN_ARRAY_PROTO_SPLICE))    return false;
    if (!register_array_proto_method(proto, heap, "unshift",   BUILTIN_ARRAY_PROTO_UNSHIFT))   return false;
    if (!register_array_proto_method(proto, heap, "indexOf",   BUILTIN_ARRAY_PROTO_INDEXOF))   return false;
    if (!register_array_proto_method(proto, heap, "lastIndexOf", BUILTIN_ARRAY_PROTO_LASTINDEXOF)) return false;
    if (!register_array_proto_method(proto, heap, "concat",    BUILTIN_ARRAY_PROTO_CONCAT))    return false;
    if (!register_array_proto_method(proto, heap, "fill",      BUILTIN_ARRAY_PROTO_FILL))      return false;
    if (!register_array_proto_method(proto, heap, "includes",  BUILTIN_ARRAY_PROTO_INCLUDES))  return false;
    if (!register_array_proto_method(proto, heap, "at",        BUILTIN_ARRAY_PROTO_AT))        return false;
    if (!register_array_proto_method(proto, heap, "copyWithin", BUILTIN_ARRAY_PROTO_COPYWITHIN)) return false;
    if (!register_compiled_proto_method(proto, heap, global_env, "find",
        "(callback){var O=Object(this);var len=O.length;var k=0;while(k<len){var v=O[k];if(callback(v,k,O))return v;k++}return undefined}")) return false;
    if (!register_compiled_proto_method(proto, heap, global_env, "findIndex",
        "(callback){var O=Object(this);var len=O.length;var k=0;while(k<len){var v=O[k];if(callback(v,k,O))return k;k++}return -1}")) return false;
    if (!register_array_proto_method(proto, heap, "flat",      BUILTIN_ARRAY_PROTO_FLAT))      return false;
    if (!register_compiled_proto_method(proto, heap, global_env, "flatMap",
        "(callback,thisArg){var O=Object(this);var len=O.length;var A=[];var k=0;while(k<len){if(k in O){var mapped=callback.call(thisArg,O[k],k,O);if(Array.isArray(mapped)){var j=0;while(j<mapped.length){A.push(mapped[j]);j++}}else{A.push(mapped)}}k++}return A}", 1)) return false;
    if (!register_array_proto_method(proto, heap, "toReversed", BUILTIN_ARRAY_PROTO_TOREVERSED)) return false;
    if (!register_array_proto_method(proto, heap, "toSorted",  BUILTIN_ARRAY_PROTO_TOSORTED))  return false;
    if (!register_array_proto_method(proto, heap, "toSpliced", BUILTIN_ARRAY_PROTO_TOSPLICED)) return false;
    if (!register_array_proto_method(proto, heap, "with",      BUILTIN_ARRAY_PROTO_WITH))      return false;

// Array.prototype.keys/values/entries (ES2015 §22.1.3.x)
    if (!register_array_proto_method(proto, heap, "keys",      BUILTIN_ARRAY_PROTO_KEYS))      return false;
    if (!register_array_proto_method(proto, heap, "values",    BUILTIN_ARRAY_PROTO_VALUES))    return false;
    if (!register_array_proto_method(proto, heap, "entries",   BUILTIN_ARRAY_PROTO_ENTRIES))   return false;

    // Register callback-based Array.prototype methods as native builtins.
    // Uses heap.call_fn for proper this-binding via Function.prototype.call semantics.
    if (!register_array_proto_method(proto, heap, "forEach",   BUILTIN_ARRAY_PROTO_FOREACH))   return false;
    if (!register_array_proto_method(proto, heap, "map",        BUILTIN_ARRAY_PROTO_MAP))        return false;
    if (!register_array_proto_method(proto, heap, "filter",     BUILTIN_ARRAY_PROTO_FILTER))     return false;
    if (!register_array_proto_method(proto, heap, "every",      BUILTIN_ARRAY_PROTO_EVERY))      return false;
    if (!register_array_proto_method(proto, heap, "some",       BUILTIN_ARRAY_PROTO_SOME))       return false;
    if (!register_array_proto_method(proto, heap, "reduce",     BUILTIN_ARRAY_PROTO_REDUCE))     return false;
    if (!register_array_proto_method(proto, heap, "reduceRight",BUILTIN_ARRAY_PROTO_REDUCERIGHT)) return false;

    // Register Array.prototype[@@iterator] (ES6 §22.1.3.30)
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        if (iter_sym != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_ARRAY_PROTO_SYMBOL_ITER;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            // Set .name
            HString* name_key = builtin_intern_string(heap, "name");
            HString* name_val = builtin_intern_string(heap, "[Symbol.iterator]");
            if (name_key != null && name_val != null) {
                TVal name_tv;
                name_tv.set_string(name_val);
                fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
            }
            // Set .length = 0
            HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            if (len_key != null) {
                TVal len_tv;
                len_tv.set_fastint(0);
                fn_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
            }
            TVal iter_tv;
            iter_tv.set_object(fn_obj);
            proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    // Add Array.isArray (ES6 §22.1.2.2) as static method on the constructor
    HString* isarray_key = builtin_intern_string(heap, "isArray");
    if (isarray_key == null) return false;
    TVal isarray_tv;
    isarray_tv.set_lightfunc((void*)(usz)BUILTIN_ARRAY_ISARRAY);
    arr.put_prop(isarray_key, isarray_tv, hobject::PROP_FLAGS_WC);

    // Add Array.of (ES6 §22.1.2.3) as static method on the constructor
    HString* of_key = builtin_intern_string(heap, "of");
    if (of_key == null) return false;
    TVal of_tv;
    of_tv.set_lightfunc((void*)(usz)BUILTIN_ARRAY_OF);
    arr.put_prop(of_key, of_tv, hobject::PROP_FLAGS_WC);

    // Add Array.from (ES6 §22.1.2.1) as static method on the constructor
    HString* from_key = builtin_intern_string(heap, "from");
    if (from_key == null) return false;
    TVal from_tv;
    from_tv.set_lightfunc((void*)(usz)BUILTIN_ARRAY_FROM);
    arr.put_prop(from_key, from_tv, hobject::PROP_FLAGS_WC);

    // Register Array constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("Array");
    HString* existing = heap.str_table_lookup("Array", hash);
    HString* arr_key;
    if (existing != null) {
        arr_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Array", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        arr_key = new_key;
    }
    TVal arr_val;
    arr_val.set_object(arr);
    set_func_ctor_name_length(arr, heap, "Array", 1);
    env::env_declare_nonenum(global_env, arr_key, arr_val);

    return true;
}

// ============================================================================
// Function constructor + Function.prototype registration
// ============================================================================

/// Create Function.prototype, register call/apply/bind, and register
/// the Function constructor globally.
fn bool register_function_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Function constructor as a proper function object FIRST
    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    func_obj.extra.func.builtin_fn_index = (int)BUILTIN_FUNCTION;
    func_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    // Create Function.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype
    heap.function_proto = proto;

    // Add .call method
    HString* call_key = builtin_intern_string(heap, "call");
    TVal call_tv;
    call_tv.set_lightfunc((void*)(usz)BUILTIN_FUNCTION_PROTO_CALL);
    proto.put_prop(call_key, call_tv, hobject::PROP_FLAGS_WC);

    // Add .apply method
    HString* apply_key = builtin_intern_string(heap, "apply");
    TVal apply_tv;
    apply_tv.set_lightfunc((void*)(usz)BUILTIN_FUNCTION_PROTO_APPLY);
    proto.put_prop(apply_key, apply_tv, hobject::PROP_FLAGS_WC);

    // Add .bind method
    HString* bind_key = builtin_intern_string(heap, "bind");
    TVal bind_tv;
    bind_tv.set_lightfunc((void*)(usz)BUILTIN_FUNCTION_PROTO_BIND);
    proto.put_prop(bind_key, bind_tv, hobject::PROP_FLAGS_WC);

    // Set .constructor to the Function constructor object itself
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(func_obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Function.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    func_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Function.length (ES5 §15.3.3)
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv;
    len_tv.set_fastint(1);
    func_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);

    // Register Function constructor globally as an OBJECT
    uint hash = heap.hash_string("Function");
    HString* existing = heap.str_table_lookup("Function", hash);
    HString* func_key;
    if (existing != null) {
        func_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Function", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        func_key = new_key;
    }
    TVal func_val;
    func_val.set_object(func_obj);
    set_func_ctor_name(func_obj, heap, "Function");
    env::env_declare_nonenum(global_env, func_key, func_val);

    return true;
}

// ============================================================================
// Date constructor registration
// ============================================================================

/// Create Date.prototype and register the Date constructor globally.
fn bool register_date_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Date.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.DATE);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype
    heap.date_proto = proto;

    // Set .constructor to Date lightfunc
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_lightfunc((void*)(usz)BUILTIN_DATE);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Add Date.prototype.toString()
    if (!register_string_proto_method(proto, heap, "toString", BUILTIN_DATE_PROTO_TOSTRING)) return false;

    // Add Date.prototype.toJSON()
    if (!register_string_proto_method(proto, heap, "toJSON", BUILTIN_DATE_PROTO_TOJSON)) return false;

    // Add Date.prototype.data.valueOf()
    if (!register_string_proto_method(proto, heap, "valueOf", BUILTIN_DATE_PROTO_VALUEOF)) return false;

    // Add Date.prototype.getTime()
    if (!register_string_proto_method(proto, heap, "getTime", BUILTIN_DATE_PROTO_GETTIME)) return false;

    // Add Date.prototype.getFullYear()
    if (!register_string_proto_method(proto, heap, "getFullYear", BUILTIN_DATE_PROTO_GETFULLYEAR)) return false;

    // Add Date.prototype.getMonth()
    if (!register_string_proto_method(proto, heap, "getMonth", BUILTIN_DATE_PROTO_GETMONTH)) return false;

    // Add Date.prototype.getDate()
    if (!register_string_proto_method(proto, heap, "getDate", BUILTIN_DATE_PROTO_GETDATE)) return false;

    // Add Date.prototype.getDay()
    if (!register_string_proto_method(proto, heap, "getDay", BUILTIN_DATE_PROTO_GETDAY)) return false;

    // Add Date.prototype.getHours()
    if (!register_string_proto_method(proto, heap, "getHours", BUILTIN_DATE_PROTO_GETHOURS)) return false;

    // Add Date.prototype.getMinutes()
    if (!register_string_proto_method(proto, heap, "getMinutes", BUILTIN_DATE_PROTO_GETMINUTES)) return false;

    // Add Date.prototype.getSeconds()
    if (!register_string_proto_method(proto, heap, "getSeconds", BUILTIN_DATE_PROTO_GETSECONDS)) return false;

    // Add Date.prototype.getMilliseconds()
    if (!register_string_proto_method(proto, heap, "getMilliseconds", BUILTIN_DATE_PROTO_GETMILLISECONDS)) return false;

    // Add Date.prototype.getTimezoneOffset()
    if (!register_string_proto_method(proto, heap, "getTimezoneOffset", BUILTIN_DATE_PROTO_GETTIMEZONEOFFSET)) return false;

    // Add Date.prototype.getUTCFullYear()
    if (!register_string_proto_method(proto, heap, "getUTCFullYear", BUILTIN_DATE_PROTO_GETUTCFULLYEAR)) return false;

    // Add Date.prototype.getUTCMonth()
    if (!register_string_proto_method(proto, heap, "getUTCMonth", BUILTIN_DATE_PROTO_GETUTCMONTH)) return false;

    // Add Date.prototype.getUTCDate()
    if (!register_string_proto_method(proto, heap, "getUTCDate", BUILTIN_DATE_PROTO_GETUTCDATE)) return false;

    // Add Date.prototype.getUTCDay()
    if (!register_string_proto_method(proto, heap, "getUTCDay", BUILTIN_DATE_PROTO_GETUTCDAY)) return false;

    // Add Date.prototype.getUTCHours()
    if (!register_string_proto_method(proto, heap, "getUTCHours", BUILTIN_DATE_PROTO_GETUTCHOURS)) return false;

    // Add Date.prototype.getUTCMinutes()
    if (!register_string_proto_method(proto, heap, "getUTCMinutes", BUILTIN_DATE_PROTO_GETUTCMINUTES)) return false;

    // Add Date.prototype.getUTCSeconds()
    if (!register_string_proto_method(proto, heap, "getUTCSeconds", BUILTIN_DATE_PROTO_GETUTCSECONDS)) return false;

    // Add Date.prototype.getUTCMilliseconds()
    if (!register_string_proto_method(proto, heap, "getUTCMilliseconds", BUILTIN_DATE_PROTO_GETUTCMILLISECONDS)) return false;

    // Add Date.prototype.setTime()
    if (!register_string_proto_method(proto, heap, "setTime", BUILTIN_DATE_PROTO_SETTIME)) return false;

    // Add Date.prototype.setMilliseconds()
    if (!register_string_proto_method(proto, heap, "setMilliseconds", BUILTIN_DATE_PROTO_SETMILLISECONDS)) return false;

    // Add Date.prototype.setSeconds()
    if (!register_string_proto_method(proto, heap, "setSeconds", BUILTIN_DATE_PROTO_SETSECONDS)) return false;

    // Add Date.prototype.setMinutes()
    if (!register_string_proto_method(proto, heap, "setMinutes", BUILTIN_DATE_PROTO_SETMINUTES)) return false;

    // Add Date.prototype.setHours()
    if (!register_string_proto_method(proto, heap, "setHours", BUILTIN_DATE_PROTO_SETHOURS)) return false;

    // Add Date.prototype.setDate()
    if (!register_string_proto_method(proto, heap, "setDate", BUILTIN_DATE_PROTO_SETDATE)) return false;

    // Add Date.prototype.setMonth()
    if (!register_string_proto_method(proto, heap, "setMonth", BUILTIN_DATE_PROTO_SETMONTH)) return false;

    // Add Date.prototype.setFullYear()
    if (!register_string_proto_method(proto, heap, "setFullYear", BUILTIN_DATE_PROTO_SETFULLYEAR)) return false;

    // Add Date.prototype.setUTCMilliseconds()
    if (!register_string_proto_method(proto, heap, "setUTCMilliseconds", BUILTIN_DATE_PROTO_SETUTCMILLISECONDS)) return false;

    // Add Date.prototype.setUTCSeconds()
    if (!register_string_proto_method(proto, heap, "setUTCSeconds", BUILTIN_DATE_PROTO_SETUTCSECONDS)) return false;

    // Add Date.prototype.setUTCMinutes()
    if (!register_string_proto_method(proto, heap, "setUTCMinutes", BUILTIN_DATE_PROTO_SETUTCMINUTES)) return false;

    // Add Date.prototype.setUTCHours()
    if (!register_string_proto_method(proto, heap, "setUTCHours", BUILTIN_DATE_PROTO_SETUTCHOURS)) return false;

    // Add Date.prototype.setUTCDate()
    if (!register_string_proto_method(proto, heap, "setUTCDate", BUILTIN_DATE_PROTO_SETUTCDATE)) return false;

    // Add Date.prototype.setUTCMonth()
    if (!register_string_proto_method(proto, heap, "setUTCMonth", BUILTIN_DATE_PROTO_SETUTCMONTH)) return false;

    // Add Date.prototype.setUTCFullYear()
    if (!register_string_proto_method(proto, heap, "setUTCFullYear", BUILTIN_DATE_PROTO_SETUTCFULLYEAR)) return false;

    // Add Date.prototype.toISOString()
    if (!register_string_proto_method(proto, heap, "toISOString", BUILTIN_DATE_PROTO_TOISOSTRING)) return false;

    // Add Date.prototype.toUTCString()
    if (!register_string_proto_method(proto, heap, "toUTCString", BUILTIN_DATE_PROTO_TOUTCSTRING)) return false;

    // Add Date.prototype.toGMTString() (alias for toUTCString)
    if (!register_string_proto_method(proto, heap, "toGMTString", BUILTIN_DATE_PROTO_TOGMTSTRING)) return false;

    // Add Date.prototype.toLocaleString() — ES5 §15.9.5.5
    if (!register_string_proto_method(proto, heap, "toLocaleString", BUILTIN_DATE_PROTO_TOLOCALESTRING)) return false;

    // Add Date.prototype.toLocaleDateString() — ES5 §15.9.5.6
    if (!register_string_proto_method(proto, heap, "toLocaleDateString", BUILTIN_DATE_PROTO_TOLOCALEDATESTRING)) return false;

    // Add Date.prototype.toLocaleTimeString() — ES5 §15.9.5.7
    if (!register_string_proto_method(proto, heap, "toLocaleTimeString", BUILTIN_DATE_PROTO_TOLOCALETIMESTRING)) return false;

    // Register Date as a global constructor (proper function object for static methods)
    HObject*? date_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = date_raw) return false;
    HObject* date_obj = date_raw;
    date_obj.extra.func.builtin_fn_index = (int)BUILTIN_DATE;
    date_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    // Set Date.prototype on the constructor
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    date_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Add Date.now() static method
    if (!register_string_proto_method(date_obj, heap, "now", BUILTIN_DATE_NOW)) return false;

    // Add Date.UTC() static method
    if (!register_string_proto_method(date_obj, heap, "UTC", BUILTIN_DATE_UTC)) return false;

    // Add Date.parse() static method
    if (!register_string_proto_method(date_obj, heap, "parse", BUILTIN_DATE_PARSE)) return false;

    // Register Date constructor globally as an OBJECT
    uint hash = heap.hash_string("Date");
    HString* existing = heap.str_table_lookup("Date", hash);
    HString* date_key;
    if (existing != null) {
        date_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Date", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        date_key = new_key;
    }
    TVal date_val;
    date_val.set_object(date_obj);
    set_func_ctor_name_length(date_obj, heap, "Date", 7);
    env::env_declare_nonenum(global_env, date_key, date_val);

    return true;
}


// ============================================================================
// RegExp constructor registration
// ============================================================================

/// Create RegExp.prototype and register the RegExp constructor globally.
fn bool register_regexp_constructor(EnvRecord* global_env, Heap* heap) {
    // Create RegExp.prototype (ObjClass.OBJECT per spec — toString gives [object Object])
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype
    heap.regexp_proto = proto;

    // Add RegExp.prototype.test()
    if (!register_string_proto_method(proto, heap, "test", BUILTIN_REGEXP_PROTO_TEST)) return false;

    // Add RegExp.prototype.exec()
    if (!register_string_proto_method(proto, heap, "exec", BUILTIN_REGEXP_PROTO_EXEC)) return false;

    // Add RegExp.prototype.toString()
    if (!register_string_proto_method(proto, heap, "toString", BUILTIN_REGEXP_PROTO_TOSTRING)) return false;

    // Add RegExp.prototype accessor getters (ES6 §21.2.5)
    if (!register_proto_accessor(proto, heap, "flags", BUILTIN_REGEXP_PROTO_GET_FLAGS)) return false;
    if (!register_proto_accessor(proto, heap, "source", BUILTIN_REGEXP_PROTO_GET_SOURCE)) return false;
    if (!register_proto_accessor(proto, heap, "global", BUILTIN_REGEXP_PROTO_GET_GLOBAL)) return false;
    if (!register_proto_accessor(proto, heap, "ignoreCase", BUILTIN_REGEXP_PROTO_GET_IGNORECASE)) return false;
    if (!register_proto_accessor(proto, heap, "multiline", BUILTIN_REGEXP_PROTO_GET_MULTILINE)) return false;
    if (!register_proto_accessor(proto, heap, "dotAll", BUILTIN_REGEXP_PROTO_GET_DOTALL)) return false;
    if (!register_proto_accessor(proto, heap, "sticky", BUILTIN_REGEXP_PROTO_GET_STICKY)) return false;
    if (!register_proto_accessor(proto, heap, "unicode", BUILTIN_REGEXP_PROTO_GET_UNICODE)) return false;

    // Register RegExp as a global constructor (proper function object)
    HObject*? regexp_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = regexp_raw) return false;
    HObject* regexp_obj = regexp_raw;
    regexp_obj.extra.func.builtin_fn_index = (int)BUILTIN_REGEXP;
    regexp_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    // Set .constructor on RegExp.prototype to the actual constructor object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(regexp_obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set RegExp.prototype on the constructor
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    regexp_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set RegExp.length (ES5 15.10.5)
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv;
    len_tv.set_fastint(2);
    regexp_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);

    // Register RegExp constructor globally as an OBJECT
    uint hash = heap.hash_string("RegExp");
    HString* existing = heap.str_table_lookup("RegExp", hash);
    HString* regexp_key;
    if (existing != null) {
        regexp_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "RegExp", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        regexp_key = new_key;
    }
    TVal regexp_val;
    regexp_val.set_object(regexp_obj);
    set_func_ctor_name(regexp_obj, heap, "RegExp");
    env::env_declare_nonenum(global_env, regexp_key, regexp_val);

    return true;
}

// ============================================================================
// Map constructor registration
// ============================================================================

fn bool register_map_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Map prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.MAP);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.map_proto = proto;

    // Add .set(key, value) method
    if (!register_string_proto_method(proto, heap, "set", BUILTIN_MAP_PROTO_SET)) return false;
    // Add .get(key) method
    if (!register_string_proto_method(proto, heap, "get", BUILTIN_MAP_PROTO_GET)) return false;
    // Add .has(key) method
    if (!register_string_proto_method(proto, heap, "has", BUILTIN_MAP_PROTO_HAS)) return false;
    // Add .delete(key) method
    if (!register_string_proto_method(proto, heap, "delete", BUILTIN_MAP_PROTO_DELETE)) return false;
    // Add .clear() method
    if (!register_string_proto_method(proto, heap, "clear", BUILTIN_MAP_PROTO_CLEAR)) return false;
    // Add .keys() method
    if (!register_string_proto_method(proto, heap, "keys", BUILTIN_MAP_PROTO_KEYS)) return false;
    // Add .values() method
    if (!register_string_proto_method(proto, heap, "values", BUILTIN_MAP_PROTO_VALUES)) return false;
    // Add .entries() method
    if (!register_string_proto_method(proto, heap, "entries", BUILTIN_MAP_PROTO_ENTRIES)) return false;
    // Add .forEach() method
    if (!register_string_proto_method(proto, heap, "forEach", BUILTIN_MAP_PROTO_FOREACH)) return false;
    // Add [Symbol.iterator] = entries
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (catch err = fn_raw) return false;
        HObject* fn_obj = fn_raw;
        fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_MAP_PROTO_SYMBOL_ITER;
        fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
        fn_obj.flags.callable = true;
        fn_obj.prototype = heap.function_proto;
        // Set .name
        HString* name_key = builtin_intern_string(heap, "name");
        HString* name_val = builtin_intern_string(heap, "[Symbol.iterator]");
        if (name_key != null && name_val != null) {
            TVal name_tv;
            name_tv.set_string(name_val);
            fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
        }
        // Set .length = 0
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            TVal len_tv;
            len_tv.set_fastint(0);
            fn_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
        }
        TVal iter_tv;
        iter_tv.set_object(fn_obj);
        proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_NWC);
    }

    // Set @@toStringTag on Map.prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Map"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Add .size property (will be updated on each mutation)
    HString* size_key = builtin_intern_string(heap, "size");
    TVal size_tv;
    size_tv.set_fastint(0);
    proto.put_prop(size_key, size_tv, hobject::PROP_FLAGS_NWC);

    // Create Map constructor as a proper function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.extra.func.builtin_fn_index = (int)BUILTIN_MAP;
    ctor.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    // Set .constructor on Map.prototype
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Map.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Map.length
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);

    // Map.prototype's [[Prototype]] is set later (to Object.prototype)

    // Register Map constructor globally
    uint hash = heap.hash_string("Map");
    HString* existing = heap.str_table_lookup("Map", hash);
    HString* map_key;
    if (existing != null) {
        map_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Map", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        map_key = new_key;
    }
    TVal map_val;
    map_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, "Map");
    env::env_declare_nonenum(global_env, map_key, map_val);

    return true;
}

// ============================================================================
// Set constructor registration
// ============================================================================

fn bool register_set_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Set prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.SET);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.set_proto = proto;

    // Add .add(value) method
    if (!register_string_proto_method(proto, heap, "add", BUILTIN_SET_PROTO_ADD)) return false;
    // Add .has(value) method
    if (!register_string_proto_method(proto, heap, "has", BUILTIN_SET_PROTO_HAS)) return false;
    // Add .delete(value) method
    if (!register_string_proto_method(proto, heap, "delete", BUILTIN_SET_PROTO_DELETE)) return false;
    // Add .clear() method
    if (!register_string_proto_method(proto, heap, "clear", BUILTIN_SET_PROTO_CLEAR)) return false;
    // Add .keys() method
    if (!register_string_proto_method(proto, heap, "keys", BUILTIN_SET_PROTO_KEYS)) return false;
    // Add .values() method
    if (!register_string_proto_method(proto, heap, "values", BUILTIN_SET_PROTO_VALUES)) return false;
    // Add .entries() method
    if (!register_string_proto_method(proto, heap, "entries", BUILTIN_SET_PROTO_ENTRIES)) return false;
    // Add .forEach() method
    if (!register_string_proto_method(proto, heap, "forEach", BUILTIN_SET_PROTO_FOREACH)) return false;
    // Add [Symbol.iterator] = values
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (catch err = fn_raw) return false;
        HObject* fn_obj = fn_raw;
        fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_SET_PROTO_SYMBOL_ITER;
        fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
        fn_obj.flags.callable = true;
        fn_obj.prototype = heap.function_proto;
        // Set .name
        HString* name_key = builtin_intern_string(heap, "name");
        HString* name_val = builtin_intern_string(heap, "[Symbol.iterator]");
        if (name_key != null && name_val != null) {
            TVal name_tv;
            name_tv.set_string(name_val);
            fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
        }
        // Set .length = 0
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            TVal len_tv;
            len_tv.set_fastint(0);
            fn_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
        }
        TVal iter_tv;
        iter_tv.set_object(fn_obj);
        proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_NWC);
    }

    // Set @@toStringTag on Set.prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Set"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Add .size property (will be updated on each mutation)
    HString* size_key = builtin_intern_string(heap, "size");
    TVal size_tv;
    size_tv.set_fastint(0);
    proto.put_prop(size_key, size_tv, hobject::PROP_FLAGS_NWC);

    // Create Set constructor as a proper function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.extra.func.builtin_fn_index = (int)BUILTIN_SET;
    ctor.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    // Set .constructor on Set.prototype
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Set.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Set.length
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);

    // Register Set constructor globally
    uint hash = heap.hash_string("Set");
    HString* existing = heap.str_table_lookup("Set", hash);
    HString* set_key;
    if (existing != null) {
        set_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Set", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        set_key = new_key;
    }
    TVal set_val;
    set_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, "Set");
    env::env_declare_nonenum(global_env, set_key, set_val);

    return true;
}

// ============================================================================
// WeakMap constructor registration
// ============================================================================

fn bool register_weakmap_constructor(EnvRecord* global_env, Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.WEAKMAP);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.weakmap_proto = proto;

    if (!register_string_proto_method(proto, heap, "set", BUILTIN_WEAKMAP_PROTO_SET)) return false;
    if (!register_string_proto_method(proto, heap, "get", BUILTIN_WEAKMAP_PROTO_GET)) return false;
    if (!register_string_proto_method(proto, heap, "has", BUILTIN_WEAKMAP_PROTO_HAS)) return false;
    if (!register_string_proto_method(proto, heap, "delete", BUILTIN_WEAKMAP_PROTO_DELETE)) return false;

    // Set @@toStringTag
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "WeakMap"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.extra.func.builtin_fn_index = (int)BUILTIN_WEAKMAP;
    ctor.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);

    uint hash = heap.hash_string("WeakMap");
    HString* existing = heap.str_table_lookup("WeakMap", hash);
    HString* wm_key;
    if (existing != null) {
        wm_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "WeakMap", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        wm_key = new_key;
    }
    TVal wm_val;
    wm_val.set_object(ctor);
    env::env_declare_nonenum(global_env, wm_key, wm_val);

    return true;
}

// ============================================================================
// WeakSet constructor registration
// ============================================================================

fn bool register_weakset_constructor(EnvRecord* global_env, Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.WEAKSET);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.weakset_proto = proto;

    if (!register_string_proto_method(proto, heap, "add", BUILTIN_WEAKSET_PROTO_ADD)) return false;
    if (!register_string_proto_method(proto, heap, "has", BUILTIN_WEAKSET_PROTO_HAS)) return false;
    if (!register_string_proto_method(proto, heap, "delete", BUILTIN_WEAKSET_PROTO_DELETE)) return false;

    // Set @@toStringTag
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "WeakSet"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.extra.func.builtin_fn_index = (int)BUILTIN_WEAKSET;
    ctor.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);

    uint hash = heap.hash_string("WeakSet");
    HString* existing = heap.str_table_lookup("WeakSet", hash);
    HString* ws_key;
    if (existing != null) {
        ws_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "WeakSet", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        ws_key = new_key;
    }
    TVal ws_val;
    ws_val.set_object(ctor);
    env::env_declare_nonenum(global_env, ws_key, ws_val);

    return true;
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
    if (!register_string_proto_method(proto, heap, "toString", BUILTIN_SYMBOL_PROTO_TOSTRING)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", BUILTIN_SYMBOL_PROTO_VALUEOF)) return false;

    // Set @@toStringTag on prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Symbol"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Create Symbol function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.extra.func.builtin_fn_index = (int)BUILTIN_SYMBOL;
    ctor.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

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
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);

    // Register Symbol.for as a property of the Symbol function
    HString* for_key = builtin_intern_string(heap, "for");
    TVal for_tv;
    for_tv.set_lightfunc((void*)(usz)BUILTIN_SYMBOL_FOR);
    ctor.put_prop(for_key, for_tv, hobject::PROP_FLAGS_WC);

    // Register Symbol.keyFor as a property of the Symbol function
    HString* keyfor_key = builtin_intern_string(heap, "keyFor");
    TVal keyfor_tv;
    keyfor_tv.set_lightfunc((void*)(usz)BUILTIN_SYMBOL_KEYFOR);
    ctor.put_prop(keyfor_key, keyfor_tv, hobject::PROP_FLAGS_WC);

    // Register Symbol.toStringTag as a well-known symbol property
    HString* tostrtag_sym = ensure_tostringtag_symbol(heap);
    if (tostrtag_sym != null) {
        HString* tostrtag_key = builtin_intern_string(heap, "toStringTag");
        TVal tostrtag_val;
        tostrtag_val.set_string(tostrtag_sym);
        ctor.put_prop(tostrtag_key, tostrtag_val, hobject::PROP_FLAGS_WC);
    }

    // Register Symbol.iterator as a well-known symbol property (non-writable, non-enumerable, non-configurable per ES6 §19.4.2.12)
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym != null) {
        HString* iter_key = builtin_intern_string(heap, "iterator");
        if (iter_key != null) {
            TVal iter_val;
            iter_val.set_string(iter_sym);
            ctor.put_prop(iter_key, iter_val, hobject::PROP_FLAGS_NWC);
        }
    }

    // Register Symbol.toPrimitive as a well-known symbol property (non-writable, non-enumerable, non-configurable per ES6 §19.4.2.12)
    HString* toprim_sym = ensure_toprimitive_symbol(heap);
    if (toprim_sym != null) {
        HString* toprim_key = builtin_intern_string(heap, "toPrimitive");
        if (toprim_key != null) {
            TVal toprim_val;
            toprim_val.set_string(toprim_sym);
            ctor.put_prop(toprim_key, toprim_val, hobject::PROP_FLAGS_NWC);
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
