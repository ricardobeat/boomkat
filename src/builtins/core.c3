/// Built-in function registry for the Duktape C3 port.
/// Core: shared types, constants, helpers, dispatch table, and registration.
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
import duktape::vm;
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
const uint BUILTIN_PROMISE_ALL_RESOLVE_ELEMENT  = 336;
const uint BUILTIN_PROMISE_ALL_REJECT_ELEMENT   = 337;
const uint BUILTIN_PROMISE_RACE_RESOLVE_ELEMENT = 338;
const uint BUILTIN_PROMISE_RACE_REJECT_ELEMENT  = 339;
const uint BUILTIN_PROMISE_ALLSETTLED_RESOLVE_ELEMENT = 340;
const uint BUILTIN_PROMISE_ALLSETTLED_REJECT_ELEMENT  = 341;
const uint BUILTIN_PROMISE_ANY_RESOLVE_ELEMENT        = 342;
const uint BUILTIN_PROMISE_ANY_REJECT_ELEMENT         = 343;

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
const uint BUILTIN_ARRAY_PROTO_FINDLAST           = 307;
const uint BUILTIN_ARRAY_PROTO_FINDLASTINDEX      = 308;
const uint BUILTIN_FUNCTION_PROTO_TOSTRING       = 312;

// TypedArray constructors (9 types)
const uint BUILTIN_INT8ARRAY                 = 316;
const uint BUILTIN_UINT8ARRAY                = 317;
const uint BUILTIN_UINT8CLAMPEDARRAY         = 318;
const uint BUILTIN_INT16ARRAY                = 319;
const uint BUILTIN_UINT16ARRAY               = 320;
const uint BUILTIN_INT32ARRAY                = 321;
const uint BUILTIN_UINT32ARRAY               = 322;
const uint BUILTIN_FLOAT32ARRAY              = 323;
const uint BUILTIN_FLOAT64ARRAY              = 324;

const uint BUILTIN_REGEXP_PROTO_SYMBOL_MATCH   = 325;
const uint BUILTIN_REGEXP_PROTO_SYMBOL_SEARCH  = 326;
const uint BUILTIN_REGEXP_PROTO_SYMBOL_REPLACE = 327;
const uint BUILTIN_REGEXP_PROTO_SYMBOL_SPLIT   = 328;

const uint BUILTIN_REGEXP_STRING_ITERATOR_NEXT = 329;
const uint BUILTIN_ASYNC_RESUME               = 330;
const uint BUILTIN_ASYNC_REJECT               = 331;

const uint BUILTIN_PROMISE_SYNTHETIC_EXECUTOR  = 344;
const uint BUILTIN_FUNCTION_PROTO_SPECIES_GETTER = 345;

const uint BUILTIN_COUNT                       = 346;

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
const uint BUILTIN_SYMBOL_PROTO_TOPRIMITIVE  = 314;
const uint BUILTIN_SYMBOL_PROTO_DESCRIPTION_GET = 333;
const uint BUILTIN_MAP_PROTO_SIZE_GET          = 334;
const uint BUILTIN_SET_PROTO_SIZE_GET          = 335;

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
const uint BUILTIN_OBJECT_GETOWNPROPERTYSYMBOLS    = 306;
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
const uint BUILTIN_DATE_PROTO_TODATESTRING   = 301;
const uint BUILTIN_DATE_PROTO_TOTIMESTRING   = 302;
const uint BUILTIN_STRING_PROTO_REPLACEALL    = 303;
const uint BUILTIN_STRING_PROTO_MATCHALL      = 304;
const uint BUILTIN_STRING_PROTO_NORMALIZE     = 305;
const uint BUILTIN_REFLECT_OWNKEYS            = 310;
const uint BUILTIN_ERROR_CAPTURE_STACK_TRACE    = 311;

// ============================================================================
// BuiltinContext — passed to every builtin handler
// ============================================================================

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

/// ES5 §8.12.3 [[Get]] / ES2020 §10.1.8.1 OrdinaryGet — for builtins that
/// need full Get semantics on a property (walks prototype chain, invokes
/// accessor getters). Returns the resolved TVal, or faults on throw (per
/// ES2017 §25.4.1.5 step 7 `ReturnIfAbrupt`). A `null`/missing key
/// returns `undefined` (no fault). Used by Map/Set/WeakMap/WeakSet
/// constructors per ES6 §23.1.1 / §23.2.1 / §23.3.1 / §23.4.1.
fn TVal? builtins_generic_get(HObject* obj, HString* key, BuiltinContext* ctx) {
    if (obj == null || key == null) {
        TVal undef; undef.set_undefined();
        return undef;
    }
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto((void*)key, true);
    switch (res.kind) {
        case hobject::PropLookupKind.PROP_DATA:
            return res.data_val;
        case hobject::PropLookupKind.PROP_ACCESSOR: {
            // ES5 §8.12.3 / ES2020 §10.1.8.1 step 6: invoke the accessor's
            // getter with `this` set to the object where the accessor was
            // found (not the receiver). For prototype accessors this is
            // critical — calling the getter with the derived instance as
            // `this` would trip the common pattern of "if (this is not
            // <Class>) throw".
            TVal getter_this;
            getter_this.set_object(res.acc.this_obj);
            if (ctx.vm == null) {
                TVal undef; undef.set_undefined();
                return undef;
            }
            TVal result = ctx.heap.call_fn(ctx.vm, res.acc.accessor_fn, null, 0, getter_this);
            if (ctx.heap.has_error) {
                // Propagate the throw into ctx; return fault so callers
                // using `try`/`catch` can detect.
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return hobject::PROP_NOT_FOUND~;
            }
            return result;
        }
        default:
            TVal undef; undef.set_undefined();
            return undef;
    }
}

// ============================================================================
// Shared helpers
// ============================================================================

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
                if ((double)iv == v && iv >= types::DUK_MIN_SAFE_INT && iv <= types::DUK_MAX_SAFE_INT) {
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
// ECMAScript whitespace check
// ============================================================================

/// ECMAScript whitespace (ASCII subset: Tab, VT, FF, Space, NBSP, LF, CR).
/// Used by ToNumber which only needs ASCII whitespace.
fn bool is_ecma_whitespace(char c) @inline {
    return c == 0x09 || c == 0x0B || c == 0x0C
        || c == 0x20 || c == 0xA0
        || c == 0x0A || c == 0x0D;
}

/// ECMAScript whitespace check at the Unicode codepoint level (ES5 §7.2 + §7.3).
/// Handles the full Unicode range including Zs (Space_Separator) characters.
/// Used by String.prototype.trim which must strip all Unicode whitespace.
fn bool is_ecma_ws_codepoint(uint cp) @inline {
    // Line terminators (§7.3)
    if (cp == 0x000A) return true;  // LF
    if (cp == 0x000D) return true;  // CR
    if (cp == 0x2028) return true;  // Line Separator
    if (cp == 0x2029) return true;  // Paragraph Separator
    // Explicit whitespace (§7.2)
    if (cp == 0x0009) return true;  // Tab
    if (cp == 0x000B) return true;  // Vertical Tab
    if (cp == 0x000C) return true;  // Form Feed
    if (cp == 0x0020) return true;  // Space
    if (cp == 0x00A0) return true;  // No-Break Space
    if (cp == 0xFEFF) return true;  // BOM / ZWNBSP
    // Unicode Zs (Space_Separator) category
    if (cp == 0x1680) return true;  // OGHAM SPACE MARK
    if (cp >= 0x2000 && cp <= 0x200A) return true;  // EN QUAD .. HAIR SPACE
    if (cp == 0x202F) return true;  // NARROW NO-BREAK SPACE
    if (cp == 0x205F) return true;  // MATHEMATICAL SPACE
    if (cp == 0x3000) return true;  // IDEOGRAPHIC SPACE
    return false;
}

/// Decode a UTF-8 codepoint starting at `data[off]`. Returns the codepoint
/// and sets `*seq_len` to the number of bytes consumed (1-4). Returns 0 on
/// invalid/truncated input.
fn uint decode_codepoint_at(char* data, uint off, uint total_len, uint* seq_len) {
    if (off >= total_len) { *seq_len = 0; return 0; }
    uint b0 = (uint)data[off];
    // 1-byte (ASCII)
    if (b0 < 0x80) { *seq_len = 1; return b0; }
    // 2-byte: 110xxxxx 10xxxxxx
    if ((b0 & 0xE0) == 0xC0) {
        if (off + 1 >= total_len) { *seq_len = 1; return 0; }
        uint b1 = (uint)data[off + 1];
        *seq_len = 2;
        return ((b0 & 0x1F) << 6) | (b1 & 0x3F);
    }
    // 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
    if ((b0 & 0xF0) == 0xE0) {
        if (off + 2 >= total_len) { *seq_len = 1; return 0; }
        uint b1 = (uint)data[off + 1];
        uint b2 = (uint)data[off + 2];
        *seq_len = 3;
        return ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
    }
    // 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    if ((b0 & 0xF8) == 0xF0) {
        if (off + 3 >= total_len) { *seq_len = 1; return 0; }
        uint b1 = (uint)data[off + 1];
        uint b2 = (uint)data[off + 2];
        uint b3 = (uint)data[off + 3];
        *seq_len = 4;
        return ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
    }
    // Invalid lead byte — skip one byte
    *seq_len = 1;
    return 0;
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
            if ((double)fi == d && fi >= types::DUK_MIN_SAFE_INT && fi <= types::DUK_MAX_SAFE_INT) {
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
            (*obj.extra_ptr()).prim.primitive_value.is_boolean()) {
            TVal result;
            result.set_boolean((*obj.extra_ptr()).prim.primitive_value.get_boolean());
            return result;
        }
        if (cls == hobject::ObjClass.NUMBER &&
            ((*obj.extra_ptr()).prim.primitive_value.is_number() || (*obj.extra_ptr()).prim.primitive_value.is_fastint())) {
            TVal result;
            result.set_number((*obj.extra_ptr()).prim.primitive_value.get_number_or_fastint());
            return result;
        }
        if (cls == hobject::ObjClass.STRING &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()) {
            TVal result;
            result.set_string((*obj.extra_ptr()).prim.primitive_value.get_heapptr());
            return result;
        }
        // Symbol wrapper → unwrap directly
        if (cls == hobject::ObjClass.SYMBOL &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()) {
            HString* s = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
            if (s != null && s.is_symbol()) {
                TVal result;
                result.set_string(s);
                return result;
            }
        }
    }
    return *val;
}

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
        ((types::HeapHeader*)s).incref();
        s.flags.is_interned = true;
        return s;
    }
    return null;
}

// ============================================================================
// Collection class check helper (shared by Map, Set, WeakMap, WeakSet)
// ============================================================================

fn HObject* check_collection_class(BuiltinContext* ctx, hobject::ObjClass want, char[] type_name) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == want) return obj;
    }
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, type_name);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        TVal err_val;
        err_val.set_object(err);
        ctx.should_throw = true;
        ctx.throw_value = err_val;
    }
    return null;
}

// ============================================================================
// Array part search helper (shared by Map, Set, WeakMap, WeakSet)
// ============================================================================

/// Find the index in array_part where a value matches using SameValueZero.
/// stride=2 for Map/WeakMap (key-value pairs), stride=1 for Set/WeakSet (values).
/// Returns -1 if not found.
fn int find_in_array_part(HObject* obj, TVal val, uint stride) {
    uint count = obj.array_used;
    for (uint i = 0; i < count; i += stride) {
        if (same_value_zero(obj.array_part()[i], val)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// Collection constructor helper (shared by Map, Set, WeakMap, WeakSet)
// ============================================================================

/// Throws a TypeError built from `msg` and marks ctx to throw / return undefined.
/// Allocs an Error object with the given prototype and message, then marks
/// ctx to throw it. Does not touch ctx.result — callers that need
/// ctx.result.set_undefined() (the common case for builtin call handlers)
/// should call builtin_throw() instead.
fn void builtin_throw_no_result_change(BuiltinContext* ctx, HObject* proto, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = proto;
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        if (msg_str != null) {
            TVal msg_val; msg_val.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
}

/// Allocs an Error object with the given prototype and message, marks ctx to
/// throw it, and sets ctx.result to undefined (the standard pattern for
/// builtin call handlers that bail out immediately after throwing).
fn void builtin_throw(BuiltinContext* ctx, HObject* proto, char[] msg) {
    builtin_throw_no_result_change(ctx, proto, msg);
    ctx.result.set_undefined();
}

fn void coll_throw(BuiltinContext* ctx, char[] msg) {
    builtin_throw(ctx, ctx.heap.type_err_proto, msg);
}

/// Shared constructor body for Map/Set/WeakMap/WeakSet (ES6 §23.1.1, §23.2.1,
/// §23.3.1, §23.4.1). Allocates the collection object, then if an iterable
/// argument is provided populates it via the adder method ("set" for
/// Map/WeakMap, "add" for Set/WeakSet) using the iterator protocol.
///
/// is_pair: true for Map/WeakMap (entries are [k,v], adder called with 2 args),
///          false for Set/WeakSet (entries are single values, adder called with 1 arg).
/// allow_array_fallback: true for Map/Set (fall back to array-like indexed
///          iteration when @@iterator is missing), false for WeakMap/WeakSet
///          (throw "iterable argument is not iterable" instead — matches
///          V8/SpiderMonkey behavior per ES2015 §7.4.1 GetIterator).
/// requires_new_msg / arg_not_object_msg / adder_not_callable_msg / not_iterable_msg:
///          pre-built full error messages (avoids runtime string formatting).
fn void coll_construct(BuiltinContext* ctx, hobject::ObjClass obj_class, HObject* proto,
                        char[] requires_new_msg, char[] arg_not_object_msg,
                        char[] adder_name, char[] adder_not_callable_msg,
                        char[] not_iterable_msg, bool is_pair, bool allow_array_fallback) {
    if (!ctx.is_constructor) {
        coll_throw(ctx, requires_new_msg);
        return;
    }
    HObject*? obj_raw = ctx.heap.alloc_object(obj_class);
    if (catch err = obj_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* coll = obj_raw;
    coll.prototype = proto;

    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (!arg.is_null() && !arg.is_undefined()) {
            if (!arg.is_object()) {
                coll_throw(ctx, arg_not_object_msg);
                return;
            }
            // Get(coll, adder_name); must throw/return abruptly per spec.
            // builtins_generic_get invokes prototype accessors correctly
            // (ES5 §8.12.3 / ES2020 §10.1.8.1 OrdinaryGet) and propagates
            // accessor-throwing to ctx.should_throw.
            TVal coll_tv; coll_tv.set_object(coll);
            HString* adder_key = builtin_intern_string(ctx.heap, adder_name);
            TVal adder;
            adder.set_undefined();
            if (adder_key != null) {
                TVal? adder_opt = builtins::builtins_generic_get(coll, adder_key, ctx);
                if (catch err = adder_opt) {
                    ctx.result.set_undefined();
                    return;
                }
                adder = adder_opt;
            }
            bool adder_callable = adder.is_lightfunc() ||
                (adder.is_object() && adder.get_heapptr() != null &&
                 ((HObject*)adder.get_heapptr()).is_callable());
            if (!adder_callable) {
                coll_throw(ctx, adder_not_callable_msg);
                return;
            }
            HObject* iterable = (HObject*)arg.get_heapptr();
            HString* iter_sym = ensure_iterator_symbol(ctx.heap);
            if (iter_sym == null) { ctx.result.set_undefined(); return; }
            TVal iter_fn;
            iter_fn.set_undefined();
            if (try found_iter_fn = iterable.get_prop_proto(iter_sym)) { iter_fn = found_iter_fn; }
            bool iter_callable = iter_fn.is_lightfunc() ||
                (iter_fn.is_object() && iter_fn.get_heapptr() != null &&
                 ((HObject*)iter_fn.get_heapptr()).is_callable());
            if (!iter_callable) {
                if (!allow_array_fallback) {
                    // ES2015 §7.4.1 GetIterator (sync): obj[@@iterator]() throws
                    // TypeError when @@iterator is missing. Newer specs add the
                    // array-like fallback, but V8/SpiderMonkey still throw here.
                    coll_throw(ctx, not_iterable_msg);
                    return;
                }
                // Fall back to simple array-like iteration. Per ES6 §23.1.1.2 SetStatus
                // step 6: k = Get(next, "key"); v = Get(next, "value"); status = Call(adder, M, k, v).
                uint len = array_get_length(iterable, ctx.heap);
                for (uint i = 0; i < len; i++) {
                    TVal elem = array_get_elem(iterable, i, ctx.heap);
                    if (is_pair) {
                        if (elem.is_object() && elem.get_heapptr() != null) {
                            HObject* pair_obj = (HObject*)elem.get_heapptr();
                            TVal k = array_get_elem(pair_obj, 0, ctx.heap);
                            TVal v = array_get_elem(pair_obj, 1, ctx.heap);
                            TVal[2] adder_args = { k, v };
                            TVal coll_tv2; coll_tv2.set_object(coll);
                            ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 2, coll_tv2);
                            if (ctx.heap.has_error) {
                                ctx.should_throw = true;
                                ctx.throw_value = ctx.heap.error_value;
                                ctx.heap.has_error = false;
                                ctx.result.set_undefined();
                                return;
                            }
                        }
                    } else {
                        TVal[1] adder_args = { elem };
                        TVal coll_tv2; coll_tv2.set_object(coll);
                        ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 1, coll_tv2);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                            ctx.result.set_undefined();
                            return;
                        }
                    }
                }
            } else {
                // Iterator-based path (ES6 §23.1.1.1.5 AddEntriesFromIterable and analogues).
                TVal iterator = ctx.heap.call_fn(ctx.vm, iter_fn, null, 0, arg);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    ctx.result.set_undefined();
                    return;
                }
                if (!iterator.is_object() || iterator.get_heapptr() == null) {
                    if (allow_array_fallback) {
                        coll_throw(ctx, "Iterator result is not an object");
                        return;
                    }
                    ctx.result.set_undefined();
                    return;
                }
                HObject* iter_obj = (HObject*)iterator.get_heapptr();
                HString* next_key = builtin_intern_string(ctx.heap, "next");
                if (next_key == null) { ctx.result.set_undefined(); return; }
                while (true) {
                    TVal next_fn;
                    next_fn.set_undefined();
                    if (try found_next_fn = iter_obj.get_prop_proto(next_key)) { next_fn = found_next_fn; }
                    if (!next_fn.is_object() || ((HObject*)next_fn.get_heapptr()) == null ||
                        !((HObject*)next_fn.get_heapptr()).is_callable()) {
                        break;
                    }
                    TVal result = ctx.heap.call_fn(ctx.vm, next_fn, null, 0, iterator);
                    if (ctx.heap.has_error) {
                        ctx.should_throw = true;
                        ctx.throw_value = ctx.heap.error_value;
                        ctx.heap.has_error = false;
                        ctx.result.set_undefined();
                        return;
                    }
                    if (!result.is_object() || result.get_heapptr() == null) break;
                    HObject* res_obj = (HObject*)result.get_heapptr();
                    HString* done_key = builtin_intern_string(ctx.heap, "done");
                    TVal done_val;
                    done_val.set_undefined();
                    if (done_key != null) {
                        TVal? dv = res_obj.get_prop_proto(done_key);
                        if (try d = dv) { done_val = d; }
                    }
                    if (done_val.is_boolean() && done_val.get_boolean()) break;

                    HString* value_key = builtin_intern_string(ctx.heap, "value");
                    TVal val_tv;
                    val_tv.set_undefined();
                    if (value_key != null) {
                        TVal? vv = res_obj.get_prop_proto(value_key);
                        if (try v = vv) { val_tv = v; }
                    }
                    if (is_pair) {
                        if (val_tv.is_object() && val_tv.get_heapptr() != null) {
                            HObject* pair_obj = (HObject*)val_tv.get_heapptr();
                            TVal k = array_get_elem(pair_obj, 0, ctx.heap);
                            TVal v = array_get_elem(pair_obj, 1, ctx.heap);
                            TVal[2] adder_args = { k, v };
                            TVal coll_tv2; coll_tv2.set_object(coll);
                            ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 2, coll_tv2);
                            if (ctx.heap.has_error) {
                                ctx.should_throw = true;
                                ctx.throw_value = ctx.heap.error_value;
                                ctx.heap.has_error = false;
                                ctx.result.set_undefined();
                                return;
                            }
                        }
                    } else {
                        if (!val_tv.is_undefined()) {
                            TVal[1] adder_args = { val_tv };
                            TVal coll_tv2; coll_tv2.set_object(coll);
                            ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 1, coll_tv2);
                            if (ctx.heap.has_error) {
                                ctx.should_throw = true;
                                ctx.throw_value = ctx.heap.error_value;
                                ctx.heap.has_error = false;
                                ctx.result.set_undefined();
                                return;
                            }
                        }
                    }
                }
            }
        }
    }

    ctx.result.set_object(coll);
}

// ============================================================================
// Collection mutator helpers (shared by Map/Set/WeakMap/WeakSet .set/.add/.delete)
// ============================================================================

/// Shared body for Map.prototype.set / WeakMap.prototype.set (ES6 §23.1.3.9 / §23.3.3.5).
/// require_object_key: true for WeakMap (throws "Invalid value used as weak map key"
/// if the key is not an object), false for Map (any key allowed).
/// grow_hwm: true for Map (array_used is a high-water mark that must include slots
/// with undefined keys/values for iteration), false for WeakMap (not iterable, so
/// set_array_idx's own count is enough — matches original WeakMap behavior exactly).
fn void coll_set_entry(BuiltinContext* ctx, HObject* coll, uint stride, bool require_object_key,
                        char[] invalid_key_msg, bool grow_hwm) {
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }
    TVal key = ctx.regs[ctx.base_reg];
    if (require_object_key && (!key.is_object() || key.get_heapptr() == null)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, invalid_key_msg);
        ctx.result.set_undefined();
        return;
    }
    TVal value = ctx.regs[ctx.base_reg + 1];  // undefined if not provided
    int found = find_in_array_part(coll, key, stride);
    if (found >= 0) {
        TVal* v_slot = &coll.array_part()[(uint)found + 1];
        if (grow_hwm && v_slot.is_string()) ctx.heap.decref_tval(v_slot);
        *v_slot = value;
    } else {
        uint cnt = coll.array_used;
        coll.set_array_idx(cnt, key);
        coll.set_array_idx(cnt + 1, value);
        if (grow_hwm && coll.array_used <= cnt + 1) {
            coll.array_used = (ushort)(cnt + 2);
        }
    }
    ctx.result.set_object(coll);
}

/// Shared body for Set.prototype.add / WeakSet.prototype.add (ES6 §23.2.3.1 / §23.4.3.1).
/// require_object_value: true for WeakSet (throws "Invalid value used in weak set" if
/// the value is not an object), false for Set (any value allowed).
/// grow_hwm: true for Set (array_used high-water mark must include undefined slots
/// for iteration), false for WeakSet (not iterable).
fn void coll_add_value(BuiltinContext* ctx, HObject* coll, bool require_object_value,
                        char[] invalid_value_msg, bool grow_hwm) {
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }
    TVal value = ctx.regs[ctx.base_reg];
    if (require_object_value && (!value.is_object() || value.get_heapptr() == null)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, invalid_value_msg);
        ctx.result.set_undefined();
        return;
    }
    int found = find_in_array_part(coll, value, 1);
    if (found < 0) {
        uint idx = coll.array_used;
        coll.set_array_idx(idx, value);
        if (grow_hwm && coll.array_used <= idx) {
            coll.array_used = (ushort)(idx + 1);
        }
    }
    ctx.result.set_object(coll);
}

/// Shared body for Map/Set.prototype.delete (tombstone: mark deleted, keep slot —
/// preserves array_used as a high-water mark so live iterators continue correctly)
/// and WeakMap/WeakSet.prototype.delete (compact: shift subsequent entries down and
/// shrink array_used — safe since Weak collections are not iterable).
/// stride=2 for Map/WeakMap (key+value slots), stride=1 for Set/WeakSet (value only).
fn void coll_delete(BuiltinContext* ctx, HObject* coll, TVal key, uint stride, bool tombstone) {
    int found = find_in_array_part(coll, key, stride);
    if (found < 0) { ctx.result.set_boolean(false); return; }
    if (tombstone) {
        for (uint i = 0; i < stride; i++) {
            TVal* slot = &coll.array_part()[(uint)found + i];
            if (slot.is_string()) ctx.heap.decref_tval(slot);
            slot.set_deleted();
        }
    } else {
        uint cnt = coll.array_used;
        for (uint i = (uint)found; i + stride < cnt; i++) {
            coll.array_part()[i] = coll.array_part()[i + stride];
        }
        for (uint i = 0; i < stride; i++) {
            coll.array_part()[cnt - stride + i].set_undefined();
        }
        coll.array_used = (ushort)(cnt - stride);
    }
    ctx.result.set_boolean(true);
}

// ============================================================================
// ToString helper (ES3 ToString for primitive types)
// ============================================================================

fn HString* builtin_to_string(Heap* heap, TVal* val) {
    switch (val.get_tag()) {
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            // Symbols need special handling: ToString(symbol) = "Symbol(description)"
            if (s != null && s.is_symbol()) {
                // Build "Symbol(description)" string
                char[] desc = "";
                if (s.blen > 1) {
                    char* ptr = s.get_cstr();
                    desc = ptr[1:(sz)(s.blen - 1)];
                }
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
                return builtin_intern_string(heap, result_buf[:(uint)pos]);
            }
            return s;
        }
        case NUMBER: {
            double d = val.get_number();
            // ES5 §9.8.1: ToString(Infinity) = "Infinity", ToString(NaN) = "NaN"
            if (math::is_nan(d)) return (HString*)heap.strs[heap::BuiltinStr.NAN_STR];
            if (math::is_inf(d)) {
                return (d > 0.0)
                    ? (HString*)heap.strs[heap::BuiltinStr.POSITIVE_INFINITY]
                    : (HString*)heap.strs[heap::BuiltinStr.NEGATIVE_INFINITY];
            }
            // ES5 §9.8.1: ToString(number) — -0 must produce "0", not "-0"
            if (d == 0.0) {
                return builtin_intern_string(heap, "0");
            }
            // ES5 §9.8.1 steps 5-7: integers with |val| < 10^21 use decimal notation
            if (d == math::trunc(d) && d > -1e21 && d < 1e21) {
                char[64] ibuf;
                int ilen = libc::snprintf(&ibuf, 64, "%.0f", d);
                if (ilen >= 0 && ilen < 64) {
                    return builtin_intern_string(heap, ibuf[:ilen]);
                }
            }
            // ES5 §9.8.1: non-integer numbers — compute base-10 exponent
            double abs_d = d < 0.0 ? -d : d;
            int exp10 = (int)math::floor(math_log10(abs_d));
            char[64] buf;
            int len;
            ulong val_bits = bitcast(d, ulong);
            if (exp10 >= -6 && exp10 < 21) {
                // ES5 §9.8.1 step 5: decimal notation
                int k = exp10 + 1;
                if (k < 1) k = 1;
                int nfrac = 17 - k;
                if (nfrac < 0) nfrac = 0;
                len = libc::snprintf(&buf, 64, "%.*f", nfrac, d);
                // Trim trailing zeros after decimal point
                while (len > 1 && buf[len - 1] == '0' && buf[len - 2] != '.') len--;
                if (len > 1 && buf[len - 1] == '.') len--;
                // Progressively trim trailing digits while round-trip holds
                buf[len] = 0;
                while (len > 0) {
                    char last = buf[len - 1];
                    if (last == '.' || last == '-') break;
                    buf[len - 1] = 0;
                    double parsed = libc::strtod(&buf, null);
                    if (bitcast(parsed, ulong) == val_bits) {
                        len--;
                    } else {
                        buf[len - 1] = last;
                        break;
                    }
                }
            } else {
                // ES5 §9.8.1 step 6: exponential notation
                len = libc::snprintf(&buf, 64, "%.15e", d);
                // Trim trailing zeros AFTER the decimal point but BEFORE 'e'.
                // e.g. "1.000000000000000e+21" → "1e+21"
                // Find the decimal point
                int dot_pos = -1;
                int e_pos = len;
                for (int j = 0; j < len; j++) {
                    if (buf[j] == '.') dot_pos = j;
                    if (buf[j] == 'e' || buf[j] == 'E') { e_pos = j; break; }
                }
                if (dot_pos >= 0) {
                    // Trim zeros between dot and 'e'
                    int trim = e_pos;
                    while (trim > dot_pos + 1 && buf[trim - 1] == '0') trim--;
                    // If only the dot remains between mantissa digits and 'e', remove it too
                    if (trim == dot_pos + 1) trim = dot_pos;
                    // Shift everything after trim left
                    int shift = e_pos - trim;
                    if (shift > 0) {
                        for (int j = trim; j + shift < len; j++) buf[j] = buf[j + shift];
                        len -= shift;
                    }
                }
                // Remove leading zero in exponent: e-07 → e-7, e+07 → e+7
                int ei = len - 1;
                while (ei > 0 && buf[ei] != 'e' && buf[ei] != 'E') ei--;
                if (ei > 0 && ei + 3 < len && buf[ei + 2] == '0') {
                    for (int j = ei + 3; j < len; j++) buf[j - 1] = buf[j];
                    len--;
                }
            }
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

/// VM-aware ToInteger (ES2022 §7.1.5): properly handles objects by calling
/// ToPrimitive via the VM (invoking valueOf/toString).  When ToPrimitive
/// returns a non-primitive, throws TypeError instead of silently returning 0.
fn double builtin_to_integer_vm(BuiltinContext* ctx, TVal* val) {
    if (val.is_object() && ctx.vm != null) {
        Vm* vm_ptr = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(vm_ptr, val, false);
        if (vm_ptr.throw_pending) {
            vm_ptr.throw_pending = false;
            ctx.should_throw = true;
            ctx.throw_value = vm_ptr.throw_value;
            return 0.0 / 0.0;
        }
        if (!prim.is_object()) {
            return builtin_to_integer(&prim);
        }
        // Both valueOf and toString returned non-primitives — ES2022 §7.1.5 step 4b
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert object to primitive value");
        return 0.0 / 0.0;
    }
    return builtin_to_integer(val);
}

/// Helper: clamp to int and coerce to range [0, len].
fn uint clamp_index(double d, uint len) {
    if (math::is_nan(d)) return 0;
    if (d < 0) return 0;
    if (d >= (double)len) return len;
    return (uint)(long)d;
}

fn bool is_regexp_object(TVal* val) {
    if (!val.is_object() || val.get_heapptr() == null) return false;
    HObject* obj = (HObject*)val.get_heapptr();
    return obj.get_class() == hobject::ObjClass.REGEXP && (*obj.extra_ptr()).regexp.regexp_data != null;
}

fn double builtin_to_number_getdouble(BuiltinContext* ctx, TVal* val) {
    if (val.is_fastint()) return (double)val.get_fastint();
    if (val.is_number()) return val.get_number();
    TVal num;
    builtin_to_number(val, &num);
    if (num.is_fastint()) return (double)num.get_fastint();
    return num.get_number();
}

/// ToNumber for builtins with VM access — calls ToPrimitive(value) then ToNumber.
/// This properly handles objects by calling valueOf() first, then toString().
fn double builtin_to_number_vm(BuiltinContext* ctx, TVal* val) {
    if (val.is_fastint()) return (double)val.get_fastint();
    if (val.get_tag() == types::TValTag.NUMBER) return val.get_number();
    if (val.is_object() && ctx.vm != null) {
        Vm* vm_ptr = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(vm_ptr, val, false);  // hint "number"
        if (vm_ptr.throw_pending) {
            // Propagate the thrown error (TypeError from to_primitive_value).
            ctx.should_throw = true;
            ctx.throw_value = vm_ptr.throw_value;
            return 0.0 / 0.0;
        }
        if (prim.is_object()) {
            // Both valueOf and toString returned non-primitives — ES2022
            // §7.1.1.1 step 3 throws TypeError. Synthesize a TypeError and
            // flag it on the context so the calling builtin propagates.
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert object to primitive value");
                if (msg_str != null) {
                    TVal msg_val;
                    msg_val.set_string(msg_str);
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    if (msg_key != null) {
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                }
                TVal err_val;
                err_val.set_object(err);
                ctx.throw_value = err_val;
            }
            ctx.should_throw = true;
            return 0.0 / 0.0;
        }
        return builtin_to_number_getdouble(ctx, &prim);
    }
    TVal num;
    builtin_to_number(val, &num);
    if (num.is_fastint()) return (double)num.get_fastint();
    return num.get_number();
}

/// ToString for builtins with VM access — calls ToPrimitive(value, "string") then ToString.
/// This properly handles objects by calling toString() first, then valueOf().
fn HString* builtin_to_string_vm(BuiltinContext* ctx, TVal* val) {
    if (val.is_string()) return (HString*)val.get_heapptr();
    if (val.is_object() && ctx.vm != null) {
        Vm* vm_ptr = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(vm_ptr, val, true);  // hint "string"
        if (vm_ptr.throw_pending) return null;
        if (prim.is_string()) return (HString*)prim.get_heapptr();
        if (prim.is_object()) return null;  // ToPrimitive returned object
        return builtin_to_string(ctx.heap, &prim);
    }
    return builtin_to_string(ctx.heap, val);
}

// ============================================================================
// BuiltinMeta — metadata for LIGHTFUNC builtins
// ============================================================================

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
        case 165: return { "create", 2 };
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
        case 187: return { "copyWithin", 2 };
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
        case 261: return { "toLocaleString", 0 };
        case 262: return { "toLocaleDateString", 0 };
        case 263: return { "toLocaleTimeString", 0 };
        case 264: return { "", 1 };  // Promise resolve callback (no name)
        case 265: return { "", 1 };  // Promise reject callback (no name)
        case 301: return { "toDateString", 0 };
        case 302: return { "toTimeString", 0 };
        case 303: return { "replaceAll", 2 };
        case 304: return { "matchAll", 1 };
        case 305: return { "normalize", 0 };
        case 306: return { "getOwnPropertySymbols", 1 };
        case 307: return { "findLast", 1 };
        case 308: return { "findLastIndex", 1 };
        case 310: return { "ownKeys", 1 };
        case 266: return { "allSettled", 1 };
        case 267: return { "any", 1 };
        case 268: return { "AggregateError", 2 };
        case 311: return { "captureStackTrace", 2 };
        case 269: return { "next", 0 };
        case 270: return { "next", 0 };
        case 271: return { "[Symbol.iterator]", 0 };
        case 272: return { "[Symbol.iterator]", 0 };
        case 285: return { "from", 1 };
        case 291: return { "forEach", 1 };
        case 292: return { "map", 1 };
        case 293: return { "filter", 1 };
        case 294: return { "every", 1 };
        case 295: return { "some", 1 };
        case 296: return { "reduce", 1 };
        case 297: return { "reduceRight", 1 };
        case 312: return { "toString", 0 };
        case 325: return { "[Symbol.match]", 1 };
        case 326: return { "[Symbol.search]", 1 };
        case 327: return { "[Symbol.replace]", 2 };
        case 328: return { "[Symbol.split]", 2 };
        case 329: return { "next", 0 };
        default: return { "", -1 };
    }
}

// ============================================================================
// Registration helpers (shared across submodules)
// ============================================================================

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
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)fn_index;
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
    (*func_obj.extra_ptr()).func.comp_func = func;
    (*func_obj.extra_ptr()).func.builtin_fn_index = -1;
    (*func_obj.extra_ptr()).func.var_env = global_env;
    (*func_obj.extra_ptr()).func.lex_env = global_env;
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
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)fn_index;
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

/// Register a global constant with ES5 §15.1 flags:
/// {writable: false, enumerable: false, configurable: false}.
/// Used for `undefined`, `NaN`, `Infinity`.
fn bool register_global_immutable(EnvRecord* global_env, Heap* heap, char[] name,
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
        val.set_string(null);
    } else {
        val.set_number(number_val);
    }
    env::env_declare_immutable(global_env, key, val);
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
/// .length: non-writable, non-enumerable, configurable (ES5 §15.3.5.1)
fn void set_func_ctor_name_length(HObject* func_obj, Heap* heap, char[] name, int length) {
    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_hstr = builtin_intern_string(heap, name);
    TVal name_tv; name_tv.set_string(name_hstr);
    func_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);

    HString* length_key = builtin_intern_string(heap, "length");
    TVal length_tv; length_tv.set_fastint((long)length);
    func_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);
}

/// Set .name on a built-in constructor HObject (when .length is already set).
fn void set_func_ctor_name(HObject* func_obj, Heap* heap, char[] name) {
    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_hstr = builtin_intern_string(heap, name);
    TVal name_tv; name_tv.set_string(name_hstr);
    func_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
}

// ============================================================================
// Dispatch table
// ============================================================================

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
    [BUILTIN_ARRAY_PROTO_FIND] = &builtin_array_proto_find,
    [BUILTIN_ARRAY_PROTO_FINDINDEX] = &builtin_array_proto_findIndex,
    [BUILTIN_ARRAY_PROTO_FINDLAST] = &builtin_array_proto_findLast,
    [BUILTIN_ARRAY_PROTO_FINDLASTINDEX] = &builtin_array_proto_findLastIndex,
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
    [BUILTIN_DATE_PROTO_TOISOSTRING] = &builtin_date_proto_toISOString,
    [BUILTIN_DATE_PROTO_TOJSON] = &builtin_date_proto_toJSON,
    [BUILTIN_DATE_PROTO_TOLOCALEDATESTRING] = &builtin_date_proto_toLocaleDateString,
    [BUILTIN_DATE_PROTO_TOLOCALESTRING] = &builtin_date_proto_toLocaleString,
    [BUILTIN_DATE_PROTO_TOLOCALETIMESTRING] = &builtin_date_proto_toLocaleTimeString,
    [BUILTIN_DATE_PROTO_TODATESTRING] = &builtin_date_proto_toDateString,
    [BUILTIN_DATE_PROTO_TOTIMESTRING] = &builtin_date_proto_toTimeString,
    [BUILTIN_DATE_PROTO_TOSTRING] = &builtin_date_proto_toString,
    [BUILTIN_DATE_PROTO_TOUTCSTRING] = &builtin_date_proto_toUTCString,
    [BUILTIN_DATE_PROTO_VALUEOF] = &builtin_date_proto_valueOf,
    [BUILTIN_DATE_UTC] = &builtin_date_utc,
    [BUILTIN_DECODE_URI] = &builtin_decode_uri,
    [BUILTIN_DECODE_URI_COMPONENT] = &builtin_decode_uri_component,
    [BUILTIN_ENCODE_URI] = &builtin_encode_uri,
    [BUILTIN_ENCODE_URI_COMPONENT] = &builtin_encode_uri_component,
    [BUILTIN_ERROR] = &builtin_error,
    [BUILTIN_ERROR_CAPTURE_STACK_TRACE] = &builtin_error_captureStackTrace,
    [BUILTIN_ERROR_PROTO_TOSTRING] = &builtin_error_prototype_to_string,
    [BUILTIN_EVAL] = &builtin_eval,
    [BUILTIN_EVAL_ERROR] = &builtin_eval_error,
    [BUILTIN_FUNCTION] = &builtin_function,
    [BUILTIN_FUNCTION_PROTO_APPLY] = &builtin_function_proto_apply,
    [BUILTIN_FUNCTION_PROTO_BIND] = &builtin_function_proto_bind,
    [BUILTIN_FUNCTION_PROTO_CALL] = &builtin_function_proto_call,
    [BUILTIN_FUNCTION_PROTO_SPECIES_GETTER] = &builtin_function_proto_species_getter,
    [BUILTIN_FUNCTION_PROTO_TOSTRING] = &builtin_function_proto_toString,
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
    [BUILTIN_MAP_PROTO_SIZE_GET] = &builtin_map_proto_size_get,
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
    [BUILTIN_OBJECT_GETOWNPROPERTYSYMBOLS] = &builtin_object_getOwnPropertySymbols,
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
    [BUILTIN_PROMISE_ALL_RESOLVE_ELEMENT] = &builtin_promise_all_resolve_element,
    [BUILTIN_PROMISE_ALL_REJECT_ELEMENT] = &builtin_promise_all_reject_element,
    [BUILTIN_PROMISE_RACE_RESOLVE_ELEMENT] = &builtin_promise_race_resolve_element,
    [BUILTIN_PROMISE_RACE_REJECT_ELEMENT] = &builtin_promise_race_reject_element,
    [BUILTIN_PROMISE_ALLSETTLED] = &builtin_promise_allsettled,
    [BUILTIN_PROMISE_ALLSETTLED_RESOLVE_ELEMENT] = &builtin_promise_allsettled_resolve_element,
    [BUILTIN_PROMISE_ALLSETTLED_REJECT_ELEMENT] = &builtin_promise_allsettled_reject_element,
    [BUILTIN_PROMISE_ANY] = &builtin_promise_any,
    [BUILTIN_PROMISE_ANY_RESOLVE_ELEMENT] = &builtin_promise_any_resolve_element,
    [BUILTIN_PROMISE_ANY_REJECT_ELEMENT] = &builtin_promise_any_reject_element,
    [BUILTIN_PROMISE_SYNTHETIC_EXECUTOR] = &builtin_promise_synthetic_executor,
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
    [BUILTIN_REGEXP_PROTO_SYMBOL_MATCH] = &builtin_regexp_proto_symbol_match,
    [BUILTIN_REGEXP_PROTO_SYMBOL_SEARCH] = &builtin_regexp_proto_symbol_search,
    [BUILTIN_REGEXP_PROTO_SYMBOL_REPLACE] = &builtin_regexp_proto_symbol_replace,
    [BUILTIN_REGEXP_PROTO_SYMBOL_SPLIT] = &builtin_regexp_proto_symbol_split,
    [BUILTIN_REGEXP_PROTO_TEST] = &builtin_regexp_proto_test,
    [BUILTIN_REGEXP_PROTO_TOSTRING] = &builtin_regexp_proto_toString,
    [BUILTIN_REGEXP_STRING_ITERATOR_NEXT] = &builtin_regexp_string_iterator_next,
    [BUILTIN_ASYNC_RESUME] = &builtin_async_resume,
    [BUILTIN_ASYNC_REJECT] = &builtin_async_reject,
    [BUILTIN_REFLECT_OWNKEYS] = &builtin_reflect_ownKeys,
    [BUILTIN_RESET_GLOBALS] = &builtin_reset_globals,
    [BUILTIN_SET] = &builtin_set,
    [BUILTIN_SET_ITERATOR_NEXT] = &builtin_set_iterator_next,
    [BUILTIN_SET_PROTO_ADD] = &builtin_set_proto_add,
    [BUILTIN_SET_PROTO_SIZE_GET] = &builtin_set_proto_size_get,
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
    [BUILTIN_STRING_PROTO_MATCHALL] = &builtin_string_proto_matchAll,
    [BUILTIN_STRING_PROTO_NORMALIZE] = &builtin_string_proto_normalize,
    [BUILTIN_STRING_PROTO_PADEND] = &builtin_string_proto_padEnd,
    [BUILTIN_STRING_PROTO_PADSTART] = &builtin_string_proto_padStart,
    [BUILTIN_STRING_PROTO_REPEAT] = &builtin_string_proto_repeat,
    [BUILTIN_STRING_PROTO_REPLACE] = &builtin_string_proto_replace,
    [BUILTIN_STRING_PROTO_REPLACEALL] = &builtin_string_proto_replaceAll,
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
    [BUILTIN_SYMBOL_PROTO_TOPRIMITIVE] = &builtin_symbol_proto_toprimitive,
    [BUILTIN_SYMBOL_PROTO_DESCRIPTION_GET] = &builtin_symbol_proto_description_get,
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
    // TypedArray constructors
    [BUILTIN_INT8ARRAY] = &builtin_int8array,
    [BUILTIN_UINT8ARRAY] = &builtin_uint8array,
    [BUILTIN_UINT8CLAMPEDARRAY] = &builtin_uint8clampedarray,
    [BUILTIN_INT16ARRAY] = &builtin_int16array,
    [BUILTIN_UINT16ARRAY] = &builtin_uint16array,
    [BUILTIN_INT32ARRAY] = &builtin_int32array,
    [BUILTIN_UINT32ARRAY] = &builtin_uint32array,
    [BUILTIN_FLOAT32ARRAY] = &builtin_float32array,
    [BUILTIN_FLOAT64ARRAY] = &builtin_float64array,
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
            void* key = globals.prop_key_at(i);
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
            heap.checkpoint_vals[count] = globals.prop_values()[i];
            count++;
        }
        heap.checkpoint_count = count;
    } else {
        // === Restore checkpoint ===
        // Delete globals not in checkpoint
        for (uint i = globals.prop_count; i > 0; i--) {
            uint idx = i - 1;
            void* key = globals.prop_key_at(idx);
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

// ============================================================================
// Master registration function
// ============================================================================

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
    // ES5 §15.1: these are {writable: false, enumerable: false, configurable: false}
    if (!register_global_immutable(global_env, heap, "NaN", NUMBER, double::nan, 0)) return false;
    if (!register_global_immutable(global_env, heap, "Infinity", NUMBER, double::inf, 0)) return false;
    {
        // Register `undefined` — ES5 §15.1.1 value is the undefined value
        uint u_hash = heap.hash_string("undefined");
        HString* u_existing = heap.str_table_lookup("undefined", u_hash);
        HString* u_key;
        if (u_existing != null) {
            u_key = u_existing;
        } else {
            HString*? u_new = hstring::hstring_alloc(heap, "undefined", u_hash);
            if (catch err = u_new) return false;
            heap.str_table_insert(u_new);
            u_key = u_new;
        }
        TVal u_val;
        u_val.set_undefined();
        env::env_declare_immutable(global_env, u_key, u_val);
    }

    // Register Object constructor FIRST — creates Object.prototype (root of all chains)
    if (!register_object_constructor(global_env, heap)) return false;

    // Register Function constructor and prototype (call, apply, bind)
    // MUST be before all other constructors so that prototype methods created
    // by register_string_proto_method / register_array_proto_method / etc.
    // get [[Prototype]] = Function.prototype (heap.function_proto is set here).
    if (!register_function_constructor(global_env, heap)) return false;

    // Register Number constructor (with prototype and static properties)
    if (!register_number_constructor(global_env, heap)) return false;

    // Register Math object
    if (!register_math_object(global_env, heap)) return false;

    // Register JSON object (parse, stringify)
    if (!register_json_object(global_env, heap)) return false;

    // Register Reflect object (empty — spec methods added later as needed)
    {
        HObject*? reflect_raw = heap.alloc_object(hobject::ObjClass.REFLECT);
        if (catch err = reflect_raw) return false;
        TVal reflect_tv;
        reflect_tv.set_object(null);
        reflect_tv.set_fastint(0);
        reflect_tv.set_object(reflect_raw);
        if (!register_named_value(global_env, heap, "Reflect", reflect_tv)) return false;

        // Register Reflect.ownKeys
        HString* ownkeys_key = builtin_intern_string(heap, "ownKeys");
        TVal ownkeys_tv;
        ownkeys_tv.set_lightfunc((void*)(usz)BUILTIN_REFLECT_OWNKEYS);
        reflect_raw.put_prop(ownkeys_key, ownkeys_tv, hobject::PROP_FLAGS_WC);
    }

    // Register Error constructors (Error, TypeError, RangeError, ReferenceError, SyntaxError, EvalError)
    if (!register_error_builtins(global_env, heap)) return false;

    // Register Boolean constructor
    if (!register_boolean_constructor(global_env, heap)) return false;

    // Register String constructor
    if (!register_string_constructor(global_env, heap)) return false;

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

    // Register Generator constructor and prototype.  This also creates
    // the GeneratorFunction constructor as a full HObject, wires
    // GeneratorFunction.prototype → Generator.prototype, and registers
    // GeneratorFunction as a global constructor (ES6 §25.2.2).
    if (!register_generator_constructor(global_env, heap)) return false;

    // Register %IteratorPrototype% (ES6 §25.1.2) — shared prototype for all
    // built-in iterators, providing [Symbol.iterator]() that returns `this`.
    if (!register_iterator_prototype(heap)) return false;

    // Register TypedArray constructors (Int8Array, Uint8Array, etc.)
    if (!register_typed_array_constructors(global_env, heap)) return false;

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
