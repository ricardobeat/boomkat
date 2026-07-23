/// Built-in function registry for the Duktape C3 port.
/// Core: shared types, constants, helpers, dispatch table, and registration.
module duktape::builtins;

import duktape::types;
import duktape::bytecode;
import duktape::hstring;
import duktape::hbigint;
import duktape::hobject;
import duktape::heap;
import duktape::env;
import duktape::compiler;
import duktape::lexer;
import duktape::re_bindings;
import duktape::vm;
import duktape::dtoa_bindings;
import std::io;
import std::math;

// Math functions forwarded to std::math (LLVM intrinsics; verified
// bit-identical to libm). Kept behind these `math_*` names so the Math.*
// builtin call sites are unchanged.
fn double math_pow(double x, double y)  => math::pow(x, y);
fn double math_sqrt(double x)           => math::sqrt(x);
fn double math_exp(double x)            => math::exp(x);
fn double math_log(double x)            => math::ln(x);
fn double math_sin(double x)            => math::sin(x);
fn double math_cos(double x)            => math::cos(x);
fn double math_tan(double x)            => math::tan(x);
fn double math_acos(double x)           => math::acos(x);
fn double math_asin(double x)           => math::asin(x);
fn double math_atan(double x)           => math::atan(x);
fn double math_atan2(double y, double x) => math::atan2(y, x);
fn double math_cosh(double x)           => math::cosh(x);
fn double math_sinh(double x)           => math::sinh(x);
fn double math_tanh(double x)           => math::tanh(x);
fn double math_acosh(double x)          => math::acosh(x);
fn double math_asinh(double x)          => math::asinh(x);
fn double math_atanh(double x)          => math::atanh(x);
fn double math_log2(double x)           => math::log2(x);
fn double math_log10(double x)          => math::log10(x);

// No std::math equivalent — these three remain link-time libm externs.
extern fn double math_log1p(double x)         @MathLibc("log1p");
extern fn double math_expm1(double x)         @MathLibc("expm1");
extern fn double math_cbrt(double x)          @MathLibc("cbrt");

// Date/time library externals (link-time resolved via libc)
// The Tm struct mirrors C's struct tm layout exactly.

/// Stable identifiers for every native builtin function, indexed into
/// builtin_dispatch_table via `.ordinal`. Never serialized to bytecode or
/// disk — builtin_fn_index is a runtime-only field on the function object
/// (HObjectFunction / HObjectProxy), so members may be appended freely
/// without a stable numbering scheme.
enum Builtin : uint {
    PRINT,
    CONSOLE_LOG,
    CONSOLE_INFO,
    CONSOLE_DEBUG,
    CONSOLE_TRACE,
    CONSOLE_WARN,
    CONSOLE_ERROR,
    CONSOLE_DIR,
    CONSOLE_ASSERT,
    PARSE_INT,
    PARSE_FLOAT,
    IS_NAN,
    IS_FINITE,
    ERROR,
    TYPE_ERROR,
    RANGE_ERROR,
    REFERENCE_ERROR,
    SYNTAX_ERROR,
    EVAL_ERROR,
    ERROR_PROTO_TOSTRING,
    BOOLEAN,
    BOOLEAN_PROTO_TOSTRING,
    BOOLEAN_PROTO_VALUEOF,
    STRING,
    STRING_PROTO_TOSTRING,
    STRING_PROTO_VALUEOF,
    NUMBER,
    NUMBER_PROTO_TOSTRING,
    NUMBER_PROTO_VALUEOF,
    OBJECT,
    OBJECT_PROTO_TOSTRING,
    OBJECT_PROTO_VALUEOF,
    OBJECT_PROTO___PROTO___GETTER,
    OBJECT_PROTO___PROTO___SETTER,
    ARRAY,
    MATH_ABS,
    MATH_FLOOR,
    MATH_CEIL,
    MATH_ROUND,
    MATH_MAX,
    MATH_MIN,
    MATH_POW,
    MATH_SQRT,
    MATH_EXP,
    MATH_LOG,
    MATH_SIN,
    MATH_COS,
    MATH_TAN,
    MATH_RANDOM,
    STRING_PROTO_CHARAT,
    STRING_PROTO_CHARCODEAT,
    STRING_PROTO_INDEXOF,
    STRING_PROTO_SLICE,
    STRING_PROTO_SUBSTRING,
    STRING_PROTO_SUBSTR,
    STRING_PROTO_TOUPPERCASE,
    STRING_PROTO_TOLOWERCASE,
    STRING_PROTO_TRIM,
    STRING_PROTO_SPLIT,
    STRING_PROTO_CONCAT,
    STRING_PROTO_REPLACE,
    ARRAY_PROTO_TOSTRING,
    ARRAY_PROTO_JOIN,
    ARRAY_PROTO_POP,
    ARRAY_PROTO_PUSH,
    ARRAY_PROTO_REVERSE,
    ARRAY_PROTO_SHIFT,
    ARRAY_PROTO_SLICE,
    ARRAY_PROTO_SORT,
    ARRAY_PROTO_SPLICE,
    ARRAY_PROTO_UNSHIFT,
    ARRAY_PROTO_INDEXOF,
    ARRAY_PROTO_LASTINDEXOF,
    ARRAY_PROTO_CONCAT,
    NUMBER_PROTO_TOFIXED,
    NUMBER_PROTO_TOEXPONENTIAL,
    NUMBER_PROTO_TOPRECISION,
    FUNCTION_PROTO_CALL,
    FUNCTION_PROTO_APPLY,
    FUNCTION_PROTO_BIND,
    BOUND_CALL,
    EVAL,
    JSON_PARSE,
    JSON_STRINGIFY,
    DATE,
    DATE_NOW,
    DATE_UTC,
    DATE_PARSE,
    DATE_PROTO_TOSTRING,
    DATE_PROTO_TOJSON,
    DATE_PROTO_VALUEOF,
    DATE_PROTO_GETTIME,
    DATE_PROTO_GETFULLYEAR,
    DATE_PROTO_GETMONTH,
    DATE_PROTO_GETDATE,
    DATE_PROTO_GETDAY,
    DATE_PROTO_GETHOURS,
    DATE_PROTO_GETMINUTES,
    DATE_PROTO_GETSECONDS,
    DATE_PROTO_GETMILLISECONDS,
    DATE_PROTO_GETTIMEZONEOFFSET,
    FUNCTION,
    RESET_GLOBALS,
    REGEXP,
    REGEXP_PROTO_TEST,
    REGEXP_PROTO_EXEC,
    REGEXP_PROTO_TOSTRING,
    OBJECT_PROTO_HASOWNPROPERTY,
    OBJECT_PROTO_PROPERTYISENUMERABLE,
    OBJECT_PROTO_ISPROTOTYPEOF,
    OBJECT_PROTO_TOLOCALESTRING,
    DATE_PROTO_TOLOCALESTRING,
    DATE_PROTO_TOLOCALEDATESTRING,
    DATE_PROTO_TOLOCALETIMESTRING,
    PROMISE_RESOLVE_CALLBACK,
    PROMISE_REJECT_CALLBACK,
    PROMISE_ALL_RESOLVE_ELEMENT,
    PROMISE_ALL_REJECT_ELEMENT,
    PROMISE_ALLSETTLED_RESOLVE_ELEMENT,
    PROMISE_ALLSETTLED_REJECT_ELEMENT,
    PROMISE_ANY_RESOLVE_ELEMENT,
    PROMISE_ANY_REJECT_ELEMENT,
    ARRAY_ITERATOR_NEXT,
    STRING_ITERATOR_NEXT,
    STRING_PROTO_SYMBOL_ITER,
    ARRAY_PROTO_KEYS,
    ARRAY_PROTO_VALUES,
    ARRAY_PROTO_ENTRIES,
    OBJECT_FROMENTRIES,
    OBJECT_GROUPBY,
    MAP_GROUPBY,
    REGEXP_PROTO_GET_FLAGS,
    REGEXP_PROTO_GET_SOURCE,
    REGEXP_PROTO_GET_GLOBAL,
    REGEXP_PROTO_GET_IGNORECASE,
    REGEXP_PROTO_GET_MULTILINE,
    REGEXP_PROTO_GET_DOTALL,
    REGEXP_PROTO_GET_STICKY,
    REGEXP_PROTO_GET_UNICODE,
    ARRAY_FROM,
    ITERATOR_PROTO_SYMBOL_ITER,
    MAP_ITERATOR_NEXT,
    SET_ITERATOR_NEXT,
    ARRAY_PROTO_FOREACH,
    ARRAY_PROTO_MAP,
    ARRAY_PROTO_FILTER,
    ARRAY_PROTO_EVERY,
    ARRAY_PROTO_SOME,
    ARRAY_PROTO_REDUCE,
    ARRAY_PROTO_REDUCERIGHT,
    STRING_PROTO_TOLOCALELOWERCASE,
    STRING_PROTO_TOLOCALEUPPERCASE,
    STRING_PROTO_LOCALECOMPARE,
    ARRAY_PROTO_FINDLAST,
    ARRAY_PROTO_FINDLASTINDEX,
    FUNCTION_PROTO_TOSTRING,
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
    REGEXP_PROTO_SYMBOL_MATCH,
    REGEXP_PROTO_SYMBOL_SEARCH,
    REGEXP_PROTO_SYMBOL_REPLACE,
    REGEXP_PROTO_SYMBOL_SPLIT,
    REGEXP_PROTO_SYMBOL_MATCHALL,
    REGEXP_STRING_ITERATOR_NEXT,
    ASYNC_RESUME,
    ASYNC_REJECT,
    PROMISE_SYNTHETIC_EXECUTOR,
    REGEXP_PROTO_GET_HASINDICES,
    REGEXP_PROTO_GET_UNICODESETS,
    ARRAYBUFFER,
    ARRAYBUFFER_ISVIEW,
    ARRAYBUFFER_PROTO_BYTELENGTH_GET,
    ARRAYBUFFER_PROTO_SLICE,
    ARRAYBUFFER_PROTO_DETACHED_GET,
    ARRAYBUFFER_SPECIES_GET,
    DETACH_ARRAYBUFFER,
    TYPEDARRAY_PROTO_LENGTH_GET,
    TYPEDARRAY_PROTO_BYTELENGTH_GET,
    TYPEDARRAY_PROTO_BYTEOFFSET_GET,
    TYPEDARRAY_PROTO_BUFFER_GET,
    TYPEDARRAY_PROTO_TOSTRINGTAG_GET,
    DATAVIEW,
    DATAVIEW_PROTO_BUFFER_GET,
    DATAVIEW_PROTO_BYTELENGTH_GET,
    DATAVIEW_PROTO_BYTEOFFSET_GET,
    DATAVIEW_GET_INT8,
    DATAVIEW_GET_UINT8,
    DATAVIEW_GET_INT16,
    DATAVIEW_GET_UINT16,
    DATAVIEW_GET_INT32,
    DATAVIEW_GET_UINT32,
    DATAVIEW_GET_FLOAT32,
    DATAVIEW_GET_FLOAT64,
    DATAVIEW_SET_INT8,
    DATAVIEW_SET_UINT8,
    DATAVIEW_SET_INT16,
    DATAVIEW_SET_UINT16,
    DATAVIEW_SET_INT32,
    DATAVIEW_SET_UINT32,
    DATAVIEW_SET_FLOAT32,
    DATAVIEW_SET_FLOAT64,
    TA_PROTO_VALUES,
    TA_PROTO_KEYS,
    TA_PROTO_ENTRIES,
    TA_PROTO_SET,
    TA_PROTO_SUBARRAY,
    TA_PROTO_FILL,
    TA_PROTO_COPYWITHIN,
    TA_PROTO_SLICE,
    TA_PROTO_INDEX_OF,
    TA_PROTO_LAST_INDEX_OF,
    TA_PROTO_INCLUDES,
    TA_PROTO_JOIN,
    TA_PROTO_FOR_EACH,
    TA_PROTO_EVERY,
    TA_PROTO_SOME,
    TA_PROTO_REDUCE,
    TA_PROTO_REDUCE_RIGHT,
    TA_PROTO_MAP,
    TA_PROTO_FILTER,
    TA_PROTO_FIND,
    TA_PROTO_FIND_INDEX,
    TA_PROTO_FIND_LAST,
    TA_PROTO_FIND_LAST_INDEX,
    TA_PROTO_REVERSE,
    TA_PROTO_TO_REVERSED,
    TA_PROTO_AT,
    TA_PROTO_SORT,
    TA_PROTO_TO_SORTED,
    TA_PROTO_WITH,
    TA_PROTO_TO_STRING,
    TA_PROTO_TO_LOCALE_STRING,
    TA_OF,
    TA_FROM,
    // Uint8Array base64/hex (tc39 proposal-arraybuffer-base64)
    UINT8ARRAY_FROM_BASE64,
    UINT8ARRAY_FROM_HEX,
    UINT8ARRAY_PROTO_TO_BASE64,
    UINT8ARRAY_PROTO_TO_HEX,
    UINT8ARRAY_PROTO_SET_FROM_BASE64,
    UINT8ARRAY_PROTO_SET_FROM_HEX,
    TYPEDARRAY_INTRINSIC,
    FUNCTION_PROTO_HASINSTANCE,
    DATE_PROTO_TOPRIMITIVE,
    OBJECT_GETOWNPROPERTYDESCRIPTORS,
    PROMISE_SPECIES_GETTER,
    ASYNC_FUNCTION,
    PROXY,
    PROXY_REVOCABLE,
    PROXY_REVOKE,
    PROXY_CALL,
    TA_SPECIES_GET,
    EVAL_SCRIPT,
    REGEXP_SPECIES_GETTER,
    MODULE_BINDING_GETTER,
    PROMISE_RESOLVE_THENABLE_JOB,
    PROMISE_THEN_FINALLY,
    PROMISE_CATCH_FINALLY,
    ARRAY_SPECIES_GETTER,
    PROMISE_IDENTITY,
    REFLECT_GET,
    REFLECT_SET,
    REFLECT_HAS,
    REFLECT_DELETE_PROPERTY,
    REFLECT_GET_OWN_PROPERTY_DESCRIPTOR,
    REFLECT_DEFINE_PROPERTY,
    REFLECT_GET_PROTOTYPE_OF,
    REFLECT_SET_PROTOTYPE_OF,
    REFLECT_IS_EXTENSIBLE,
    REFLECT_PREVENT_EXTENSIONS,
    REFLECT_APPLY,
    REFLECT_CONSTRUCT,
    PROMISE_THROWER,
    MAP_SPECIES_GETTER,
    SET_SPECIES_GETTER,
    DATAVIEW_GET_BIGINT64,
    DATAVIEW_GET_BIGUINT64,
    DATAVIEW_SET_BIGINT64,
    DATAVIEW_SET_BIGUINT64,
    FUNCTION_PROTO_RESTRICTED_GETTER,
    FUNCTION_PROTO_RESTRICTED_SETTER,
    MAP,
    MAP_PROTO_SET,
    MAP_PROTO_GET,
    MAP_PROTO_HAS,
    MAP_PROTO_DELETE,
    MAP_PROTO_CLEAR,
    MAP_PROTO_KEYS,
    MAP_PROTO_VALUES,
    MAP_PROTO_ENTRIES,
    MAP_PROTO_FOREACH,
    MAP_PROTO_GETORINSERT,
    MAP_PROTO_GETORINSERTCOMPUTED,
    SET,
    SET_PROTO_ADD,
    SET_PROTO_HAS,
    SET_PROTO_DELETE,
    SET_PROTO_CLEAR,
    SET_PROTO_VALUES,
    SET_PROTO_ENTRIES,
    SET_PROTO_FOREACH,
    WEAKMAP,
    WEAKMAP_PROTO_SET,
    WEAKMAP_PROTO_GET,
    WEAKMAP_PROTO_HAS,
    WEAKMAP_PROTO_DELETE,
    WEAKMAP_PROTO_GETORINSERT,
    WEAKMAP_PROTO_GETORINSERTCOMPUTED,
    WEAKSET,
    WEAKSET_PROTO_ADD,
    WEAKSET_PROTO_HAS,
    WEAKSET_PROTO_DELETE,
    WEAKREF,
    WEAKREF_PROTO_DEREF,
    FINALIZATION_REGISTRY,
    FINALIZATION_REGISTRY_PROTO_REGISTER,
    FINALIZATION_REGISTRY_PROTO_UNREGISTER,
    SYMBOL,
    SYMBOL_FOR,
    SYMBOL_KEYFOR,
    SYMBOL_PROTO_TOSTRING,
    SYMBOL_PROTO_VALUEOF,
    SYMBOL_PROTO_TOPRIMITIVE,
    SYMBOL_PROTO_DESCRIPTION_GET,
    MAP_PROTO_SIZE_GET,
    SET_PROTO_SIZE_GET,
    PROMISE,
    PROMISE_PROTO_THEN,
    PROMISE_PROTO_CATCH,
    PROMISE_PROTO_FINALLY,
    PROMISE_RESOLVE,
    PROMISE_REJECT,
    PROMISE_ALL,
    PROMISE_RACE,
    PROMISE_ALLSETTLED,
    PROMISE_ANY,
    AGGREGATE_ERROR,
    GENERATOR_FUNCTION,
    GENERATOR_PROTO_NEXT,
    GENERATOR_PROTO_THROW,
    GENERATOR_PROTO_RETURN,
    OBJECT_KEYS,
    OBJECT_GETPROTOTYPEOF,
    OBJECT_ISEXTENSIBLE,
    OBJECT_PREVENTEXTENSIONS,
    OBJECT_GETOWNPROPERTYDESCRIPTOR,
    OBJECT_DEFINEPROPERTY,
    OBJECT_GETOWNPROPERTYNAMES,
    OBJECT_GETOWNPROPERTYSYMBOLS,
    OBJECT_DEFINEPROPERTIES,
    OBJECT_CREATE,
    OBJECT_SEAL,
    OBJECT_FREEZE,
    OBJECT_ISSEALED,
    OBJECT_ISFROZEN,
    OBJECT_ENTRIES,
    OBJECT_VALUES,
    OBJECT_ASSIGN,
    NUMBER_ISNAN,
    NUMBER_ISFINITE,
    NUMBER_ISINTEGER,
    NUMBER_ISSAFEINTEGER,
    MATH_ACOS,
    MATH_ASIN,
    MATH_ATAN,
    MATH_ATAN2,
    MATH_COSH,
    MATH_SINH,
    MATH_TANH,
    MATH_ACOSH,
    MATH_ASINH,
    MATH_ATANH,
    MATH_LOG2,
    MATH_LOG10,
    MATH_LOG1P,
    MATH_EXPM1,
    MATH_CBRT,
    MATH_HYPOT,
    MATH_TRUNC,
    MATH_SIGN,
    MATH_FROUND,
    MATH_CLZ32,
    MATH_IMUL,
    MATH_SUMPRECISE,
    ARRAY_ISARRAY,
    STRING_FROMCHARCODE,
    OBJECT_IS,
    OBJECT_HASOWN,
    OBJECT_SETPROTOTYPEOF,
    ARRAY_PROTO_FLAT,
    ARRAY_PROTO_FLATMAP,
    STRING_FROMCODEPOINT,
    ENCODE_URI,
    ENCODE_URI_COMPONENT,
    DECODE_URI,
    DECODE_URI_COMPONENT,
    URI_ERROR,
    ARRAY_PROTO_TOREVERSED,
    ARRAY_PROTO_TOSORTED,
    ARRAY_PROTO_TOSPLICED,
    ARRAY_PROTO_WITH,
    STRING_PROTO_MATCH,
    STRING_PROTO_SEARCH,
    STRING_PROTO_INCLUDES,
    STRING_PROTO_STARTSWITH,
    STRING_PROTO_ENDSWITH,
    STRING_PROTO_REPEAT,
    STRING_PROTO_TRIMSTART,
    STRING_PROTO_TRIMEND,
    STRING_PROTO_CODEPOINTAT,
    STRING_PROTO_AT,
    STRING_PROTO_PADSTART,
    STRING_PROTO_PADEND,
    STRING_PROTO_LASTINDEXOF,
    ARRAY_OF,
    ARRAY_PROTO_FILL,
    ARRAY_PROTO_FIND,
    ARRAY_PROTO_FINDINDEX,
    ARRAY_PROTO_INCLUDES,
    ARRAY_PROTO_AT,
    ARRAY_PROTO_COPYWITHIN,
    DATE_PROTO_GETUTCFULLYEAR,
    DATE_PROTO_GETUTCMONTH,
    DATE_PROTO_GETUTCDATE,
    DATE_PROTO_GETUTCDAY,
    DATE_PROTO_GETUTCHOURS,
    DATE_PROTO_GETUTCMINUTES,
    DATE_PROTO_GETUTCSECONDS,
    DATE_PROTO_GETUTCMILLISECONDS,
    DATE_PROTO_SETTIME,
    DATE_PROTO_SETMILLISECONDS,
    DATE_PROTO_SETSECONDS,
    DATE_PROTO_SETMINUTES,
    DATE_PROTO_SETHOURS,
    DATE_PROTO_SETDATE,
    DATE_PROTO_SETMONTH,
    DATE_PROTO_SETFULLYEAR,
    DATE_PROTO_SETUTCMILLISECONDS,
    DATE_PROTO_SETUTCSECONDS,
    DATE_PROTO_SETUTCMINUTES,
    DATE_PROTO_SETUTCHOURS,
    DATE_PROTO_SETUTCDATE,
    DATE_PROTO_SETUTCMONTH,
    DATE_PROTO_SETUTCFULLYEAR,
    DATE_PROTO_TOISOSTRING,
    DATE_PROTO_TOUTCSTRING,
    DATE_PROTO_TODATESTRING,
    DATE_PROTO_TOTIMESTRING,
    STRING_PROTO_REPLACEALL,
    STRING_PROTO_MATCHALL,
    STRING_PROTO_NORMALIZE,
    STRING_PROTO_ISWELLFORMED,
    STRING_PROTO_TOWELLFORMED,
    REFLECT_OWNKEYS,
    ERROR_CAPTURE_STACK_TRACE,
    STRING_RAW,
    // --- BigInt (plan 056) ---
    BIGINT,                       // BigInt(x)
    BIGINT_AS_INTN,               // BigInt.asIntN(bits, x)
    BIGINT_AS_UINTN,              // BigInt.asUintN(bits, x)
    BIGINT_PROTO_TOSTRING,        // BigInt.prototype.toString([radix])
    BIGINT_PROTO_VALUEOF,         // BigInt.prototype.valueOf()
    BIGINT_PROTO_TOLOCALESTRING,  // BigInt.prototype.toLocaleString()
    // --- %AsyncFromSyncIteratorPrototype% (plan 057, ES2018 §27.1.4) ---
    ASYNC_FROM_SYNC_NEXT,           // %AsyncFromSyncIteratorPrototype%.next(value)
    ASYNC_FROM_SYNC_RETURN,         // %AsyncFromSyncIteratorPrototype%.return(value)
    ASYNC_FROM_SYNC_THROW,          // %AsyncFromSyncIteratorPrototype%.throw(value)
    ASYNC_FROM_SYNC_VALUE_UNWRAP,   // native fulfill reaction: builds {value, done}
    ASYNC_FROM_SYNC_REJECT_FORWARD, // native reject reaction: forwards rejection
    PROMISE_WITH_RESOLVERS,         // Promise.withResolvers() (ES2024)
    PROMISE_TRY,                    // Promise.try(callbackfn, ...args) (ES2026)
    ERROR_ISERROR,                  // Error.isError(arg) (ES2026)
    // --- Set methods proposal (ES2025 §24.2.4) ---
    SET_PROTO_UNION,                // Set.prototype.union(other)
    SET_PROTO_INTERSECTION,         // Set.prototype.intersection(other)
    SET_PROTO_DIFFERENCE,           // Set.prototype.difference(other)
    SET_PROTO_SYMMETRICDIFFERENCE,  // Set.prototype.symmetricDifference(other)
    SET_PROTO_ISSUBSETOF,           // Set.prototype.isSubsetOf(other)
    SET_PROTO_ISSUPERSETOF,         // Set.prototype.isSupersetOf(other)
    SET_PROTO_ISDISJOINTFROM,       // Set.prototype.isDisjointFrom(other)
    REGEXP_ESCAPE, // RegExp.escape(string) (ES2026 proposal-regex-escaping)
    // --- Iterator Helpers (ES2025 §27.1) ---
    ITERATOR_CTOR,                  // Iterator() — throws (abstract, subclassable)
    ITERATOR_FROM,                  // Iterator.from(obj)
    ITERATOR_PROTO_CONSTRUCTOR_GET, // get Iterator.prototype.constructor
    ITERATOR_PROTO_CONSTRUCTOR_SET, // set Iterator.prototype.constructor
    ITERATOR_PROTO_TOSTRINGTAG_GET, // get Iterator.prototype[Symbol.toStringTag]
    ITERATOR_PROTO_TOSTRINGTAG_SET, // set Iterator.prototype[Symbol.toStringTag]
    ITERATOR_PROTO_MAP,
    ITERATOR_PROTO_FILTER,
    ITERATOR_PROTO_TAKE,
    ITERATOR_PROTO_DROP,
    ITERATOR_PROTO_FLATMAP,
    ITERATOR_PROTO_REDUCE,
    ITERATOR_PROTO_TOARRAY,
    ITERATOR_PROTO_FOREACH,
    ITERATOR_PROTO_SOME,
    ITERATOR_PROTO_EVERY,
    ITERATOR_PROTO_FIND,
    ITERATOR_CONCAT,
    WRAP_FOR_VALID_ITERATOR_NEXT,
    WRAP_FOR_VALID_ITERATOR_RETURN,
    ITERATOR_HELPER_NEXT,
    ITERATOR_HELPER_RETURN,
    JSON_RAW_JSON,
    JSON_IS_RAW_JSON,
    // --- Array.fromAsync (proposal-array-from-async, ES2026) ---
    ARRAY_FROM_ASYNC,               // Array.fromAsync(asyncItems, mapfn, thisArg)
    ARRAY_FROM_ASYNC_STEP_FULFILL,  // native reaction: awaited next()/element ready
    ARRAY_FROM_ASYNC_MAP_FULFILL,   // native reaction: awaited mapped value ready
    ARRAY_FROM_ASYNC_REJECT,        // native reaction: reject → close iterator, reject outer
    // --- Resizable ArrayBuffer (ES2024) ---
    ARRAYBUFFER_PROTO_RESIZE,
    ARRAYBUFFER_PROTO_RESIZABLE_GET,
    ARRAYBUFFER_PROTO_MAXBYTELENGTH_GET,
    LAST, // sentinel — one past the highest valid builtin; not a real builtin
}

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
    /// ES2015 GetPrototypeFromConstructor: the new.target passed to this constructor
    /// invocation.  Set to the subclass constructor when called via super(); set to
    /// the callee itself for a plain `new Builtin()`.  Null for non-constructor calls.
    HObject* new_target;
}

alias BuiltinFunc = fn void(BuiltinContext*);

/// ES2015 §9.1.14 OrdinaryCreateFromConstructor / §9.1.15 GetPrototypeFromConstructor.
///
/// If ctx.new_target is non-null, perform a full `Get(C, "prototype")` on it;
/// if the result is an object, return it as the instance prototype.  Otherwise
/// return default_proto.  This makes `class Sub extends Builtin {}` produce
/// instances whose __proto__ is Sub.prototype rather than the built-in prototype.
///
/// Uses full Get semantics (not get_prop_proto) so an accessor "prototype"
/// getter on `new_target` is actually invoked, and a throwing getter propagates
/// as an abrupt completion via ctx.should_throw per ES2015 §9.1.14 step 3
/// (test262 built-ins/Promise/get-prototype-abrupt).  Returns default_proto on
/// error so the VM can still consult ctx.should_throw / ctx.throw_value to
/// raise the original error when the calling builtin returns.
fn HObject* builtin_proto_from_new_target(BuiltinContext* ctx, HObject* default_proto) {
    HObject* nt = ctx.new_target;
    if (nt == null) return default_proto;
    // Avoid the trivial case: if new_target is the builtin itself (plain `new Builtin()`)
    // its ".prototype" IS default_proto, so we'd return the same value — but it's still
    // correct to do the lookup for callee-less lightfunc paths.
    HString* proto_key = (HString*)ctx.heap.strs[heap::BuiltinStr.PROTOTYPE];
    if (proto_key == null) return default_proto;
    TVal? proto_tv = builtins_generic_get(nt, proto_key, ctx);
    if (ctx.should_throw) return default_proto;
    if (try ptv = proto_tv) {
        if (ptv.is_object() && ptv.get_heapptr() != null) {
            return (HObject*)ptv.get_heapptr();
        }
    }
    return default_proto;
}

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
                    // Shortest round-trip form, same as ToString(Number).
                    char[64] nbuf;
                    char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] ntmp;
                    int nlen = dtoa_bindings::duktape_js_dtoa(&nbuf, v, 10, 0,
                        dtoa_bindings::JS_DTOA_FORMAT_FREE, &ntmp);
                    if (nlen > 0 && nlen < 64) {
                        nbuf[nlen] = 0;
                        io::printf("%s", (ZString)&nbuf);
                    } else {
                        io::printf("%f", v);
                    }
                }
            }
        case FASTINT:
            io::printf("%d", val.get_fastint());
        case STRING:
            HString* s = (HString*)val.get_heapptr();
            if (s != null) {
                hstring::write_cesu8_as_utf8(s.get_data(), &io::putchar);
            } else {
                io::printf("[null string]");
            }
        case OBJECT:
            io::printf("[object Object]");
        case LIGHTFUNC:
            io::printf("[function]");
        case BIGINT:
            char[48] bbuf;
            char[] bs = hbigint::int128_to_decimal(val.get_bigint(), bbuf[..]);
            for (usz bi = 0; bi < bs.len; bi++) { io::putchar(bs[bi]); }
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
        double r = dtoa_bindings::atod_strtod_compat((ZString)h.get_cstr(), &end);
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

    // --- skip leading ECMAScript whitespace (CESU-8 aware) ---
    uint start = 0;
    while (start < blen) {
        uint seq_len = 0;
        uint cp = decode_codepoint_at(cstr, start, blen, &seq_len);
        if (seq_len == 0 || !is_ecma_ws_codepoint(cp)) break;
        start += seq_len;
    }

    // Empty or all-whitespace -> +0
    if (start == blen) {
        return 0.0;
    }

    char* p = cstr + start;

    // --- Infinity / -Infinity / +Infinity (trailing ECMAScript whitespace ok) ---
    {
        char* q = p;
        double inf_sign = 1.0;
        if (*q == '+') { q++; }
        else if (*q == '-') { inf_sign = -1.0; q++; }
        if (mem::equals(q, (char*)"Infinity", 8)) {
            uint rest = (uint)(q - cstr) + 8;
            uint tail = rest;
            bool only_ws = true;
            while (tail < blen) {
                uint seq_len2 = 0;
                uint cp2 = decode_codepoint_at(cstr, tail, blen, &seq_len2);
                if (seq_len2 == 0 || !is_ecma_ws_codepoint(cp2)) { only_ws = false; break; }
                tail += seq_len2;
            }
            if (only_ws) return inf_sign * double::inf;
        }
    }

    // --- Reject sign-prefixed hex/binary/octal literals ---
    // ES2015 §7.1.3.1: +0x... / -0x... etc. are not valid StringNumericLiterals.
    if ((p[0] == '+' || p[0] == '-')) {
        char* q = p + 1;
        if (q[0] == '0' && (q[1] == 'x' || q[1] == 'X')) return double::nan;
        if (q[0] == '0' && (q[1] == 'b' || q[1] == 'B')) return double::nan;
        if (q[0] == '0' && (q[1] == 'o' || q[1] == 'O')) return double::nan;
    }

    // --- Hex integer literal (0x...) ---
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        uint j = 2;
        // Require at least one hex digit (ES2015 §7.1.3.1)
        if (p[j] == 0 || !((p[j] >= '0' && p[j] <= '9') || (p[j] >= 'a' && p[j] <= 'f') || (p[j] >= 'A' && p[j] <= 'F'))) {
            return double::nan;
        }
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
        // Trailing must be whitespace (codepoint-aware)
        uint trail_pos = (uint)((p + j) - cstr);
        while (trail_pos < blen) {
            uint seq_len = 0;
            uint cp = decode_codepoint_at(cstr, trail_pos, blen, &seq_len);
            if (seq_len == 0 || !is_ecma_ws_codepoint(cp)) return double::nan;
            trail_pos += seq_len;
        }
        return (double)val;
    }

    // --- Binary integer literal (0b... / 0B...) — ES2015 §7.1.3.1 ---
    // Unlike parseInt, ToNumber(String) accepts the ES2015 non-decimal
    // integer literal prefixes 0b/0o/0x (but NOT a sign or a trailing radix).
    if (p[0] == '0' && (p[1] == 'b' || p[1] == 'B')) {
        uint j = 2;
        if (p[j] != '0' && p[j] != '1') return double::nan; // require ≥1 digit
        double val = 0.0;
        while (p[j] == '0' || p[j] == '1') {
            val = val * 2.0 + (double)(p[j] - '0');
            j++;
        }
        uint trail_pos = (uint)((p + j) - cstr);
        while (trail_pos < blen) {
            uint seq_len = 0;
            uint cp = decode_codepoint_at(cstr, trail_pos, blen, &seq_len);
            if (seq_len == 0 || !is_ecma_ws_codepoint(cp)) return double::nan;
            trail_pos += seq_len;
        }
        return val;
    }

    // --- Octal integer literal (0o... / 0O...) — ES2015 §7.1.3.1 ---
    if (p[0] == '0' && (p[1] == 'o' || p[1] == 'O')) {
        uint j = 2;
        if (p[j] < '0' || p[j] > '7') return double::nan; // require ≥1 digit
        double val = 0.0;
        while (p[j] >= '0' && p[j] <= '7') {
            val = val * 8.0 + (double)(p[j] - '0');
            j++;
        }
        uint trail_pos = (uint)((p + j) - cstr);
        while (trail_pos < blen) {
            uint seq_len = 0;
            uint cp = decode_codepoint_at(cstr, trail_pos, blen, &seq_len);
            if (seq_len == 0 || !is_ecma_ws_codepoint(cp)) return double::nan;
            trail_pos += seq_len;
        }
        return val;
    }

    // --- Decimal via libc::strtod ---
    char* endptr;
    double result = dtoa_bindings::atod_strtod_compat(p, &endptr);

    // Nothing was consumed -> NaN
    if (endptr == p) {
        return double::nan;
    }

    // strtod accepts case-insensitive "infinity" text, but ES only allows the
    // exact "Infinity" spelling. Distinguish text-Infinity from numeric overflow
    // (e.g. "10e10000" legitimately overflows to Infinity): overflow input
    // begins with a digit or '.', whereas Infinity text begins with a letter
    // after the optional sign. Only reject a wrong-case Infinity *spelling*.
    if (result == double::inf || result == -double::inf) {
        char* q = p;
        if (q[0] == '+' || q[0] == '-') q++;
        bool is_inf_text = (q[0] == 'i' || q[0] == 'I');
        if (is_inf_text &&
            (ZString)p != (ZString)"Infinity" &&
            (ZString)p != (ZString)"+Infinity" &&
            (ZString)p != (ZString)"-Infinity") {
            return double::nan;
        }
    }

    // Trailing characters must be whitespace only (codepoint-aware for multi-byte Unicode ws)
    uint trail_pos = (uint)(endptr - cstr);
    while (trail_pos < blen) {
        uint seq_len = 0;
        uint cp = decode_codepoint_at(cstr, trail_pos, blen, &seq_len);
        if (seq_len == 0 || !is_ecma_ws_codepoint(cp)) {
            return double::nan;
        }
        trail_pos += seq_len;
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
            // Try fastint preservation — but not for -0 (fastint can't represent it)
            if (d != 0.0 || !math::signbit(d)) {
                long fi = (long)d;
                if ((double)fi == d && fi >= types::DUK_MIN_SAFE_INT && fi <= types::DUK_MAX_SAFE_INT) {
                    result.set_fastint(fi);
                    return;
                }
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
        case BIGINT:
            return val.get_bigint() != (int128)0;   // ToBoolean(0n) = false
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
    // Delegate to Heap.str_intern rather than duplicating lookup/alloc here
    // — it normalizes raw 4-byte UTF-8 astral sequences to CESU-8 before
    // hashing, which this hand-rolled version used to skip, causing the
    // same logical string to intern under two different byte encodings.
    return heap.str_intern(data);
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
// CanBeHeldWeakly (ES2023 §7.2.11) — shared by WeakMap key / WeakSet value /
// WeakRef target / FinalizationRegistry target+token checks.
// ============================================================================

/// True if `val` is an object, or a Symbol that is not in the global Symbol
/// registry (i.e. not created via Symbol.for — well-known symbols like
/// Symbol.iterator are fine, since only Symbol.for results are registered).
fn bool can_be_held_weakly(Heap* heap, TVal val) {
    if (val.is_object() && val.get_heapptr() != null) return true;
    if (is_symbol_val(val)) {
        HString* sym = (HString*)val.get_heapptr();
        return symbol_registry_get_key(heap, sym) == null;
    }
    return false;
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
/// allow_array_fallback: reserved for array-like indexed iteration when
///          @@iterator is missing. Map/Set/WeakMap/WeakSet all pass false —
///          @@iterator must be callable or construction throws "iterable
///          argument is not iterable" (ES2015 §7.4.1 GetIterator; matches
///          V8/SpiderMonkey — there is no array-like fallback in the spec).
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
    coll.prototype = builtin_proto_from_new_target(ctx, proto);

    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (!arg.is_null() && !arg.is_undefined()) {
            // Wrap primitives in a throwaway object whose [[Prototype]] is the
            // matching wrapper prototype, so the @@iterator lookup walks the
            // real prototype chain. This matches group_by_shared's pattern.
            HObject* iterable_obj = null;
            if (arg.is_object() && arg.get_heapptr() != null) {
                iterable_obj = (HObject*)arg.get_heapptr();
            } else {
                HObject*? wrapped = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch err = wrapped) {
                    ctx.result.set_undefined();
                    return;
                }
                iterable_obj = wrapped;
                if (is_symbol_val(arg)) {
                    iterable_obj.prototype = ctx.heap.symbol_proto;
                } else if (arg.is_string()) {
                    (*iterable_obj.extra_ptr()).prim.primitive_value = arg;
                    iterable_obj.prototype = ctx.heap.string_proto;
                } else if (arg.is_boolean()) {
                    iterable_obj.prototype = ctx.heap.bool_proto;
                } else if (arg.is_number() || arg.is_fastint()) {
                    iterable_obj.prototype = ctx.heap.number_proto;
                } else if (arg.is_bigint()) {
                    iterable_obj.prototype = ctx.heap.bigint_proto;
                }
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
            HString* iter_sym = ensure_iterator_symbol(ctx.heap);
            if (iter_sym == null) { ctx.result.set_undefined(); return; }
            TVal iter_fn;
            iter_fn.set_undefined();
            if (try found_iter_fn = iterable_obj.get_prop_proto(iter_sym)) { iter_fn = found_iter_fn; }
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
                uint len = array_get_length(iterable_obj, ctx.heap);
                for (uint i = 0; i < len; i++) {
                    TVal elem = array_get_elem(iterable_obj, i, ctx.heap);
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
                    // Use accessor-aware reads for IteratorResult fields (ES2022 §7.4.4).
                    // get_prop_proto bypasses accessor getters; builtins_generic_get
                    // invokes [[Get]] so a throwing getter is caught.
                    HString* done_key = builtin_intern_string(ctx.heap, "done");
                    TVal done_val;
                    done_val.set_undefined();
                    if (done_key != null) {
                        if (try d = builtins_generic_get(res_obj, done_key, ctx)) { done_val = d; }
                    }
                    if (ctx.should_throw) {
                        // done getter threw — close iterator then propagate.
                        arr_iterator_close_after_throw(ctx, iterator);
                        ctx.result.set_undefined();
                        return;
                    }
                    if (done_val.is_boolean() && done_val.get_boolean()) break;

                    HString* value_key = builtin_intern_string(ctx.heap, "value");
                    TVal val_tv;
                    val_tv.set_undefined();
                    if (value_key != null) {
                        if (try v = builtins_generic_get(res_obj, value_key, ctx)) { val_tv = v; }
                    }
                    if (ctx.should_throw) {
                        // value getter threw — close iterator then propagate (ES2022 §7.4.5).
                        arr_iterator_close_after_throw(ctx, iterator);
                        ctx.result.set_undefined();
                        return;
                    }
                    if (is_pair) {
                        if (val_tv.is_object() && val_tv.get_heapptr() != null) {
                            HObject* pair_obj = (HObject*)val_tv.get_heapptr();
                            // Use accessor-aware property reads (ES2022 §23.1.1.1 step 9h/9j).
                            // array_get_elem is a fast path that bypasses accessor getters;
                            // builtins_generic_get invokes [[Get]] correctly.
                            HString* key0 = ctx.heap.int_to_hstring(0);
                            HString* key1 = ctx.heap.int_to_hstring(1);
                            TVal k; k.set_undefined();
                            TVal v; v.set_undefined();
                            if (key0 != null) {
                                if (try kv = builtins_generic_get(pair_obj, key0, ctx)) { k = kv; }
                            }
                            if (ctx.should_throw) {
                                // Getter for key[0] threw — close iterator then propagate.
                                arr_iterator_close_after_throw(ctx, iterator);
                                ctx.result.set_undefined();
                                return;
                            }
                            if (key1 != null) {
                                if (try vv = builtins_generic_get(pair_obj, key1, ctx)) { v = vv; }
                            }
                            if (ctx.should_throw) {
                                // Getter for key[1] threw — close iterator then propagate.
                                arr_iterator_close_after_throw(ctx, iterator);
                                ctx.result.set_undefined();
                                return;
                            }
                            TVal[2] adder_args = { k, v };
                            TVal coll_tv2; coll_tv2.set_object(coll);
                            ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 2, coll_tv2);
                            if (ctx.heap.has_error) {
                                ctx.should_throw = true;
                                ctx.throw_value = ctx.heap.error_value;
                                ctx.heap.has_error = false;
                                // adder threw — close iterator then propagate.
                                arr_iterator_close_after_throw(ctx, iterator);
                                ctx.result.set_undefined();
                                return;
                            }
                        } else {
                            // pair entry is not an object — ES2022 §23.1.1.1 step 9f requires TypeError.
                            coll_throw(ctx, "Iterator value must be an object");
                            arr_iterator_close_after_throw(ctx, iterator);
                            ctx.result.set_undefined();
                            return;
                        }
                    } else {
                        TVal[1] adder_args = { val_tv };
                        TVal coll_tv2; coll_tv2.set_object(coll);
                        ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 1, coll_tv2);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                            // adder threw — close iterator then propagate.
                            arr_iterator_close_after_throw(ctx, iterator);
                            ctx.result.set_undefined();
                            return;
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
/// unless CanBeHeldWeakly(key) — object or non-registered symbol), false for Map
/// (any key allowed).
/// grow_hwm: true for Map (array_used is a high-water mark that must include slots
/// with undefined keys/values for iteration), false for WeakMap (not iterable).
/// array_used is always widened to include the value slot regardless of
/// grow_hwm — set_array_idx only tracks non-undefined writes, so a value of
/// undefined (a valid Map/WeakMap value) would otherwise leave array_used
/// short of the slot just written, corrupting find_in_array_part's scan
/// bound for every later insert.
fn void coll_set_entry(BuiltinContext* ctx, HObject* coll, uint stride, bool require_object_key,
                        char[] invalid_key_msg, bool grow_hwm) {
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }
    TVal key = ctx.regs[ctx.base_reg];
    if (require_object_key && !can_be_held_weakly(ctx.heap, key)) {
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
        if (coll.array_used <= cnt + 1) {
            coll.array_used = (uint)(cnt + 2);
        }
    }
    ctx.result.set_object(coll);
}

/// CanonicalizeKeyedCollectionKey (ES2025 §24.1.1.3): -0 -> +0, otherwise unchanged.
fn TVal canonicalize_keyed_collection_key(TVal key) {
    if (key.is_number() && key.get_number() == 0.0) {
        TVal out; out.set_fastint(0);
        return out;
    }
    if (key.is_fastint() && key.get_fastint() == 0) {
        TVal out; out.set_fastint(0);
        return out;
    }
    return key;
}

/// Shared body for Map.prototype.getOrInsert / WeakMap.prototype.getOrInsert
/// (ES2025 §24.1.3.9 / §24.3.3.6). require_weak_key: true for WeakMap (throws
/// unless CanBeHeldWeakly(key)), false for Map. grow_hwm: see coll_set_entry.
fn void coll_get_or_insert(BuiltinContext* ctx, HObject* coll, bool require_weak_key,
                            char[] invalid_key_msg, bool grow_hwm) {
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }
    TVal key = ctx.regs[ctx.base_reg];
    if (require_weak_key && !can_be_held_weakly(ctx.heap, key)) {
        builtin_throw(ctx, ctx.heap.type_err_proto, invalid_key_msg);
        return;
    }
    key = canonicalize_keyed_collection_key(key);
    TVal value = ctx.regs[ctx.base_reg + 1];  // undefined if not provided

    int found = find_in_array_part(coll, key, 2);
    if (found >= 0) {
        *ctx.result = coll.array_part()[(uint)found + 1];
        return;
    }
    uint cnt = coll.array_used;
    coll.set_array_idx(cnt, key);
    coll.set_array_idx(cnt + 1, value);
    if (coll.array_used <= cnt + 1) {
        coll.array_used = (uint)(cnt + 2);
    }
    *ctx.result = value;
}

/// Shared body for Map.prototype.getOrInsertComputed / WeakMap.prototype.
/// getOrInsertComputed (ES2025 §24.1.3.10 / §24.3.3.7). callbackfn is called
/// with `key` as its sole argument and `undefined` as `this`, ONLY when the
/// key was absent beforehand. After the callback returns, the map is
/// re-searched for `key`: if present (whether because the callback itself
/// inserted it, or it was already there), its value is overwritten with the
/// callback's result and that value is returned; otherwise a new entry is
/// appended. A throwing callback inserts nothing and propagates the throw.
fn void coll_get_or_insert_computed(BuiltinContext* ctx, HObject* coll, bool require_weak_key,
                                     char[] invalid_key_msg, char[] not_callable_msg, bool grow_hwm) {
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }
    TVal key = ctx.regs[ctx.base_reg];
    if (require_weak_key && !can_be_held_weakly(ctx.heap, key)) {
        builtin_throw(ctx, ctx.heap.type_err_proto, invalid_key_msg);
        return;
    }
    key = canonicalize_keyed_collection_key(key);

    TVal callback;
    if (ctx.argc >= 2) { callback = ctx.regs[ctx.base_reg + 1]; } else { callback.set_undefined(); }
    bool callback_callable = callback.is_lightfunc() ||
        (callback.is_object() && callback.get_heapptr() != null &&
         ((HObject*)callback.get_heapptr()).is_callable());
    if (!callback_callable) {
        builtin_throw(ctx, ctx.heap.type_err_proto, not_callable_msg);
        return;
    }

    int found = find_in_array_part(coll, key, 2);
    if (found >= 0) {
        *ctx.result = coll.array_part()[(uint)found + 1];
        return;
    }

    if (ctx.heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return; }
    TVal[1] cb_args;
    cb_args[0] = key;
    TVal undef_this; undef_this.set_undefined();
    TVal value = ctx.heap.call_fn(ctx.vm, callback, &cb_args[0], 1, undef_this);
    if (ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        ctx.result.set_undefined();
        return;
    }

    // Re-search: the callback may have inserted `key` itself (overwrites-
    // mutation-from-callbackfn test262 semantics) or another concurrent
    // mutation may have added it.
    int found2 = find_in_array_part(coll, key, 2);
    if (found2 >= 0) {
        TVal* v_slot = &coll.array_part()[(uint)found2 + 1];
        if (grow_hwm && v_slot.is_string()) ctx.heap.decref_tval(v_slot);
        *v_slot = value;
    } else {
        uint cnt = coll.array_used;
        coll.set_array_idx(cnt, key);
        coll.set_array_idx(cnt + 1, value);
        if (coll.array_used <= cnt + 1) {
            coll.array_used = (uint)(cnt + 2);
        }
    }
    *ctx.result = value;
}

/// Shared body for Set.prototype.add / WeakSet.prototype.add (ES6 §23.2.3.1 / §23.4.3.1).
/// require_object_value: true for WeakSet (throws "Invalid value used in weak set"
/// unless CanBeHeldWeakly(value) — object or non-registered symbol), false for Set
/// (any value allowed).
/// grow_hwm: true for Set (array_used high-water mark must include undefined slots
/// for iteration), false for WeakSet (not iterable).
fn void coll_add_value(BuiltinContext* ctx, HObject* coll, bool require_object_value,
                        char[] invalid_value_msg, bool grow_hwm) {
    TVal value; value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];
    if (require_object_value && !can_be_held_weakly(ctx.heap, value)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, invalid_value_msg);
        ctx.result.set_undefined();
        return;
    }
    int found = find_in_array_part(coll, value, 1);
    if (found < 0) {
        uint idx = coll.array_used;
        coll.set_array_idx(idx, value);
        if (grow_hwm && coll.array_used <= idx) {
            coll.array_used = (uint)(idx + 1);
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
        coll.array_used = (uint)(cnt - stride);
    }
    ctx.result.set_boolean(true);
}

// ============================================================================
// GroupBy shared driver (ES2024 §23.1.2.1 Object.groupBy / §24.1.2.1 Map.groupBy)
// ============================================================================

/// Append `value` to the group array for `key` in `groups_obj`, creating a new
/// single-element Array the first time `key` is seen. `groups_obj` already has
/// its final [[Prototype]] set by the caller (null for Object.groupBy).
fn bool group_by_append_object(BuiltinContext* ctx, HObject* groups_obj, HString* key, TVal value) {
    HObject* group_arr = null;
    PropValue*? existing = groups_obj.find_prop(key);
    if (try ex = existing) {
        if (ex.is_object() && ex.get_heapptr() != null) {
            group_arr = (HObject*)ex.get_heapptr();
        }
    }
    if (group_arr == null) {
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = arr_raw) return false;
        group_arr = arr_raw;
        group_arr.prototype = ctx.heap.array_proto;
        TVal arr_tv; arr_tv.set_object(group_arr);
        groups_obj.put_prop(key, arr_tv, hobject::PROP_FLAGS_WEC);
    }
    uint idx = *group_arr.array_len_ptr();
    group_arr.set_array_idx(idx, value);
    array_set_length(group_arr, idx + 1, ctx.heap);
    return true;
}

/// Append `value` to the group array for `key` (SameValueZero) in `map`,
/// creating a new single-element Array the first time `key` is seen.
fn bool group_by_append_map(BuiltinContext* ctx, HObject* map, TVal key, TVal value) {
    int found = map_find_key(map, key);
    HObject* group_arr = null;
    if (found >= 0) {
        TVal existing = map.array_part()[(uint)found + 1];
        if (existing.is_object() && existing.get_heapptr() != null) {
            group_arr = (HObject*)existing.get_heapptr();
        }
    }
    if (group_arr == null) {
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = arr_raw) return false;
        group_arr = arr_raw;
        group_arr.prototype = ctx.heap.array_proto;
        TVal arr_tv; arr_tv.set_object(group_arr);
        if (found >= 0) {
            TVal* v_slot = &map.array_part()[(uint)found + 1];
            *v_slot = arr_tv;
        } else {
            uint cnt = map.array_used;
            map.set_array_idx(cnt, key);
            map.set_array_idx(cnt + 1, arr_tv);
            if (map.array_used <= cnt + 1) {
                map.array_used = (uint)(cnt + 2);
            }
        }
    }
    uint idx = *group_arr.array_len_ptr();
    group_arr.set_array_idx(idx, value);
    array_set_length(group_arr, idx + 1, ctx.heap);
    return true;
}

/// GroupBy ( items, callbackfn, coercion ) — ES2024 §23.1.2.1.
/// `into_map`: false stores groups as data properties of a null-prototype
/// object (Object.groupBy), true stores groups keyed by SameValueZero in a
/// fresh Map (Map.groupBy, key -0 normalized to +0 per CanonicalizeKeyedCollectionKey).
/// `result` receives the produced Object/Map on success, or null on failure —
/// callers should check ctx.should_throw afterward to distinguish an in-band
/// TypeError from ctx.result being validly unset.
fn HObject* group_by_shared(BuiltinContext* ctx, bool into_map) {
    Heap* heap = ctx.heap;
    if (ctx.argc < 2) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "callback function is not callable");
        return null;
    }
    TVal items = ctx.regs[ctx.base_reg];
    TVal callback = ctx.regs[ctx.base_reg + 1];
    bool callback_callable = callback.is_lightfunc() ||
        (callback.is_object() && callback.get_heapptr() != null &&
         ((HObject*)callback.get_heapptr()).is_callable());
    if (!callback_callable) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "callback function is not callable");
        return null;
    }
    if (heap.call_fn == null || ctx.vm == null) return null;

    // GetIterator(items) — must be an object/primitive with a callable
    // @@iterator; undefined/null @@iterator is a TypeError (no fallback).
    // Primitives are wrapped in a throwaway object whose [[Prototype]] is the
    // matching wrapper prototype, so the @@iterator lookup below walks the
    // real prototype chain (must set items_obj.prototype directly — a named
    // "prototype" data property is not consulted by get_prop_or_accessor_proto).
    HObject* items_obj = null;
    if (items.is_object() && items.get_heapptr() != null) {
        items_obj = (HObject*)items.get_heapptr();
    } else if (!items.is_undefined() && !items.is_null()) {
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try w = wrapped) {
            items_obj = w;
            if (is_symbol_val(items)) {
                items_obj.prototype = heap.symbol_proto;
            } else if (items.is_string()) {
                (*items_obj.extra_ptr()).prim.primitive_value = items;
                items_obj.prototype = heap.string_proto;
            } else if (items.is_boolean()) {
                items_obj.prototype = heap.bool_proto;
            } else if (items.is_number() || items.is_fastint()) {
                items_obj.prototype = heap.number_proto;
            } else if (items.is_bigint()) {
                items_obj.prototype = heap.bigint_proto;
            }
        }
    } else {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "items is null or undefined");
        return null;
    }

    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym == null) return null;
    TVal? iter_method_opt = builtins_generic_get(items_obj, iter_sym, ctx);
    if (ctx.should_throw) return null;
    TVal iter_method;
    if (try im = iter_method_opt) { iter_method = im; } else { iter_method.set_undefined(); }
    if (iter_method.is_undefined() || iter_method.is_null()) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "items is not iterable");
        return null;
    }
    bool iter_method_callable = iter_method.is_lightfunc() ||
        (iter_method.is_object() && iter_method.get_heapptr() != null &&
         ((HObject*)iter_method.get_heapptr()).is_callable());
    if (!iter_method_callable) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "Symbol.iterator method is not callable");
        return null;
    }

    TVal iterator = heap.call_fn(ctx.vm, iter_method, null, 0, items);
    if (heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = heap.error_value;
        heap.has_error = false;
        return null;
    }
    if (!iterator.is_object() || iterator.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "Result of the Symbol.iterator method is not an object");
        return null;
    }
    HObject* iter_obj = (HObject*)iterator.get_heapptr();

    // Result container: a null-prototype ordinary object (Object.groupBy) or
    // a freshly constructed Map (Map.groupBy) — created before iteration.
    HObject* groups;
    if (into_map) {
        HObject*? map_raw = heap.alloc_object(hobject::ObjClass.MAP);
        if (catch err = map_raw) return null;
        groups = map_raw;
        groups.prototype = heap.map_proto;
    } else {
        HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = obj_raw) return null;
        groups = obj_raw;
        groups.prototype = null;
    }

    HString* next_key = builtin_intern_string(heap, "next");
    HString* done_key = builtin_intern_string(heap, "done");
    HString* value_key = builtin_intern_string(heap, "value");

    ulong k = 0;
    while (true) {
        TVal? next_method_opt = builtins_generic_get(iter_obj, next_key, ctx);
        if (ctx.should_throw) return null;
        TVal next_method;
        if (try nm = next_method_opt) { next_method = nm; } else { break; }
        bool next_callable = next_method.is_lightfunc() ||
            (next_method.is_object() && next_method.get_heapptr() != null &&
             ((HObject*)next_method.get_heapptr()).is_callable());
        if (!next_callable) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto, "iterator.next is not callable");
            return null;
        }

        TVal step_result = heap.call_fn(ctx.vm, next_method, null, 0, iterator);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            return null;
        }
        if (!step_result.is_object() || step_result.get_heapptr() == null) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto, "Iterator result is not an object");
            return null;
        }
        HObject* result_obj = (HObject*)step_result.get_heapptr();

        TVal? done_opt = builtins_generic_get(result_obj, done_key, ctx);
        if (ctx.should_throw) return null;
        bool done = false;
        if (try dv = done_opt) { done = builtin_to_boolean(&dv); }
        if (done) break;

        TVal? value_opt = builtins_generic_get(result_obj, value_key, ctx);
        if (ctx.should_throw) {
            arr_iterator_close_after_throw(ctx, iterator);
            return null;
        }
        TVal next_value;
        if (try vv = value_opt) { next_value = vv; } else { next_value.set_undefined(); }

        // ES2024 §23.1.2.1 GroupBy step 6.e: 𝔽(k) as the index arg — beyond
        // 2^53-1 keys the spec has already thrown RangeError (step 6.d), which
        // cannot occur in practice (would require exhausting all safe integers).
        TVal[2] cb_args;
        cb_args[0] = next_value;
        TVal k_tv;
        if (k <= (ulong)types::FASTINT_MAX) { k_tv.set_fastint((long)k); } else { k_tv.set_number((double)k); }
        cb_args[1] = k_tv;
        TVal undef_this; undef_this.set_undefined();
        TVal key_result = heap.call_fn(ctx.vm, callback, &cb_args[0], 2, undef_this);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            arr_iterator_close_after_throw(ctx, iterator);
            return null;
        }

        if (into_map) {
            // CanonicalizeKeyedCollectionKey: -0 -> +0.
            TVal norm_key = key_result;
            if (norm_key.is_number() && norm_key.get_number() == 0.0) {
                norm_key.set_fastint(0);
            } else if (norm_key.is_fastint() && norm_key.get_fastint() == 0) {
                norm_key.set_fastint(0);
            }
            if (!group_by_append_map(ctx, groups, norm_key, next_value)) {
                arr_iterator_close_after_throw(ctx, iterator);
                return null;
            }
        } else {
            HString* prop_key = builtin_to_property_key_vm(ctx, &key_result);
            if (ctx.should_throw) {
                arr_iterator_close_after_throw(ctx, iterator);
                return null;
            }
            if (prop_key == null) {
                arr_iterator_close_after_throw(ctx, iterator);
                return null;
            }
            if (!group_by_append_object(ctx, groups, prop_key, next_value)) {
                arr_iterator_close_after_throw(ctx, iterator);
                return null;
            }
        }

        k++;
    }

    return groups;
}

// ============================================================================
// ToString helper (ES3 ToString for primitive types)
// ============================================================================

/// ToString(Number) per ES2015 §7.1.12.1 — shortest round-trip decimal via
/// QuickJS js_dtoa (FREE mode), spec exponent format (1e+21, 1e-7).
fn HString* builtin_number_to_hstring(Heap* heap, double d) {
    if (math::is_nan(d)) return (HString*)heap.strs[heap::BuiltinStr.NAN_STR];
    if (math::is_inf(d)) {
        return (d > 0.0)
            ? (HString*)heap.strs[heap::BuiltinStr.POSITIVE_INFINITY]
            : (HString*)heap.strs[heap::BuiltinStr.NEGATIVE_INFINITY];
    }
    // -0 must produce "0"
    if (d == 0.0) return builtin_intern_string(heap, "0");
    // Integers up to 2^53 (every value in this range is exactly representable
    // and is therefore its own shortest round-trip decimal) use plain decimal
    // notation via printf. Above 2^53, adjacent doubles are more than 1 apart,
    // so the exact binary value's decimal expansion (as printf would produce)
    // is no longer necessarily the shortest round-trip String; those go
    // through dtoa's FREE format below to match ES ToString semantics.
    if (d == math::trunc(d) && d > -9007199254740992.0 && d < 9007199254740992.0) {
        char[64] ibuf;
        int ilen = (int)(io::bprintf(&ibuf, "%.0f", d) ?? ibuf[:0]).len;
        if (ilen >= 0 && ilen < 64) {
            return builtin_intern_string(heap, ibuf[:ilen]);
        }
    }
    char[64] buf;
    char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] tmp;
    int len = dtoa_bindings::duktape_js_dtoa(&buf, d, 10, 0,
        dtoa_bindings::JS_DTOA_FORMAT_FREE, &tmp);
    if (len > 0 && len < 64) {
        return builtin_intern_string(heap, buf[:len]);
    }
    // Unreachable for finite doubles; keep a safe fallback.
    int flen = (int)(io::bprintf(&buf, "%.17g", d) ?? buf[:0]).len;
    return builtin_intern_string(heap, buf[:flen]);
}

fn HString* builtin_to_string(Heap* heap, TVal* val) {
    switch (val.get_tag()) {
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            // Symbols need special handling: ToString(symbol) = "Symbol(description)"
            if (s != null && s.is_symbol()) {
                // Build "Symbol(description)" string
                char[] desc = symbol_description(s);
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
            return builtin_number_to_hstring(heap, val.get_number());
        }
        case FASTINT: {
            char[64] buf;
            int len = (int)(io::bprintf(&buf, "%d", (long)val.get_fastint()) ?? buf[:0]).len;
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
        case BIGINT: {
            char[48] bbuf;
            char[] bs = hbigint::int128_to_decimal(val.get_bigint(), bbuf[..]);
            return builtin_intern_string(heap, bs);
        }
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
/// ToIntegerOrInfinity first calls ToNumber, which throws TypeError for
/// Symbol and BigInt arguments (ES2022 §7.1.4) — checked before the object
/// path since Symbols/BigInts are not objects.
fn double builtin_to_integer_vm(BuiltinContext* ctx, TVal* val) {
    if (val.is_bigint()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert a BigInt value to a number");
        return 0.0 / 0.0;
    }
    if (val.is_string()) {
        HString* hs = (HString*)val.get_heapptr();
        if (hs != null && hs.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert a Symbol value to a number");
            return 0.0 / 0.0;
        }
    }
    if (val.is_object() && ctx.vm != null) {
        Vm* vm_ptr = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(vm_ptr, val, 2);  // hint "number"
        if (vm_ptr.throw_pending) {
            vm_ptr.throw_pending = false;
            ctx.should_throw = true;
            ctx.throw_value = vm_ptr.throw_value;
            return 0.0 / 0.0;
        }
        if (!prim.is_object()) {
            if (prim.is_string()) {
                HString* ps = (HString*)prim.get_heapptr();
                if (ps != null && ps.is_symbol()) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert a Symbol value to a number");
                    return 0.0 / 0.0;
                }
            }
            // ToNumber(BigInt) throws TypeError (ES2020 §7.1.4) — e.g. a wrapper
            // or @@toPrimitive that yields a BigInt reaches here.
            if (prim.is_bigint()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert a BigInt value to a number");
                return 0.0 / 0.0;
            }
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

/// Full IsRegExp check per ES2015 §7.2.8 with VM access for abrupt completions.
///
/// Returns: 1 = is RegExp, 0 = is not RegExp, -1 = abrupt completion (throw pending).
/// The algorithm:
///  1. If Type(argument) is not Object, return false.
///  2. Let isRegExp be Get(argument, @@match).
///  3. ReturnIfAbrupt(isRegExp).
///  4. If isRegExp is not undefined, return ToBoolean(isRegExp).
///  5. If argument has [[RegExpMatcher]] internal slot, return true.
///  6. Return false.
fn int is_regexp_check_vm(BuiltinContext* ctx, TVal* val) {
    // Step 1: If Type is not Object, return false.
    if (!val.is_object() || val.get_heapptr() == null) return 0;

    // Step 2: Let isRegExp = Get(argument, @@match).
    HObject* obj = (HObject*)val.get_heapptr();
    HString* match_sym = ensure_match_symbol(ctx.heap);
    if (match_sym == null) { ctx.result.set_undefined(); return 0; }
    TVal? match_opt = builtins_generic_get(obj, match_sym, ctx);
    if (ctx.should_throw) return -1;

    // Step 3-4: If @@match is not undefined, return ToBoolean(@@match).
    if (try match_val = match_opt) {
        if (!match_val.is_undefined()) {
            return match_val.is_boolean() ? (match_val.get_boolean() ? 1 : 0) : 1;
        }
    }

    // Step 5: If argument has [[RegExpMatcher]] internal slot, return true.
    if (obj.get_class() == hobject::ObjClass.REGEXP && (*obj.extra_ptr()).regexp.regexp_data != null) {
        return 1;
    }

    // Step 6: Return false.
    return 0;
}

fn double builtin_to_number_getdouble(BuiltinContext* ctx, TVal* val) {
    if (val.is_fastint()) return (double)val.get_fastint();
    if (val.is_number()) return val.get_number();
    // ToNumber(BigInt) throws TypeError (ES2020 §7.1.4).
    if (val.is_bigint()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert a BigInt value to a number");
        return 0.0 / 0.0;
    }
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
    // ToNumber on a BigInt value must throw TypeError (ES2020 §7.1.4).
    if (val.is_bigint()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert a BigInt value to a number");
        return 0.0 / 0.0;
    }
    // ToNumber on a Symbol value must throw TypeError (ES2022 §7.1.3).
    if (val.is_string()) {
        HString* hs = (HString*)val.get_heapptr();
        if (hs != null && hs.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert a Symbol value to a number");
            return 0.0 / 0.0;
        }
    }
    if (val.is_object() && ctx.vm != null) {
        Vm* vm_ptr = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(vm_ptr, val, 2);  // hint "number"
        if (vm_ptr.throw_pending) {
            // Propagate the thrown error (TypeError from to_primitive_value).
            ctx.should_throw = true;
            ctx.throw_value = vm_ptr.throw_value;
            vm_ptr.throw_pending = false;  // Clear so stale state doesn't re-fire.
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
/// Throws TypeError if the value is a Symbol (ToString(symbol) must throw per spec).
fn HString* builtin_to_string_vm(BuiltinContext* ctx, TVal* val) {
    if (val.is_string()) {
        // Symbols cannot be converted to string — ToString(symbol) must throw TypeError.
        HString* s = (HString*)val.get_heapptr();
        if (s != null && s.is_symbol()) {
            arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
            return null;
        }
        return s;
    }
    if (val.is_object() && ctx.vm != null) {
        Vm* vm_ptr = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(vm_ptr, val, 1);  // hint "string"
        if (vm_ptr.throw_pending) {
            // Propagate to BuiltinContext so callers using `if (ctx.should_throw) return;`
            // bail, and the dispatcher turns the throw into a JS exception.
            // Clear throw_pending so stale state does not re-fire after the
            // dispatcher re-throws via vm_throw_value.
            ctx.should_throw = true;
            ctx.throw_value = vm_ptr.throw_value;
            vm_ptr.throw_pending = false;
            return null;
        }
        // ToString(Symbol) must throw TypeError even when returned from ToPrimitive.
        if (prim.is_string()) {
            HString* ps = (HString*)prim.get_heapptr();
            if (ps != null && ps.is_symbol()) {
                arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
                return null;
            }
            return ps;
        }
        if (prim.is_object()) return null;  // ToPrimitive returned object
        return builtin_to_string(ctx.heap, &prim);
    }
    return builtin_to_string(ctx.heap, val);
}

/// ToPropertyKey (ES §7.1.19): like ToString but a Symbol is a valid property
/// key and passes through unchanged (Symbols are HString with is_symbol()).
/// Use this — not builtin_to_string_vm — anywhere a value is being coerced to a
/// property key (defineProperty, hasOwn, getOwnPropertyDescriptor, in, etc.),
/// since ToString(Symbol) throws TypeError but a Symbol key must not.
fn HString* builtin_to_property_key_vm(BuiltinContext* ctx, TVal* val) {
    if (val.is_string()) {
        // Covers both plain strings and Symbols (is_symbol HStrings).
        return (HString*)val.get_heapptr();
    }
    // Object key: ToPrimitive(key, "string"); if that yields a Symbol, the
    // Symbol IS the property key (ToPropertyKey, §7.1.19) — do not ToString it.
    if (val.is_object() && ctx.vm != null) {
        Vm* vm_ptr = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(vm_ptr, val, 1);  // hint "string"
        if (vm_ptr.throw_pending) {
            ctx.should_throw = true;
            ctx.throw_value = vm_ptr.throw_value;
            vm_ptr.throw_pending = false;
            return null;
        }
        if (prim.is_string()) {
            // Plain string or Symbol — both are valid keys, pass through.
            return (HString*)prim.get_heapptr();
        }
        if (prim.is_object()) return null;
        return builtin_to_string(ctx.heap, &prim);
    }
    return builtin_to_string_vm(ctx, val);
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
        case Builtin.PRINT.ordinal:  return { "print", 1 };
        case Builtin.CONSOLE_LOG.ordinal:  return { "log", 1 };
        case Builtin.CONSOLE_INFO.ordinal:  return { "info", 1 };
        case Builtin.CONSOLE_DEBUG.ordinal: return { "debug", 1 };
        case Builtin.CONSOLE_TRACE.ordinal: return { "trace", 1 };
        case Builtin.CONSOLE_WARN.ordinal:  return { "warn", 1 };
        case Builtin.CONSOLE_ERROR.ordinal: return { "error", 1 };
        case Builtin.CONSOLE_DIR.ordinal:   return { "dir", 1 };
        case Builtin.CONSOLE_ASSERT.ordinal: return { "assert", 1 };
        case Builtin.PARSE_INT.ordinal:  return { "parseInt", 2 };
        case Builtin.PARSE_FLOAT.ordinal:  return { "parseFloat", 1 };
        case Builtin.IS_NAN.ordinal:  return { "isNaN", 1 };
        case Builtin.IS_FINITE.ordinal:  return { "isFinite", 1 };
        case Builtin.ERROR.ordinal:  return { "Error", 1 };
        case Builtin.TYPE_ERROR.ordinal:  return { "TypeError", 1 };
        case Builtin.RANGE_ERROR.ordinal:  return { "RangeError", 1 };
        case Builtin.REFERENCE_ERROR.ordinal:  return { "ReferenceError", 1 };
        case Builtin.SYNTAX_ERROR.ordinal: return { "SyntaxError", 1 };
        case Builtin.EVAL_ERROR.ordinal: return { "EvalError", 1 };
        case Builtin.ERROR_PROTO_TOSTRING.ordinal: return { "toString", 0 };
        case Builtin.BOOLEAN.ordinal: return { "Boolean", 1 };
        case Builtin.BOOLEAN_PROTO_TOSTRING.ordinal: return { "toString", 0 };
        case Builtin.BOOLEAN_PROTO_VALUEOF.ordinal: return { "valueOf", 0 };
        case Builtin.STRING.ordinal: return { "String", 1 };
        case Builtin.STRING_PROTO_TOSTRING.ordinal: return { "toString", 0 };
        case Builtin.STRING_PROTO_VALUEOF.ordinal: return { "valueOf", 0 };
        case Builtin.NUMBER.ordinal: return { "Number", 1 };
        case Builtin.NUMBER_PROTO_TOSTRING.ordinal: return { "toString", 0 };
        case Builtin.NUMBER_PROTO_VALUEOF.ordinal: return { "valueOf", 0 };
        case Builtin.OBJECT.ordinal: return { "Object", 1 };
        case Builtin.OBJECT_PROTO_TOSTRING.ordinal: return { "toString", 0 };
        case Builtin.OBJECT_PROTO_VALUEOF.ordinal: return { "valueOf", 0 };
        case Builtin.OBJECT_PROTO___PROTO___GETTER.ordinal: return { "get __proto__", 0 };
        case Builtin.OBJECT_PROTO___PROTO___SETTER.ordinal: return { "set __proto__", 1 };
        case Builtin.ARRAY.ordinal: return { "Array", 0 };
        case Builtin.MATH_ABS.ordinal: return { "abs", 1 };
        case Builtin.MATH_FLOOR.ordinal: return { "floor", 1 };
        case Builtin.MATH_CEIL.ordinal: return { "ceil", 1 };
        case Builtin.MATH_ROUND.ordinal: return { "round", 1 };
        case Builtin.MATH_MAX.ordinal: return { "max", 2 };
        case Builtin.MATH_MIN.ordinal: return { "min", 2 };
        case Builtin.MATH_POW.ordinal: return { "pow", 2 };
        case Builtin.MATH_SQRT.ordinal: return { "sqrt", 1 };
        case Builtin.MATH_EXP.ordinal: return { "exp", 1 };
        case Builtin.MATH_LOG.ordinal: return { "log", 1 };
        case Builtin.MATH_SIN.ordinal: return { "sin", 1 };
        case Builtin.MATH_COS.ordinal: return { "cos", 1 };
        case Builtin.MATH_TAN.ordinal: return { "tan", 1 };
        case Builtin.MATH_RANDOM.ordinal: return { "random", 0 };
        case Builtin.STRING_PROTO_CHARAT.ordinal: return { "charAt", 1 };
        case Builtin.STRING_PROTO_CHARCODEAT.ordinal: return { "charCodeAt", 1 };
        case Builtin.STRING_PROTO_INDEXOF.ordinal: return { "indexOf", 1 };
        case Builtin.STRING_PROTO_SLICE.ordinal: return { "slice", 2 };
        case Builtin.STRING_PROTO_SUBSTRING.ordinal: return { "substring", 2 };
        case Builtin.STRING_PROTO_SUBSTR.ordinal: return { "substr", 2 };
        case Builtin.STRING_PROTO_TOUPPERCASE.ordinal: return { "toUpperCase", 0 };
        case Builtin.STRING_PROTO_TOLOWERCASE.ordinal: return { "toLowerCase", 0 };
        case Builtin.STRING_PROTO_TRIM.ordinal: return { "trim", 0 };
        case Builtin.STRING_PROTO_SPLIT.ordinal: return { "split", 2 };
        case Builtin.STRING_PROTO_CONCAT.ordinal: return { "concat", 1 };
        case Builtin.STRING_PROTO_REPLACE.ordinal: return { "replace", 2 };
        case Builtin.ARRAY_PROTO_TOSTRING.ordinal: return { "toString", 0 };
        case Builtin.ARRAY_PROTO_JOIN.ordinal: return { "join", 1 };
        case Builtin.ARRAY_PROTO_POP.ordinal: return { "pop", 0 };
        case Builtin.ARRAY_PROTO_PUSH.ordinal: return { "push", 1 };
        case Builtin.ARRAY_PROTO_REVERSE.ordinal: return { "reverse", 0 };
        case Builtin.ARRAY_PROTO_SHIFT.ordinal: return { "shift", 0 };
        case Builtin.ARRAY_PROTO_SLICE.ordinal: return { "slice", 2 };
        case Builtin.ARRAY_PROTO_SORT.ordinal: return { "sort", 1 };
        case Builtin.ARRAY_PROTO_SPLICE.ordinal: return { "splice", 2 };
        case Builtin.ARRAY_PROTO_UNSHIFT.ordinal: return { "unshift", 1 };
        case Builtin.ARRAY_PROTO_INDEXOF.ordinal: return { "indexOf", 1 };
        case Builtin.ARRAY_PROTO_LASTINDEXOF.ordinal: return { "lastIndexOf", 1 };
        case Builtin.ARRAY_PROTO_CONCAT.ordinal: return { "concat", 1 };
        case Builtin.NUMBER_PROTO_TOFIXED.ordinal: return { "toFixed", 1 };
        case Builtin.NUMBER_PROTO_TOEXPONENTIAL.ordinal: return { "toExponential", 1 };
        case Builtin.NUMBER_PROTO_TOPRECISION.ordinal: return { "toPrecision", 1 };
        case Builtin.FUNCTION_PROTO_CALL.ordinal: return { "call", 1 };
        case Builtin.FUNCTION_PROTO_APPLY.ordinal: return { "apply", 2 };
        case Builtin.FUNCTION_PROTO_BIND.ordinal: return { "bind", 1 };
        case Builtin.BOUND_CALL.ordinal: return { "bind", 1 };
        case Builtin.EVAL.ordinal: return { "eval", 1 };
        case Builtin.JSON_PARSE.ordinal: return { "parse", 2 };
        case Builtin.JSON_STRINGIFY.ordinal: return { "stringify", 3 };
        case Builtin.JSON_RAW_JSON.ordinal: return { "rawJSON", 1 };
        case Builtin.JSON_IS_RAW_JSON.ordinal: return { "isRawJSON", 1 };
        case Builtin.DATE.ordinal: return { "Date", 7 };
        case Builtin.DATE_NOW.ordinal: return { "now", 0 };
        case Builtin.DATE_UTC.ordinal: return { "UTC", 7 };
        case Builtin.DATE_PARSE.ordinal: return { "parse", 1 };
        case Builtin.DATE_PROTO_TOSTRING.ordinal: return { "toString", 0 };
        case Builtin.DATE_PROTO_TOJSON.ordinal: return { "toJSON", 1 };
        case Builtin.DATE_PROTO_VALUEOF.ordinal: return { "valueOf", 0 };
        case Builtin.DATE_PROTO_GETTIME.ordinal: return { "getTime", 0 };
        case Builtin.DATE_PROTO_GETFULLYEAR.ordinal: return { "getFullYear", 0 };
        case Builtin.DATE_PROTO_GETMONTH.ordinal: return { "getMonth", 0 };
        case Builtin.DATE_PROTO_GETDATE.ordinal: return { "getDate", 0 };
        case Builtin.DATE_PROTO_GETDAY.ordinal: return { "getDay", 0 };
        case Builtin.DATE_PROTO_GETHOURS.ordinal: return { "getHours", 0 };
        case Builtin.DATE_PROTO_GETMINUTES.ordinal: return { "getMinutes", 0 };
        case Builtin.DATE_PROTO_GETSECONDS.ordinal: return { "getSeconds", 0 };
        case Builtin.DATE_PROTO_GETMILLISECONDS.ordinal: return { "getMilliseconds", 0 };
        case Builtin.FUNCTION.ordinal: return { "Function", 1 };
        case Builtin.REGEXP.ordinal: return { "RegExp", 2 };
        case Builtin.REGEXP_PROTO_TEST.ordinal: return { "test", 1 };
        case Builtin.REGEXP_PROTO_EXEC.ordinal: return { "exec", 1 };
        case Builtin.REGEXP_PROTO_TOSTRING.ordinal: return { "toString", 0 };
        case Builtin.OBJECT_PROTO_ISPROTOTYPEOF.ordinal: return { "isPrototypeOf", 1 };
        case Builtin.OBJECT_PROTO_HASOWNPROPERTY.ordinal: return { "hasOwnProperty", 1 };
        case Builtin.OBJECT_PROTO_PROPERTYISENUMERABLE.ordinal: return { "propertyIsEnumerable", 1 };
        case Builtin.OBJECT_PROTO_TOLOCALESTRING.ordinal: return { "toLocaleString", 0 };
        case Builtin.MAP.ordinal: return { "Map", 0 };
        case Builtin.MAP_PROTO_SET.ordinal: return { "set", 2 };
        case Builtin.MAP_PROTO_GET.ordinal: return { "get", 1 };
        case Builtin.MAP_PROTO_HAS.ordinal: return { "has", 1 };
        case Builtin.MAP_PROTO_DELETE.ordinal: return { "delete", 1 };
        case Builtin.MAP_PROTO_CLEAR.ordinal: return { "clear", 0 };
        case Builtin.MAP_PROTO_KEYS.ordinal: return { "keys", 0 };
        case Builtin.MAP_PROTO_VALUES.ordinal: return { "values", 0 };
        case Builtin.MAP_PROTO_ENTRIES.ordinal: return { "entries", 0 };
        case Builtin.MAP_PROTO_FOREACH.ordinal: return { "forEach", 1 };
        case Builtin.MAP_PROTO_GETORINSERT.ordinal: return { "getOrInsert", 2 };
        case Builtin.MAP_PROTO_GETORINSERTCOMPUTED.ordinal: return { "getOrInsertComputed", 2 };
        case Builtin.SET.ordinal: return { "Set", 0 };
        case Builtin.SET_PROTO_ADD.ordinal: return { "add", 1 };
        case Builtin.SET_PROTO_HAS.ordinal: return { "has", 1 };
        case Builtin.SET_PROTO_DELETE.ordinal: return { "delete", 1 };
        case Builtin.SET_PROTO_CLEAR.ordinal: return { "clear", 0 };
        case Builtin.SET_PROTO_VALUES.ordinal: return { "values", 0 };
        case Builtin.SET_PROTO_ENTRIES.ordinal: return { "entries", 0 };
        case Builtin.SET_PROTO_FOREACH.ordinal: return { "forEach", 1 };
        case Builtin.WEAKMAP.ordinal: return { "WeakMap", 0 };
        case Builtin.WEAKMAP_PROTO_SET.ordinal: return { "set", 2 };
        case Builtin.WEAKMAP_PROTO_GET.ordinal: return { "get", 1 };
        case Builtin.WEAKMAP_PROTO_HAS.ordinal: return { "has", 1 };
        case Builtin.WEAKMAP_PROTO_DELETE.ordinal: return { "delete", 1 };
        case Builtin.WEAKMAP_PROTO_GETORINSERT.ordinal: return { "getOrInsert", 2 };
        case Builtin.WEAKMAP_PROTO_GETORINSERTCOMPUTED.ordinal: return { "getOrInsertComputed", 2 };
        case Builtin.WEAKSET.ordinal: return { "WeakSet", 0 };
        case Builtin.WEAKSET_PROTO_ADD.ordinal: return { "add", 1 };
        case Builtin.WEAKSET_PROTO_HAS.ordinal: return { "has", 1 };
        case Builtin.WEAKSET_PROTO_DELETE.ordinal: return { "delete", 1 };
        case Builtin.WEAKREF.ordinal: return { "WeakRef", 1 };
        case Builtin.WEAKREF_PROTO_DEREF.ordinal: return { "deref", 0 };
        case Builtin.FINALIZATION_REGISTRY.ordinal: return { "FinalizationRegistry", 1 };
        case Builtin.FINALIZATION_REGISTRY_PROTO_REGISTER.ordinal: return { "register", 2 };
        case Builtin.FINALIZATION_REGISTRY_PROTO_UNREGISTER.ordinal: return { "unregister", 1 };
        case Builtin.SYMBOL.ordinal: return { "Symbol", 1 };
        case Builtin.SYMBOL_FOR.ordinal: return { "for", 1 };
        case Builtin.SYMBOL_KEYFOR.ordinal: return { "keyFor", 1 };
        case Builtin.SYMBOL_PROTO_TOSTRING.ordinal: return { "toString", 0 };
        case Builtin.SYMBOL_PROTO_VALUEOF.ordinal: return { "valueOf", 0 };
        case Builtin.PROMISE.ordinal: return { "Promise", 1 };
        case Builtin.PROMISE_PROTO_THEN.ordinal: return { "then", 2 };
        case Builtin.PROMISE_PROTO_CATCH.ordinal: return { "catch", 1 };
        case Builtin.PROMISE_PROTO_FINALLY.ordinal: return { "finally", 1 };
        case Builtin.PROMISE_RESOLVE.ordinal: return { "resolve", 1 };
        case Builtin.PROMISE_REJECT.ordinal: return { "reject", 1 };
        case Builtin.PROMISE_ALL.ordinal: return { "all", 1 };
        case Builtin.PROMISE_RACE.ordinal: return { "race", 1 };
        case Builtin.GENERATOR_FUNCTION.ordinal: return { "Function", 1 };
        case Builtin.GENERATOR_PROTO_NEXT.ordinal: return { "next", 1 };
        case Builtin.GENERATOR_PROTO_THROW.ordinal: return { "throw", 1 };
        case Builtin.GENERATOR_PROTO_RETURN.ordinal: return { "return", 1 };
        case Builtin.OBJECT_KEYS.ordinal: return { "keys", 1 };
        case Builtin.OBJECT_GETPROTOTYPEOF.ordinal: return { "getPrototypeOf", 1 };
        case Builtin.OBJECT_ISEXTENSIBLE.ordinal: return { "isExtensible", 1 };
        case Builtin.OBJECT_PREVENTEXTENSIONS.ordinal: return { "preventExtensions", 1 };
        case Builtin.OBJECT_GETOWNPROPERTYDESCRIPTOR.ordinal: return { "getOwnPropertyDescriptor", 2 };
        case Builtin.OBJECT_GETOWNPROPERTYDESCRIPTORS.ordinal: return { "getOwnPropertyDescriptors", 1 };
        case Builtin.OBJECT_DEFINEPROPERTY.ordinal: return { "defineProperty", 3 };
        case Builtin.OBJECT_GETOWNPROPERTYNAMES.ordinal: return { "getOwnPropertyNames", 1 };
        case Builtin.OBJECT_DEFINEPROPERTIES.ordinal: return { "defineProperties", 2 };
        case Builtin.OBJECT_CREATE.ordinal: return { "create", 2 };
        case Builtin.OBJECT_SEAL.ordinal: return { "seal", 1 };
        case Builtin.OBJECT_FREEZE.ordinal: return { "freeze", 1 };
        case Builtin.OBJECT_ISSEALED.ordinal: return { "isSealed", 1 };
        case Builtin.OBJECT_ISFROZEN.ordinal: return { "isFrozen", 1 };
        case Builtin.STRING_PROTO_INCLUDES.ordinal: return { "includes", 1 };
        case Builtin.STRING_PROTO_STARTSWITH.ordinal: return { "startsWith", 1 };
        case Builtin.STRING_PROTO_ENDSWITH.ordinal: return { "endsWith", 1 };
        case Builtin.STRING_PROTO_REPEAT.ordinal: return { "repeat", 1 };
        case Builtin.STRING_PROTO_TRIMSTART.ordinal: return { "trimStart", 0 };
        case Builtin.STRING_PROTO_TRIMEND.ordinal: return { "trimEnd", 0 };
        case Builtin.STRING_PROTO_CODEPOINTAT.ordinal: return { "codePointAt", 1 };
        case Builtin.STRING_PROTO_AT.ordinal: return { "at", 1 };
        case Builtin.STRING_PROTO_PADSTART.ordinal: return { "padStart", 1 };
        case Builtin.STRING_PROTO_PADEND.ordinal: return { "padEnd", 1 };
        case Builtin.STRING_PROTO_LASTINDEXOF.ordinal: return { "lastIndexOf", 1 };
        case Builtin.ARRAY_OF.ordinal: return { "of", 0 };
        case Builtin.ARRAY_PROTO_FILL.ordinal: return { "fill", 1 };
        case Builtin.ARRAY_PROTO_FIND.ordinal: return { "find", 1 };
        case Builtin.ARRAY_PROTO_FINDINDEX.ordinal: return { "findIndex", 1 };
        case Builtin.ARRAY_PROTO_INCLUDES.ordinal: return { "includes", 1 };
        case Builtin.ARRAY_PROTO_AT.ordinal: return { "at", 1 };
        case Builtin.ARRAY_PROTO_COPYWITHIN.ordinal: return { "copyWithin", 2 };
        case Builtin.OBJECT_ENTRIES.ordinal: return { "entries", 1 };
        case Builtin.OBJECT_VALUES.ordinal: return { "values", 1 };
        case Builtin.OBJECT_ASSIGN.ordinal: return { "assign", 2 };
        case Builtin.NUMBER_ISNAN.ordinal: return { "isNaN", 1 };
        case Builtin.NUMBER_ISFINITE.ordinal: return { "isFinite", 1 };
        case Builtin.NUMBER_ISINTEGER.ordinal: return { "isInteger", 1 };
        case Builtin.NUMBER_ISSAFEINTEGER.ordinal: return { "isSafeInteger", 1 };
        case Builtin.MATH_ACOS.ordinal: return { "acos", 1 };
        case Builtin.MATH_ASIN.ordinal: return { "asin", 1 };
        case Builtin.MATH_ATAN.ordinal: return { "atan", 1 };
        case Builtin.MATH_ATAN2.ordinal: return { "atan2", 2 };
        case Builtin.MATH_COSH.ordinal: return { "cosh", 1 };
        case Builtin.MATH_SINH.ordinal: return { "sinh", 1 };
        case Builtin.MATH_TANH.ordinal: return { "tanh", 1 };
        case Builtin.MATH_ACOSH.ordinal: return { "acosh", 1 };
        case Builtin.MATH_ASINH.ordinal: return { "asinh", 1 };
        case Builtin.MATH_ATANH.ordinal: return { "atanh", 1 };
        case Builtin.MATH_LOG2.ordinal: return { "log2", 1 };
        case Builtin.MATH_LOG10.ordinal: return { "log10", 1 };
        case Builtin.MATH_LOG1P.ordinal: return { "log1p", 1 };
        case Builtin.MATH_EXPM1.ordinal: return { "expm1", 1 };
        case Builtin.MATH_CBRT.ordinal: return { "cbrt", 1 };
        case Builtin.MATH_HYPOT.ordinal: return { "hypot", 2 };
        case Builtin.MATH_TRUNC.ordinal: return { "trunc", 1 };
        case Builtin.MATH_SIGN.ordinal: return { "sign", 1 };
        case Builtin.MATH_FROUND.ordinal: return { "fround", 1 };
        case Builtin.MATH_CLZ32.ordinal: return { "clz32", 1 };
        case Builtin.MATH_IMUL.ordinal: return { "imul", 2 };
        case Builtin.MATH_SUMPRECISE.ordinal: return { "sumPrecise", 1 };
        case Builtin.ARRAY_ISARRAY.ordinal: return { "isArray", 1 };
        case Builtin.STRING_FROMCHARCODE.ordinal: return { "fromCharCode", 1 };
        case Builtin.OBJECT_IS.ordinal: return { "is", 2 };
        case Builtin.OBJECT_HASOWN.ordinal: return { "hasOwn", 2 };
        case Builtin.OBJECT_SETPROTOTYPEOF.ordinal: return { "setPrototypeOf", 2 };
        case Builtin.ARRAY_PROTO_FLAT.ordinal: return { "flat", 0 };
        case Builtin.ARRAY_PROTO_FLATMAP.ordinal: return { "flatMap", 1 };
        case Builtin.STRING_FROMCODEPOINT.ordinal: return { "fromCodePoint", 1 };
        case Builtin.ENCODE_URI.ordinal: return { "encodeURI", 1 };
        case Builtin.ENCODE_URI_COMPONENT.ordinal: return { "encodeURIComponent", 1 };
        case Builtin.DECODE_URI.ordinal: return { "decodeURI", 1 };
        case Builtin.DECODE_URI_COMPONENT.ordinal: return { "decodeURIComponent", 1 };
        case Builtin.URI_ERROR.ordinal: return { "URIError", 1 };
        case Builtin.ARRAY_PROTO_TOREVERSED.ordinal: return { "toReversed", 0 };
        case Builtin.ARRAY_PROTO_TOSORTED.ordinal: return { "toSorted", 1 };
        case Builtin.ARRAY_PROTO_TOSPLICED.ordinal: return { "toSpliced", 2 };
        case Builtin.ARRAY_PROTO_WITH.ordinal: return { "with", 2 };
        case Builtin.STRING_PROTO_MATCH.ordinal: return { "match", 1 };
        case Builtin.STRING_PROTO_SEARCH.ordinal: return { "search", 1 };
        case Builtin.DATE_PROTO_GETUTCFULLYEAR.ordinal: return { "getUTCFullYear", 0 };
        case Builtin.DATE_PROTO_GETUTCMONTH.ordinal: return { "getUTCMonth", 0 };
        case Builtin.DATE_PROTO_GETUTCDATE.ordinal: return { "getUTCDate", 0 };
        case Builtin.DATE_PROTO_GETUTCDAY.ordinal: return { "getUTCDay", 0 };
        case Builtin.DATE_PROTO_GETUTCHOURS.ordinal: return { "getUTCHours", 0 };
        case Builtin.DATE_PROTO_GETUTCMINUTES.ordinal: return { "getUTCMinutes", 0 };
        case Builtin.DATE_PROTO_GETUTCSECONDS.ordinal: return { "getUTCSeconds", 0 };
        case Builtin.DATE_PROTO_GETUTCMILLISECONDS.ordinal: return { "getUTCMilliseconds", 0 };
        case Builtin.DATE_PROTO_SETTIME.ordinal: return { "setTime", 1 };
        case Builtin.DATE_PROTO_SETMILLISECONDS.ordinal: return { "setMilliseconds", 1 };
        case Builtin.DATE_PROTO_SETSECONDS.ordinal: return { "setSeconds", 2 };
        case Builtin.DATE_PROTO_SETMINUTES.ordinal: return { "setMinutes", 3 };
        case Builtin.DATE_PROTO_SETHOURS.ordinal: return { "setHours", 4 };
        case Builtin.DATE_PROTO_SETDATE.ordinal: return { "setDate", 1 };
        case Builtin.DATE_PROTO_SETMONTH.ordinal: return { "setMonth", 2 };
        case Builtin.DATE_PROTO_SETFULLYEAR.ordinal: return { "setFullYear", 3 };
        case Builtin.DATE_PROTO_SETUTCMILLISECONDS.ordinal: return { "setUTCMilliseconds", 1 };
        case Builtin.DATE_PROTO_SETUTCSECONDS.ordinal: return { "setUTCSeconds", 2 };
        case Builtin.DATE_PROTO_SETUTCMINUTES.ordinal: return { "setUTCMinutes", 3 };
        case Builtin.DATE_PROTO_SETUTCHOURS.ordinal: return { "setUTCHours", 4 };
        case Builtin.DATE_PROTO_SETUTCDATE.ordinal: return { "setUTCDate", 1 };
        case Builtin.DATE_PROTO_SETUTCMONTH.ordinal: return { "setUTCMonth", 2 };
        case Builtin.DATE_PROTO_SETUTCFULLYEAR.ordinal: return { "setUTCFullYear", 3 };
        case Builtin.DATE_PROTO_TOISOSTRING.ordinal: return { "toISOString", 0 };
        case Builtin.DATE_PROTO_TOUTCSTRING.ordinal: return { "toUTCString", 0 };
        case Builtin.DATE_PROTO_TOLOCALESTRING.ordinal: return { "toLocaleString", 0 };
        case Builtin.DATE_PROTO_TOLOCALEDATESTRING.ordinal: return { "toLocaleDateString", 0 };
        case Builtin.DATE_PROTO_TOLOCALETIMESTRING.ordinal: return { "toLocaleTimeString", 0 };
        case Builtin.PROMISE_RESOLVE_CALLBACK.ordinal: return { "", 1 };  // Promise resolve callback (no name)
        case Builtin.PROMISE_REJECT_CALLBACK.ordinal: return { "", 1 };  // Promise reject callback (no name)
        case Builtin.DATE_PROTO_TODATESTRING.ordinal: return { "toDateString", 0 };
        case Builtin.DATE_PROTO_TOTIMESTRING.ordinal: return { "toTimeString", 0 };
        case Builtin.STRING_PROTO_REPLACEALL.ordinal: return { "replaceAll", 2 };
        case Builtin.STRING_PROTO_MATCHALL.ordinal: return { "matchAll", 1 };
        case Builtin.STRING_PROTO_NORMALIZE.ordinal: return { "normalize", 0 };
        case Builtin.STRING_PROTO_ISWELLFORMED.ordinal: return { "isWellFormed", 0 };
        case Builtin.STRING_PROTO_TOWELLFORMED.ordinal: return { "toWellFormed", 0 };
        case Builtin.OBJECT_GETOWNPROPERTYSYMBOLS.ordinal: return { "getOwnPropertySymbols", 1 };
        case Builtin.ARRAY_PROTO_FINDLAST.ordinal: return { "findLast", 1 };
        case Builtin.ARRAY_PROTO_FINDLASTINDEX.ordinal: return { "findLastIndex", 1 };
        case Builtin.REFLECT_OWNKEYS.ordinal: return { "ownKeys", 1 };
        case Builtin.PROMISE_ALLSETTLED.ordinal: return { "allSettled", 1 };
        case Builtin.PROMISE_ANY.ordinal: return { "any", 1 };
        case Builtin.AGGREGATE_ERROR.ordinal: return { "AggregateError", 2 };
        case Builtin.ERROR_CAPTURE_STACK_TRACE.ordinal: return { "captureStackTrace", 2 };
        case Builtin.STRING_RAW.ordinal: return { "raw", 1 };
        case Builtin.ARRAY_ITERATOR_NEXT.ordinal: return { "next", 0 };
        case Builtin.STRING_ITERATOR_NEXT.ordinal: return { "next", 0 };
        case Builtin.STRING_PROTO_SYMBOL_ITER.ordinal: return { "[Symbol.iterator]", 0 };
        case Builtin.ARRAY_PROTO_KEYS.ordinal: return { "keys", 0 };
        case Builtin.ARRAY_PROTO_VALUES.ordinal: return { "values", 0 };
        case Builtin.ARRAY_PROTO_ENTRIES.ordinal: return { "entries", 0 };
        case Builtin.ARRAY_FROM.ordinal: return { "from", 1 };
        case Builtin.ARRAY_PROTO_FOREACH.ordinal: return { "forEach", 1 };
        case Builtin.ARRAY_PROTO_MAP.ordinal: return { "map", 1 };
        case Builtin.ARRAY_PROTO_FILTER.ordinal: return { "filter", 1 };
        case Builtin.ARRAY_PROTO_EVERY.ordinal: return { "every", 1 };
        case Builtin.ARRAY_PROTO_SOME.ordinal: return { "some", 1 };
        case Builtin.ARRAY_PROTO_REDUCE.ordinal: return { "reduce", 1 };
        case Builtin.ARRAY_PROTO_REDUCERIGHT.ordinal: return { "reduceRight", 1 };
        case Builtin.STRING_PROTO_TOLOCALELOWERCASE.ordinal: return { "toLocaleLowerCase", 0 };
        case Builtin.STRING_PROTO_TOLOCALEUPPERCASE.ordinal: return { "toLocaleUpperCase", 0 };
        case Builtin.STRING_PROTO_LOCALECOMPARE.ordinal: return { "localeCompare", 1 };
        case Builtin.FUNCTION_PROTO_TOSTRING.ordinal: return { "toString", 0 };
        case Builtin.REGEXP_PROTO_SYMBOL_MATCH.ordinal: return { "[Symbol.match]", 1 };
        case Builtin.REGEXP_PROTO_SYMBOL_SEARCH.ordinal: return { "[Symbol.search]", 1 };
        case Builtin.REGEXP_PROTO_SYMBOL_REPLACE.ordinal: return { "[Symbol.replace]", 2 };
        case Builtin.REGEXP_PROTO_SYMBOL_SPLIT.ordinal: return { "[Symbol.split]", 2 };
        case Builtin.REGEXP_PROTO_SYMBOL_MATCHALL.ordinal: return { "[Symbol.matchAll]", 1 };
        // RegExp string iterator .next()
        case Builtin.REGEXP_STRING_ITERATOR_NEXT.ordinal: return { "next", 0 };
        // ArrayBuffer constructor / statics / prototype
        case Builtin.ARRAYBUFFER.ordinal: return { "ArrayBuffer", 1 };
        case Builtin.ARRAYBUFFER_ISVIEW.ordinal: return { "isView", 1 };
        case Builtin.ARRAYBUFFER_PROTO_SLICE.ordinal: return { "slice", 2 };
        case Builtin.ARRAYBUFFER_PROTO_RESIZE.ordinal: return { "resize", 1 };
        // DataView constructor / prototype
        case Builtin.DATAVIEW.ordinal: return { "DataView", 1 };
        case Builtin.DATAVIEW_GET_INT8.ordinal: return { "getInt8", 1 };
        case Builtin.DATAVIEW_GET_UINT8.ordinal: return { "getUint8", 1 };
        case Builtin.DATAVIEW_GET_INT16.ordinal: return { "getInt16", 1 };
        case Builtin.DATAVIEW_GET_UINT16.ordinal: return { "getUint16", 1 };
        case Builtin.DATAVIEW_GET_INT32.ordinal: return { "getInt32", 1 };
        case Builtin.DATAVIEW_GET_UINT32.ordinal: return { "getUint32", 1 };
        case Builtin.DATAVIEW_GET_FLOAT32.ordinal: return { "getFloat32", 1 };
        case Builtin.DATAVIEW_GET_FLOAT64.ordinal: return { "getFloat64", 1 };
        case Builtin.DATAVIEW_SET_INT8.ordinal: return { "setInt8", 2 };
        case Builtin.DATAVIEW_SET_UINT8.ordinal: return { "setUint8", 2 };
        case Builtin.DATAVIEW_SET_INT16.ordinal: return { "setInt16", 2 };
        case Builtin.DATAVIEW_SET_UINT16.ordinal: return { "setUint16", 2 };
        case Builtin.DATAVIEW_SET_INT32.ordinal: return { "setInt32", 2 };
        case Builtin.DATAVIEW_SET_UINT32.ordinal: return { "setUint32", 2 };
        case Builtin.DATAVIEW_SET_FLOAT32.ordinal: return { "setFloat32", 2 };
        case Builtin.DATAVIEW_SET_FLOAT64.ordinal: return { "setFloat64", 2 };
        case Builtin.MAP_SPECIES_GETTER.ordinal: return { "[Symbol.species]", 0 };
        case Builtin.SET_SPECIES_GETTER.ordinal: return { "[Symbol.species]", 0 };
        case Builtin.DATAVIEW_GET_BIGINT64.ordinal: return { "getBigInt64", 1 };
        case Builtin.DATAVIEW_GET_BIGUINT64.ordinal: return { "getBigUint64", 1 };
        case Builtin.DATAVIEW_SET_BIGINT64.ordinal: return { "setBigInt64", 2 };
        case Builtin.DATAVIEW_SET_BIGUINT64.ordinal: return { "setBigUint64", 2 };
        // %TypedArray%.prototype wave A (plan 049 stage 4)
        case Builtin.TA_PROTO_VALUES.ordinal: return { "values", 0 };
        case Builtin.TA_PROTO_KEYS.ordinal: return { "keys", 0 };
        case Builtin.TA_PROTO_ENTRIES.ordinal: return { "entries", 0 };
        case Builtin.TA_PROTO_SET.ordinal: return { "set", 1 };
        case Builtin.TA_PROTO_SUBARRAY.ordinal: return { "subarray", 2 };
        case Builtin.TA_PROTO_FILL.ordinal: return { "fill", 1 };
        case Builtin.TA_PROTO_COPYWITHIN.ordinal: return { "copyWithin", 2 };
        case Builtin.TA_PROTO_SLICE.ordinal: return { "slice", 2 };
        // %TypedArray%.prototype wave B (plan 049 stage 5)
        case Builtin.TA_PROTO_INDEX_OF.ordinal: return { "indexOf", 1 };
        case Builtin.TA_PROTO_LAST_INDEX_OF.ordinal: return { "lastIndexOf", 1 };
        case Builtin.TA_PROTO_INCLUDES.ordinal: return { "includes", 1 };
        case Builtin.TA_PROTO_JOIN.ordinal: return { "join", 1 };
        case Builtin.TA_PROTO_FOR_EACH.ordinal: return { "forEach", 1 };
        case Builtin.TA_PROTO_EVERY.ordinal: return { "every", 1 };
        case Builtin.TA_PROTO_SOME.ordinal: return { "some", 1 };
        case Builtin.TA_PROTO_REDUCE.ordinal: return { "reduce", 1 };
        case Builtin.TA_PROTO_REDUCE_RIGHT.ordinal: return { "reduceRight", 1 };
        case Builtin.TA_PROTO_MAP.ordinal: return { "map", 1 };
        case Builtin.TA_PROTO_FILTER.ordinal: return { "filter", 1 };
        case Builtin.TA_PROTO_FIND.ordinal: return { "find", 1 };
        case Builtin.TA_PROTO_FIND_INDEX.ordinal: return { "findIndex", 1 };
        case Builtin.TA_PROTO_FIND_LAST.ordinal: return { "findLast", 1 };
        case Builtin.TA_PROTO_FIND_LAST_INDEX.ordinal: return { "findLastIndex", 1 };
        case Builtin.TA_PROTO_REVERSE.ordinal: return { "reverse", 0 };
        case Builtin.TA_PROTO_TO_REVERSED.ordinal: return { "toReversed", 0 };
        case Builtin.TA_PROTO_AT.ordinal: return { "at", 1 };
        case Builtin.TA_PROTO_SORT.ordinal: return { "sort", 1 };
        case Builtin.TA_PROTO_TO_SORTED.ordinal: return { "toSorted", 1 };
        case Builtin.TA_PROTO_WITH.ordinal: return { "with", 2 };
        case Builtin.TA_PROTO_TO_STRING.ordinal: return { "toString", 0 };
        case Builtin.TA_PROTO_TO_LOCALE_STRING.ordinal: return { "toLocaleString", 0 };
        case Builtin.OBJECT_FROMENTRIES.ordinal: return { "fromEntries", 1 };
        case Builtin.OBJECT_GROUPBY.ordinal: return { "groupBy", 2 };
        case Builtin.MAP_GROUPBY.ordinal: return { "groupBy", 2 };
        // %TypedArray% intrinsic statics
        case Builtin.TA_OF.ordinal: return { "of", 0 };
        case Builtin.TA_FROM.ordinal: return { "from", 1 };
        case Builtin.UINT8ARRAY_FROM_BASE64.ordinal: return { "fromBase64", 1 };
        case Builtin.UINT8ARRAY_FROM_HEX.ordinal: return { "fromHex", 1 };
        case Builtin.UINT8ARRAY_PROTO_TO_BASE64.ordinal: return { "toBase64", 0 };
        case Builtin.UINT8ARRAY_PROTO_TO_HEX.ordinal: return { "toHex", 0 };
        case Builtin.UINT8ARRAY_PROTO_SET_FROM_BASE64.ordinal: return { "setFromBase64", 1 };
        case Builtin.UINT8ARRAY_PROTO_SET_FROM_HEX.ordinal: return { "setFromHex", 1 };
        case Builtin.TYPEDARRAY_INTRINSIC.ordinal: return { "TypedArray", 0 };
        case Builtin.FUNCTION_PROTO_HASINSTANCE.ordinal: return { "[Symbol.hasInstance]", 1 };
        case Builtin.DATE_PROTO_TOPRIMITIVE.ordinal: return { "[Symbol.toPrimitive]", 1 };
        // Proxy
        case Builtin.PROXY.ordinal: return { "Proxy", 2 };
        case Builtin.PROXY_REVOCABLE.ordinal: return { "revocable", 2 };
        case Builtin.PROXY_REVOKE.ordinal: return { "", 0 };     // revoker function
        // Reflect
        case Builtin.REFLECT_GET.ordinal: return { "get", 2 };
        case Builtin.REFLECT_SET.ordinal: return { "set", 3 };
        case Builtin.REFLECT_HAS.ordinal: return { "has", 2 };
        case Builtin.REFLECT_DELETE_PROPERTY.ordinal: return { "deleteProperty", 2 };
        case Builtin.REFLECT_GET_OWN_PROPERTY_DESCRIPTOR.ordinal: return { "getOwnPropertyDescriptor", 2 };
        case Builtin.REFLECT_DEFINE_PROPERTY.ordinal: return { "defineProperty", 3 };
        case Builtin.REFLECT_GET_PROTOTYPE_OF.ordinal: return { "getPrototypeOf", 1 };
        case Builtin.REFLECT_SET_PROTOTYPE_OF.ordinal: return { "setPrototypeOf", 2 };
        case Builtin.REFLECT_IS_EXTENSIBLE.ordinal: return { "isExtensible", 1 };
        case Builtin.REFLECT_PREVENT_EXTENSIONS.ordinal: return { "preventExtensions", 1 };
        case Builtin.REFLECT_APPLY.ordinal: return { "apply", 3 };
        case Builtin.REFLECT_CONSTRUCT.ordinal: return { "construct", 2 };
        // BigInt
        case Builtin.BIGINT.ordinal: return { "BigInt", 1 };
        case Builtin.BIGINT_AS_INTN.ordinal: return { "asIntN", 2 };
        case Builtin.BIGINT_AS_UINTN.ordinal: return { "asUintN", 2 };
        case Builtin.BIGINT_PROTO_TOSTRING.ordinal: return { "toString", 0 };
        case Builtin.BIGINT_PROTO_VALUEOF.ordinal: return { "valueOf", 0 };
        // %AsyncFromSyncIteratorPrototype%
        case Builtin.ASYNC_FROM_SYNC_NEXT.ordinal: return { "next", 1 };
        case Builtin.ASYNC_FROM_SYNC_RETURN.ordinal: return { "return", 1 };
        case Builtin.ASYNC_FROM_SYNC_THROW.ordinal: return { "throw", 1 };
        case Builtin.ASYNC_FROM_SYNC_VALUE_UNWRAP.ordinal: return { "", 1 };
        case Builtin.ASYNC_FROM_SYNC_REJECT_FORWARD.ordinal: return { "", 1 };
        // Array.fromAsync + its internal reaction closures
        case Builtin.ARRAY_FROM_ASYNC.ordinal: return { "fromAsync", 1 };
        case Builtin.ARRAY_FROM_ASYNC_STEP_FULFILL.ordinal: return { "", 1 };
        case Builtin.ARRAY_FROM_ASYNC_MAP_FULFILL.ordinal: return { "", 1 };
        case Builtin.ARRAY_FROM_ASYNC_REJECT.ordinal: return { "", 1 };
        case Builtin.PROMISE_WITH_RESOLVERS.ordinal: return { "withResolvers", 0 };
        case Builtin.PROMISE_TRY.ordinal: return { "try", 1 };
        case Builtin.ERROR_ISERROR.ordinal: return { "isError", 1 };
        // Set methods proposal
        case Builtin.SET_PROTO_UNION.ordinal: return { "union", 1 };
        case Builtin.SET_PROTO_INTERSECTION.ordinal: return { "intersection", 1 };
        case Builtin.SET_PROTO_DIFFERENCE.ordinal: return { "difference", 1 };
        case Builtin.SET_PROTO_SYMMETRICDIFFERENCE.ordinal: return { "symmetricDifference", 1 };
        case Builtin.SET_PROTO_ISSUBSETOF.ordinal: return { "isSubsetOf", 1 };
        case Builtin.SET_PROTO_ISSUPERSETOF.ordinal: return { "isSupersetOf", 1 };
        case Builtin.SET_PROTO_ISDISJOINTFROM.ordinal: return { "isDisjointFrom", 1 };
        case Builtin.REGEXP_ESCAPE.ordinal: return { "escape", 1 };
        // Iterator Helpers (ES2025 §27.1)
        case Builtin.ITERATOR_CTOR.ordinal: return { "Iterator", 0 };
        case Builtin.ITERATOR_FROM.ordinal: return { "from", 1 };
        case Builtin.ITERATOR_PROTO_CONSTRUCTOR_GET.ordinal: return { "get constructor", 0 };
        case Builtin.ITERATOR_PROTO_CONSTRUCTOR_SET.ordinal: return { "set constructor", 1 };
        case Builtin.ITERATOR_PROTO_TOSTRINGTAG_GET.ordinal: return { "get [Symbol.toStringTag]", 0 };
        case Builtin.ITERATOR_PROTO_TOSTRINGTAG_SET.ordinal: return { "set [Symbol.toStringTag]", 1 };
        case Builtin.ITERATOR_PROTO_MAP.ordinal: return { "map", 1 };
        case Builtin.ITERATOR_PROTO_FILTER.ordinal: return { "filter", 1 };
        case Builtin.ITERATOR_PROTO_TAKE.ordinal: return { "take", 1 };
        case Builtin.ITERATOR_PROTO_DROP.ordinal: return { "drop", 1 };
        case Builtin.ITERATOR_PROTO_FLATMAP.ordinal: return { "flatMap", 1 };
        case Builtin.ITERATOR_PROTO_REDUCE.ordinal: return { "reduce", 1 };
        case Builtin.ITERATOR_PROTO_TOARRAY.ordinal: return { "toArray", 0 };
        case Builtin.ITERATOR_PROTO_FOREACH.ordinal: return { "forEach", 1 };
        case Builtin.ITERATOR_PROTO_SOME.ordinal: return { "some", 1 };
        case Builtin.ITERATOR_PROTO_EVERY.ordinal: return { "every", 1 };
        case Builtin.ITERATOR_PROTO_FIND.ordinal: return { "find", 1 };
        case Builtin.ITERATOR_CONCAT.ordinal: return { "concat", -1 };
        case Builtin.WRAP_FOR_VALID_ITERATOR_NEXT.ordinal: return { "next", 0 };
        case Builtin.WRAP_FOR_VALID_ITERATOR_RETURN.ordinal: return { "return", 0 };
        case Builtin.ITERATOR_HELPER_NEXT.ordinal: return { "next", 0 };
        case Builtin.ITERATOR_HELPER_RETURN.ordinal: return { "return", 0 };
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
    func_obj.flags.constructable = false;
    func_obj.prototype = heap.function_proto;
    // Set .length from builtin metadata (ES2015 §17: "length" before "name")
    builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_index);
    {
        HString* length_str = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (length_str != null) {
            TVal len_tv;
            len_tv.set_fastint((long)(meta.arity >= 0 ? meta.arity : 0));
            func_obj.put_prop(length_str, len_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    // Set .name (non-writable, non-enumerable, configurable)
    HString* name_prop_key = builtin_intern_string(heap, "name");
    HString* name_val = builtin_intern_string(heap, name);
    if (name_prop_key != null && name_val != null) {
        TVal name_tv;
        name_tv.set_string(name_val);
        func_obj.put_prop(name_prop_key, name_tv, hobject::PROP_FLAGS_NWC);
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
    defer lex.free_arena();
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
    func_obj.flags.constructable = false;
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
    func_obj.flags.constructable = false;
    func_obj.prototype = heap.function_proto;
    // Set .length from builtin metadata (ES2015 §17: "length" before "name")
    builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_index);
    {
        HString* length_str = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (length_str != null) {
            TVal len_tv;
            len_tv.set_fastint((long)(meta.arity >= 0 ? meta.arity : 0));
            func_obj.put_prop(length_str, len_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    // Set .name (non-writable, non-enumerable, configurable)
    HString* name_prop_key = builtin_intern_string(heap, "name");
    HString* name_val = builtin_intern_string(heap, name);
    if (name_prop_key != null && name_val != null) {
        TVal name_tv;
        name_tv.set_string(name_val);
        func_obj.put_prop(name_prop_key, name_tv, hobject::PROP_FLAGS_NWC);
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
    // ES2015 §17: built-in function objects have "length" before "name" in
    // own property insertion order.
    HString* length_key = builtin_intern_string(heap, "length");
    TVal length_tv; length_tv.set_fastint((long)length);
    func_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_hstr = builtin_intern_string(heap, name);
    TVal name_tv; name_tv.set_string(name_hstr);
    func_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
}

/// Set .name on a built-in constructor HObject (when .length is already set).
fn void set_func_ctor_name(HObject* func_obj, Heap* heap, char[] name) {
    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_hstr = builtin_intern_string(heap, name);
    TVal name_tv; name_tv.set_string(name_hstr);
    func_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
}

// ============================================================================
// Live module binding accessor
// ============================================================================
//
// A module namespace export (`import * as ns`, `ns.x`) and a named import
// (`import { x } from './s'`) must both observe the exporting module's
// CURRENT binding value, not a value snapshotted at link/execute time
// (ECMA-262 SS10.4.6 / SS16.2). Both cases are implemented as one native
// accessor getter that closes over the source module's env bindings object
// and the interned binding key, stored as hidden non-enumerable,
// non-writable, non-configurable properties on the getter function object
// (mirroring the Proxy revoker closure pattern in builtins/proxy.c3). The
// getter re-reads env::env_get every call, so it is live by construction.

const char[] MODULE_BINDING_ENV_SLOT = "\xFFmoduleBindingEnv";
const char[] MODULE_BINDING_KEY_SLOT = "\xFFmoduleBindingKey";

/// Throw a ReferenceError "Cannot access '<name>' before initialization"
/// through the builtin should_throw/throw_value channel (mirrors
/// arr_throw_type_error in builtins/array.c3, but with ref_err_proto and
/// an interpolated binding name).
fn void module_binding_throw_tdz(BuiltinContext* ctx, HString* name) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.ref_err_proto;
        char[256] buf;
        int len = (int)(io::bprintf(&buf, "Cannot access '%s' before initialization", (ZString)name.get_cstr()) ?? buf[:0]).len;
        char[] msg = len > 0 && len < 256 ? buf[:len] : buf[:0];
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
}

/// Native getter body: recover (source bindings object, binding key) from
/// hidden slots on the getter function itself and read the live value.
/// Returns undefined if the binding cannot be found. Throws a
/// ReferenceError if the source slot still holds the TDZ sentinel (the
/// exporting module's `let`/`const`/`class` declaration has not yet run) —
/// ECMA-262 SS10.4.6.8 / SS16.2.1.5.5 GetBindingValue for a not-yet-initialized
/// binding.
///
/// A re-export chain (`export { x } from './a'` re-exported again by a
/// third module) means the resolved slot in `bindings` can itself be an
/// accessor property installed by this same mechanism (one live binding
/// pointing at another). Such a slot is unwrapped and its getter invoked
/// via ctx.heap.call_fn, exactly mirroring GETVAR's own accessor-chase —
/// a single non-recursive lookup would otherwise return the boxed
/// getter/setter pair instead of the underlying value.
fn void builtin_module_binding_getter(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    if (ctx.callee_obj == null) return;
    HString* env_slot_key = ctx.heap.str_intern(MODULE_BINDING_ENV_SLOT);
    HString* key_slot_key = ctx.heap.str_intern(MODULE_BINDING_KEY_SLOT);
    if (env_slot_key == null || key_slot_key == null) return;

    int env_idx = ctx.callee_obj.find_prop_idx((void*)env_slot_key);
    int key_idx = ctx.callee_obj.find_prop_idx((void*)key_slot_key);
    if (env_idx < 0 || key_idx < 0) return;

    TVal env_tv = ctx.callee_obj.prop_values()[env_idx];
    TVal key_tv = ctx.callee_obj.prop_values()[key_idx];
    if (!env_tv.is_object() || !key_tv.is_string()) return;

    HObject* bindings = (HObject*)env_tv.get_heapptr();
    HString* key = (HString*)key_tv.get_heapptr();
    int idx = bindings.find_prop_idx((void*)key);
    if (idx < 0) return;

    if (bindings.get_prop_flags((uint)idx).is_accessor) {
        TVal slot = bindings.prop_values()[idx];
        TVal getter = hobject::hobject_access_getter(slot);
        if (!getter.is_object()) return;
        TVal this_tv; this_tv.set_object(bindings);
        *ctx.result = ctx.heap.call_fn(ctx.vm, getter, null, 0, this_tv);
        return;
    }
    TVal raw = bindings.prop_values()[idx];
    if (env::is_tdz_sentinel(&raw)) {
        module_binding_throw_tdz(ctx, key);
        return;
    }
    *ctx.result = raw;
}

/// Build an accessor property VALUE (a boxed getter/setter pair, per
/// hobject_create_accessors) that live-reads `key` from `source_bindings`
/// (a module env's `.bindings` HObject). Callers install it with
/// `put_prop(key, value, accessor_flags)`, setting PropFlags.is_accessor.
/// Returns an undefined TVal on allocation failure (caller should skip the
/// property rather than fail the whole namespace/import).
fn TVal make_module_binding_accessor(Heap* heap, HObject* source_bindings, HString* key) {
    TVal undef_result;
    undef_result.set_undefined();

    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return undef_result;
    HObject* func_obj = func_raw;
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.MODULE_BINDING_GETTER.ordinal;
    func_obj.flags.callable = true;
    func_obj.flags.constructable = false;
    func_obj.prototype = heap.function_proto;

    HString* env_slot_key = heap.str_intern(MODULE_BINDING_ENV_SLOT);
    HString* key_slot_key = heap.str_intern(MODULE_BINDING_KEY_SLOT);
    if (env_slot_key == null || key_slot_key == null) return undef_result;

    TVal env_tv; env_tv.set_object(source_bindings);
    TVal key_tv; key_tv.set_string(key);
    func_obj.put_prop((void*)env_slot_key, env_tv, hobject::PROP_FLAGS_NWC);
    func_obj.put_prop((void*)key_slot_key, key_tv, hobject::PROP_FLAGS_NWC);

    TVal getter_tv;
    getter_tv.set_object(func_obj);
    TVal undef;
    undef.set_undefined();
    return hobject::hobject_create_accessors(heap, getter_tv, undef);
}

// ============================================================================
// Dispatch table
// ============================================================================

// Function-pointer dispatch table — replaces the 278-arm switch with a single
// indirect call. Builtin.LAST.ordinal is one past the highest valid index; the bounds
// check below mirrors the old `default:` arm (set_undefined on the result).
BuiltinFunc[Builtin.LAST.ordinal] builtin_dispatch_table = {
    [Builtin.AGGREGATE_ERROR.ordinal] = &builtin_aggregate_error,
    [Builtin.ARRAY.ordinal] = &builtin_array,
    [Builtin.ARRAY_FROM.ordinal] = &builtin_array_from,
    [Builtin.ARRAY_ISARRAY.ordinal] = &builtin_array_isArray,
    [Builtin.ARRAY_ITERATOR_NEXT.ordinal] = &builtin_array_iterator_next,
    [Builtin.ARRAY_OF.ordinal] = &builtin_array_of,
    [Builtin.ARRAY_PROTO_AT.ordinal] = &builtin_array_proto_at,
    [Builtin.ARRAY_PROTO_CONCAT.ordinal] = &builtin_array_proto_concat,
    [Builtin.ARRAY_PROTO_COPYWITHIN.ordinal] = &builtin_array_proto_copyWithin,
    [Builtin.ARRAY_PROTO_EVERY.ordinal] = &builtin_array_proto_every,
    [Builtin.ARRAY_PROTO_ENTRIES.ordinal] = &builtin_array_proto_entries,
    [Builtin.ARRAY_PROTO_FILL.ordinal] = &builtin_array_proto_fill,
    [Builtin.ARRAY_PROTO_FILTER.ordinal] = &builtin_array_proto_filter,
    [Builtin.ARRAY_PROTO_FIND.ordinal] = &builtin_array_proto_find,
    [Builtin.ARRAY_PROTO_FINDINDEX.ordinal] = &builtin_array_proto_findIndex,
    [Builtin.ARRAY_PROTO_FINDLAST.ordinal] = &builtin_array_proto_findLast,
    [Builtin.ARRAY_PROTO_FINDLASTINDEX.ordinal] = &builtin_array_proto_findLastIndex,
    [Builtin.ARRAY_PROTO_FLAT.ordinal] = &builtin_array_proto_flat,
    [Builtin.ARRAY_PROTO_FLATMAP.ordinal] = &builtin_array_proto_flatMap,
    [Builtin.ARRAY_PROTO_FOREACH.ordinal] = &builtin_array_proto_forEach,
    [Builtin.ARRAY_PROTO_INCLUDES.ordinal] = &builtin_array_proto_includes,
    [Builtin.ARRAY_PROTO_INDEXOF.ordinal] = &builtin_array_proto_indexOf,
    [Builtin.ARRAY_PROTO_JOIN.ordinal] = &builtin_array_proto_join,
    [Builtin.ARRAY_PROTO_KEYS.ordinal] = &builtin_array_proto_keys,
    [Builtin.ARRAY_PROTO_LASTINDEXOF.ordinal] = &builtin_array_proto_lastIndexOf,
    [Builtin.ARRAY_PROTO_MAP.ordinal] = &builtin_array_proto_map,
    [Builtin.ARRAY_PROTO_POP.ordinal] = &builtin_array_proto_pop,
    [Builtin.ARRAY_PROTO_PUSH.ordinal] = &builtin_array_proto_push,
    [Builtin.ARRAY_PROTO_REDUCE.ordinal] = &builtin_array_proto_reduce,
    [Builtin.ARRAY_PROTO_REDUCERIGHT.ordinal] = &builtin_array_proto_reduceRight,
    [Builtin.ARRAY_PROTO_REVERSE.ordinal] = &builtin_array_proto_reverse,
    [Builtin.ARRAY_PROTO_SHIFT.ordinal] = &builtin_array_proto_shift,
    [Builtin.ARRAY_PROTO_SLICE.ordinal] = &builtin_array_proto_slice,
    [Builtin.ARRAY_PROTO_SOME.ordinal] = &builtin_array_proto_some,
    [Builtin.ARRAY_PROTO_SORT.ordinal] = &builtin_array_proto_sort,
    [Builtin.ARRAY_PROTO_SPLICE.ordinal] = &builtin_array_proto_splice,
    [Builtin.ARRAY_PROTO_TOREVERSED.ordinal] = &builtin_array_proto_toReversed,
    [Builtin.ARRAY_PROTO_TOSORTED.ordinal] = &builtin_array_proto_toSorted,
    [Builtin.ARRAY_PROTO_TOSPLICED.ordinal] = &builtin_array_proto_toSpliced,
    [Builtin.ARRAY_PROTO_TOSTRING.ordinal] = &builtin_array_proto_toString,
    [Builtin.ARRAY_PROTO_UNSHIFT.ordinal] = &builtin_array_proto_unshift,
    [Builtin.ARRAY_PROTO_VALUES.ordinal] = &builtin_array_proto_values,
    [Builtin.ARRAY_PROTO_WITH.ordinal] = &builtin_array_proto_with,
    [Builtin.BOOLEAN.ordinal] = &builtin_boolean,
    [Builtin.BOOLEAN_PROTO_TOSTRING.ordinal] = &builtin_boolean_proto_toString,
    [Builtin.BOOLEAN_PROTO_VALUEOF.ordinal] = &builtin_boolean_proto_valueOf,
    [Builtin.BOUND_CALL.ordinal] = &builtin_bound_call,
    [Builtin.CONSOLE_LOG.ordinal] = &builtin_console_log,
    [Builtin.CONSOLE_INFO.ordinal] = &builtin_console_info,
    [Builtin.CONSOLE_DEBUG.ordinal] = &builtin_console_debug,
    [Builtin.CONSOLE_TRACE.ordinal] = &builtin_console_trace,
    [Builtin.CONSOLE_WARN.ordinal] = &builtin_console_warn,
    [Builtin.CONSOLE_ERROR.ordinal] = &builtin_console_error,
    [Builtin.CONSOLE_DIR.ordinal] = &builtin_console_dir,
    [Builtin.CONSOLE_ASSERT.ordinal] = &builtin_console_assert,
    [Builtin.DATE.ordinal] = &builtin_date,
    [Builtin.DATE_NOW.ordinal] = &builtin_date_now,
    [Builtin.DATE_PARSE.ordinal] = &builtin_date_parse,
    [Builtin.DATE_PROTO_GETDATE.ordinal] = &builtin_date_proto_getDate,
    [Builtin.DATE_PROTO_GETDAY.ordinal] = &builtin_date_proto_getDay,
    [Builtin.DATE_PROTO_GETFULLYEAR.ordinal] = &builtin_date_proto_getFullYear,
    [Builtin.DATE_PROTO_GETHOURS.ordinal] = &builtin_date_proto_getHours,
    [Builtin.DATE_PROTO_GETMILLISECONDS.ordinal] = &builtin_date_proto_getMilliseconds,
    [Builtin.DATE_PROTO_GETMINUTES.ordinal] = &builtin_date_proto_getMinutes,
    [Builtin.DATE_PROTO_GETMONTH.ordinal] = &builtin_date_proto_getMonth,
    [Builtin.DATE_PROTO_GETSECONDS.ordinal] = &builtin_date_proto_getSeconds,
    [Builtin.DATE_PROTO_GETTIME.ordinal] = &builtin_date_proto_getTime,
    [Builtin.DATE_PROTO_GETTIMEZONEOFFSET.ordinal] = &builtin_date_proto_getTimezoneOffset,
    [Builtin.DATE_PROTO_GETUTCDATE.ordinal] = &builtin_date_proto_getUTCDate,
    [Builtin.DATE_PROTO_GETUTCDAY.ordinal] = &builtin_date_proto_getUTCDay,
    [Builtin.DATE_PROTO_GETUTCFULLYEAR.ordinal] = &builtin_date_proto_getUTCFullYear,
    [Builtin.DATE_PROTO_GETUTCHOURS.ordinal] = &builtin_date_proto_getUTCHours,
    [Builtin.DATE_PROTO_GETUTCMILLISECONDS.ordinal] = &builtin_date_proto_getUTCMilliseconds,
    [Builtin.DATE_PROTO_GETUTCMINUTES.ordinal] = &builtin_date_proto_getUTCMinutes,
    [Builtin.DATE_PROTO_GETUTCMONTH.ordinal] = &builtin_date_proto_getUTCMonth,
    [Builtin.DATE_PROTO_GETUTCSECONDS.ordinal] = &builtin_date_proto_getUTCSeconds,
    [Builtin.DATE_PROTO_SETDATE.ordinal] = &builtin_date_proto_setDate,
    [Builtin.DATE_PROTO_SETFULLYEAR.ordinal] = &builtin_date_proto_setFullYear,
    [Builtin.DATE_PROTO_SETHOURS.ordinal] = &builtin_date_proto_setHours,
    [Builtin.DATE_PROTO_SETMILLISECONDS.ordinal] = &builtin_date_proto_setMilliseconds,
    [Builtin.DATE_PROTO_SETMINUTES.ordinal] = &builtin_date_proto_setMinutes,
    [Builtin.DATE_PROTO_SETMONTH.ordinal] = &builtin_date_proto_setMonth,
    [Builtin.DATE_PROTO_SETSECONDS.ordinal] = &builtin_date_proto_setSeconds,
    [Builtin.DATE_PROTO_SETTIME.ordinal] = &builtin_date_proto_setTime,
    [Builtin.DATE_PROTO_SETUTCDATE.ordinal] = &builtin_date_proto_setUTCDate,
    [Builtin.DATE_PROTO_SETUTCFULLYEAR.ordinal] = &builtin_date_proto_setUTCFullYear,
    [Builtin.DATE_PROTO_SETUTCHOURS.ordinal] = &builtin_date_proto_setUTCHours,
    [Builtin.DATE_PROTO_SETUTCMILLISECONDS.ordinal] = &builtin_date_proto_setUTCMilliseconds,
    [Builtin.DATE_PROTO_SETUTCMINUTES.ordinal] = &builtin_date_proto_setUTCMinutes,
    [Builtin.DATE_PROTO_SETUTCMONTH.ordinal] = &builtin_date_proto_setUTCMonth,
    [Builtin.DATE_PROTO_SETUTCSECONDS.ordinal] = &builtin_date_proto_setUTCSeconds,
    [Builtin.DATE_PROTO_TOISOSTRING.ordinal] = &builtin_date_proto_toISOString,
    [Builtin.DATE_PROTO_TOJSON.ordinal] = &builtin_date_proto_toJSON,
    [Builtin.DATE_PROTO_TOLOCALEDATESTRING.ordinal] = &builtin_date_proto_toLocaleDateString,
    [Builtin.DATE_PROTO_TOLOCALESTRING.ordinal] = &builtin_date_proto_toLocaleString,
    [Builtin.DATE_PROTO_TOLOCALETIMESTRING.ordinal] = &builtin_date_proto_toLocaleTimeString,
    [Builtin.DATE_PROTO_TODATESTRING.ordinal] = &builtin_date_proto_toDateString,
    [Builtin.DATE_PROTO_TOTIMESTRING.ordinal] = &builtin_date_proto_toTimeString,
    [Builtin.DATE_PROTO_TOSTRING.ordinal] = &builtin_date_proto_toString,
    [Builtin.DATE_PROTO_TOUTCSTRING.ordinal] = &builtin_date_proto_toUTCString,
    [Builtin.DATE_PROTO_VALUEOF.ordinal] = &builtin_date_proto_valueOf,
    [Builtin.DATE_UTC.ordinal] = &builtin_date_utc,
    [Builtin.DECODE_URI.ordinal] = &builtin_decode_uri,
    [Builtin.DECODE_URI_COMPONENT.ordinal] = &builtin_decode_uri_component,
    [Builtin.ENCODE_URI.ordinal] = &builtin_encode_uri,
    [Builtin.ENCODE_URI_COMPONENT.ordinal] = &builtin_encode_uri_component,
    [Builtin.ERROR.ordinal] = &builtin_error,
    [Builtin.ERROR_CAPTURE_STACK_TRACE.ordinal] = &builtin_error_captureStackTrace,
    [Builtin.ERROR_PROTO_TOSTRING.ordinal] = &builtin_error_prototype_to_string,
    [Builtin.EVAL.ordinal] = &builtin_eval,
    [Builtin.EVAL_ERROR.ordinal] = &builtin_eval_error,
    [Builtin.FUNCTION.ordinal] = &builtin_function,
    [Builtin.FUNCTION_PROTO_APPLY.ordinal] = &builtin_function_proto_apply,
    [Builtin.FUNCTION_PROTO_BIND.ordinal] = &builtin_function_proto_bind,
    [Builtin.FUNCTION_PROTO_CALL.ordinal] = &builtin_function_proto_call,
    [Builtin.FUNCTION_PROTO_TOSTRING.ordinal] = &builtin_function_proto_toString,
    [Builtin.GENERATOR_FUNCTION.ordinal] = &builtin_generator_function,
    [Builtin.GENERATOR_PROTO_NEXT.ordinal] = &builtin_generator_proto_next,
    [Builtin.GENERATOR_PROTO_RETURN.ordinal] = &builtin_generator_proto_return,
    [Builtin.GENERATOR_PROTO_THROW.ordinal] = &builtin_generator_proto_throw,
    [Builtin.IS_FINITE.ordinal] = &builtin_is_finite,
    [Builtin.IS_NAN.ordinal] = &builtin_is_nan,
    [Builtin.ITERATOR_PROTO_SYMBOL_ITER.ordinal] = &builtin_iterator_proto_symbol_iter,
    [Builtin.JSON_PARSE.ordinal] = &builtin_json_parse,
    [Builtin.JSON_STRINGIFY.ordinal] = &builtin_json_stringify,
    [Builtin.JSON_RAW_JSON.ordinal] = &builtin_json_raw_json,
    [Builtin.JSON_IS_RAW_JSON.ordinal] = &builtin_json_is_raw_json,
    [Builtin.MAP.ordinal] = &builtin_map,
    [Builtin.MAP_GROUPBY.ordinal] = &builtin_map_groupBy,
    [Builtin.MAP_ITERATOR_NEXT.ordinal] = &builtin_map_iterator_next,
    [Builtin.MAP_PROTO_CLEAR.ordinal] = &builtin_map_proto_clear,
    [Builtin.MAP_PROTO_DELETE.ordinal] = &builtin_map_proto_delete,
    [Builtin.MAP_PROTO_ENTRIES.ordinal] = &builtin_map_proto_entries,
    [Builtin.MAP_PROTO_FOREACH.ordinal] = &builtin_map_proto_forEach,
    [Builtin.MAP_PROTO_GET.ordinal] = &builtin_map_proto_get,
    [Builtin.MAP_PROTO_GETORINSERT.ordinal] = &builtin_map_proto_getOrInsert,
    [Builtin.MAP_PROTO_GETORINSERTCOMPUTED.ordinal] = &builtin_map_proto_getOrInsertComputed,
    [Builtin.MAP_PROTO_HAS.ordinal] = &builtin_map_proto_has,
    [Builtin.MAP_PROTO_KEYS.ordinal] = &builtin_map_proto_keys,
    [Builtin.MAP_PROTO_SET.ordinal] = &builtin_map_proto_set,
    [Builtin.MAP_PROTO_SIZE_GET.ordinal] = &builtin_map_proto_size_get,
    [Builtin.MAP_PROTO_VALUES.ordinal] = &builtin_map_proto_values,
    [Builtin.MATH_ABS.ordinal] = &builtin_math_abs,
    [Builtin.MATH_ACOS.ordinal] = &builtin_math_acos,
    [Builtin.MATH_ACOSH.ordinal] = &builtin_math_acosh,
    [Builtin.MATH_ASIN.ordinal] = &builtin_math_asin,
    [Builtin.MATH_ASINH.ordinal] = &builtin_math_asinh,
    [Builtin.MATH_ATAN.ordinal] = &builtin_math_atan,
    [Builtin.MATH_ATAN2.ordinal] = &builtin_math_atan2,
    [Builtin.MATH_ATANH.ordinal] = &builtin_math_atanh,
    [Builtin.MATH_CBRT.ordinal] = &builtin_math_cbrt,
    [Builtin.MATH_CEIL.ordinal] = &builtin_math_ceil,
    [Builtin.MATH_CLZ32.ordinal] = &builtin_math_clz32,
    [Builtin.MATH_COS.ordinal] = &builtin_math_cos,
    [Builtin.MATH_COSH.ordinal] = &builtin_math_cosh,
    [Builtin.MATH_EXP.ordinal] = &builtin_math_exp,
    [Builtin.MATH_EXPM1.ordinal] = &builtin_math_expm1,
    [Builtin.MATH_FLOOR.ordinal] = &builtin_math_floor,
    [Builtin.MATH_FROUND.ordinal] = &builtin_math_fround,
    [Builtin.MATH_HYPOT.ordinal] = &builtin_math_hypot,
    [Builtin.MATH_IMUL.ordinal] = &builtin_math_imul,
    [Builtin.MATH_SUMPRECISE.ordinal] = &builtin_math_sumPrecise,
    [Builtin.MATH_LOG.ordinal] = &builtin_math_log,
    [Builtin.MATH_LOG10.ordinal] = &builtin_math_log10,
    [Builtin.MATH_LOG1P.ordinal] = &builtin_math_log1p,
    [Builtin.MATH_LOG2.ordinal] = &builtin_math_log2,
    [Builtin.MATH_MAX.ordinal] = &builtin_math_max,
    [Builtin.MATH_MIN.ordinal] = &builtin_math_min,
    [Builtin.MATH_POW.ordinal] = &builtin_math_pow,
    [Builtin.MATH_RANDOM.ordinal] = &builtin_math_random,
    [Builtin.MATH_ROUND.ordinal] = &builtin_math_round,
    [Builtin.MATH_SIGN.ordinal] = &builtin_math_sign,
    [Builtin.MATH_SIN.ordinal] = &builtin_math_sin,
    [Builtin.MATH_SINH.ordinal] = &builtin_math_sinh,
    [Builtin.MATH_SQRT.ordinal] = &builtin_math_sqrt,
    [Builtin.MATH_TAN.ordinal] = &builtin_math_tan,
    [Builtin.MATH_TANH.ordinal] = &builtin_math_tanh,
    [Builtin.MATH_TRUNC.ordinal] = &builtin_math_trunc,
    [Builtin.NUMBER.ordinal] = &builtin_number,
    [Builtin.NUMBER_ISFINITE.ordinal] = &builtin_number_isFinite,
    [Builtin.NUMBER_ISINTEGER.ordinal] = &builtin_number_isInteger,
    [Builtin.NUMBER_ISNAN.ordinal] = &builtin_number_isNaN,
    [Builtin.NUMBER_ISSAFEINTEGER.ordinal] = &builtin_number_isSafeInteger,
    [Builtin.NUMBER_PROTO_TOEXPONENTIAL.ordinal] = &builtin_number_proto_toExponential,
    [Builtin.NUMBER_PROTO_TOFIXED.ordinal] = &builtin_number_proto_toFixed,
    [Builtin.NUMBER_PROTO_TOPRECISION.ordinal] = &builtin_number_proto_toPrecision,
    [Builtin.NUMBER_PROTO_TOSTRING.ordinal] = &builtin_number_proto_toString,
    [Builtin.NUMBER_PROTO_VALUEOF.ordinal] = &builtin_number_proto_valueOf,
    [Builtin.OBJECT.ordinal] = &builtin_object,
    [Builtin.OBJECT_ASSIGN.ordinal] = &builtin_object_assign,
    [Builtin.OBJECT_CREATE.ordinal] = &builtin_object_create,
    [Builtin.OBJECT_DEFINEPROPERTIES.ordinal] = &builtin_object_defineProperties,
    [Builtin.OBJECT_DEFINEPROPERTY.ordinal] = &builtin_object_defineProperty,
    [Builtin.OBJECT_ENTRIES.ordinal] = &builtin_object_entries,
    [Builtin.OBJECT_FREEZE.ordinal] = &builtin_object_freeze,
    [Builtin.OBJECT_FROMENTRIES.ordinal] = &builtin_object_fromEntries,
    [Builtin.OBJECT_GETOWNPROPERTYDESCRIPTOR.ordinal] = &builtin_object_getOwnPropertyDescriptor,
    [Builtin.OBJECT_GETOWNPROPERTYNAMES.ordinal] = &builtin_object_getOwnPropertyNames,
    [Builtin.OBJECT_GETOWNPROPERTYSYMBOLS.ordinal] = &builtin_object_getOwnPropertySymbols,
    [Builtin.OBJECT_GETPROTOTYPEOF.ordinal] = &builtin_object_getPrototypeOf,
    [Builtin.OBJECT_GROUPBY.ordinal] = &builtin_object_groupBy,
    [Builtin.OBJECT_HASOWN.ordinal] = &builtin_object_hasOwn,
    [Builtin.OBJECT_IS.ordinal] = &builtin_object_is,
    [Builtin.OBJECT_ISEXTENSIBLE.ordinal] = &builtin_object_isExtensible,
    [Builtin.OBJECT_ISFROZEN.ordinal] = &builtin_object_isFrozen,
    [Builtin.OBJECT_ISSEALED.ordinal] = &builtin_object_isSealed,
    [Builtin.OBJECT_KEYS.ordinal] = &builtin_object_keys,
    [Builtin.OBJECT_PREVENTEXTENSIONS.ordinal] = &builtin_object_preventExtensions,
    [Builtin.OBJECT_PROTO_HASOWNPROPERTY.ordinal] = &builtin_object_proto_hasOwnProperty,
    [Builtin.OBJECT_PROTO_ISPROTOTYPEOF.ordinal] = &builtin_object_proto_isPrototypeOf,
    [Builtin.OBJECT_PROTO_PROPERTYISENUMERABLE.ordinal] = &builtin_object_proto_propertyIsEnumerable,
    [Builtin.OBJECT_PROTO_TOLOCALESTRING.ordinal] = &builtin_object_proto_toLocaleString,
    [Builtin.OBJECT_PROTO_TOSTRING.ordinal] = &builtin_object_proto_toString,
    [Builtin.OBJECT_PROTO_VALUEOF.ordinal] = &builtin_object_proto_valueOf,
    [Builtin.OBJECT_PROTO___PROTO___GETTER.ordinal] = &builtin_object_proto___proto___getter,
    [Builtin.OBJECT_PROTO___PROTO___SETTER.ordinal] = &builtin_object_proto___proto___setter,
    [Builtin.OBJECT_SEAL.ordinal] = &builtin_object_seal,
    [Builtin.OBJECT_SETPROTOTYPEOF.ordinal] = &builtin_object_setPrototypeOf,
    [Builtin.OBJECT_VALUES.ordinal] = &builtin_object_values,
    [Builtin.OBJECT_GETOWNPROPERTYDESCRIPTORS.ordinal] = &builtin_object_getOwnPropertyDescriptors,
    [Builtin.PARSE_FLOAT.ordinal] = &builtin_parse_float,
    [Builtin.PARSE_INT.ordinal] = &builtin_parse_int,
    [Builtin.PRINT.ordinal] = &builtin_print,
    [Builtin.PROMISE.ordinal] = &builtin_promise,
    [Builtin.PROMISE_ALL.ordinal] = &builtin_promise_all,
    [Builtin.PROMISE_ALL_RESOLVE_ELEMENT.ordinal] = &builtin_promise_all_resolve_element,
    [Builtin.PROMISE_ALL_REJECT_ELEMENT.ordinal] = &builtin_promise_all_reject_element,
    [Builtin.PROMISE_ALLSETTLED.ordinal] = &builtin_promise_allsettled,
    [Builtin.PROMISE_ALLSETTLED_RESOLVE_ELEMENT.ordinal] = &builtin_promise_allsettled_resolve_element,
    [Builtin.PROMISE_ALLSETTLED_REJECT_ELEMENT.ordinal] = &builtin_promise_allsettled_reject_element,
    [Builtin.PROMISE_ANY.ordinal] = &builtin_promise_any,
    [Builtin.PROMISE_ANY_RESOLVE_ELEMENT.ordinal] = &builtin_promise_any_resolve_element,
    [Builtin.PROMISE_ANY_REJECT_ELEMENT.ordinal] = &builtin_promise_any_reject_element,
    [Builtin.PROMISE_SYNTHETIC_EXECUTOR.ordinal] = &builtin_promise_synthetic_executor,
    [Builtin.PROMISE_RESOLVE_THENABLE_JOB.ordinal] = &builtin_promise_resolve_thenable_job,
    [Builtin.PROMISE_THEN_FINALLY.ordinal] = &builtin_promise_then_finally,
    [Builtin.PROMISE_CATCH_FINALLY.ordinal] = &builtin_promise_catch_finally,
    [Builtin.ARRAY_SPECIES_GETTER.ordinal] = &builtin_array_species_getter,
    [Builtin.PROMISE_PROTO_CATCH.ordinal] = &builtin_promise_proto_catch,
    [Builtin.PROMISE_PROTO_FINALLY.ordinal] = &builtin_promise_proto_finally,
    [Builtin.PROMISE_PROTO_THEN.ordinal] = &builtin_promise_proto_then,
    [Builtin.PROMISE_RACE.ordinal] = &builtin_promise_race,
    [Builtin.PROMISE_REJECT.ordinal] = &builtin_promise_reject,
    [Builtin.PROMISE_REJECT_CALLBACK.ordinal] = &builtin_promise_reject_callback,
    [Builtin.PROMISE_RESOLVE.ordinal] = &builtin_promise_resolve,
    [Builtin.PROMISE_RESOLVE_CALLBACK.ordinal] = &builtin_promise_resolve_callback,
    [Builtin.RANGE_ERROR.ordinal] = &builtin_range_error,
    [Builtin.REFERENCE_ERROR.ordinal] = &builtin_reference_error,
    [Builtin.REGEXP.ordinal] = &builtin_regexp,
    [Builtin.REGEXP_PROTO_EXEC.ordinal] = &builtin_regexp_proto_exec,
    [Builtin.REGEXP_PROTO_GET_DOTALL.ordinal] = &builtin_regexp_proto_get_dotAll,
    [Builtin.REGEXP_PROTO_GET_FLAGS.ordinal] = &builtin_regexp_proto_get_flags,
    [Builtin.REGEXP_PROTO_GET_GLOBAL.ordinal] = &builtin_regexp_proto_get_global,
    [Builtin.REGEXP_PROTO_GET_HASINDICES.ordinal] = &builtin_regexp_proto_get_hasIndices,
    [Builtin.REGEXP_PROTO_GET_IGNORECASE.ordinal] = &builtin_regexp_proto_get_ignoreCase,
    [Builtin.REGEXP_PROTO_GET_MULTILINE.ordinal] = &builtin_regexp_proto_get_multiline,
    [Builtin.REGEXP_PROTO_GET_SOURCE.ordinal] = &builtin_regexp_proto_get_source,
    [Builtin.REGEXP_PROTO_GET_STICKY.ordinal] = &builtin_regexp_proto_get_sticky,
    [Builtin.REGEXP_PROTO_GET_UNICODE.ordinal] = &builtin_regexp_proto_get_unicode,
    [Builtin.REGEXP_PROTO_GET_UNICODESETS.ordinal] = &builtin_regexp_proto_get_unicodeSets,
    [Builtin.REGEXP_PROTO_SYMBOL_MATCH.ordinal] = &builtin_regexp_proto_symbol_match,
    [Builtin.REGEXP_PROTO_SYMBOL_SEARCH.ordinal] = &builtin_regexp_proto_symbol_search,
    [Builtin.REGEXP_PROTO_SYMBOL_REPLACE.ordinal] = &builtin_regexp_proto_symbol_replace,
    [Builtin.REGEXP_PROTO_SYMBOL_SPLIT.ordinal] = &builtin_regexp_proto_symbol_split,
    [Builtin.REGEXP_PROTO_SYMBOL_MATCHALL.ordinal] = &builtin_regexp_proto_symbol_matchAll,
    [Builtin.REGEXP_PROTO_TEST.ordinal] = &builtin_regexp_proto_test,
    [Builtin.REGEXP_PROTO_TOSTRING.ordinal] = &builtin_regexp_proto_toString,
    [Builtin.REGEXP_STRING_ITERATOR_NEXT.ordinal] = &builtin_regexp_string_iterator_next,
    [Builtin.ASYNC_RESUME.ordinal] = &builtin_async_resume,
    [Builtin.ASYNC_REJECT.ordinal] = &builtin_async_reject,
    [Builtin.REFLECT_OWNKEYS.ordinal] = &builtin_reflect_ownKeys,
    [Builtin.RESET_GLOBALS.ordinal] = &builtin_reset_globals,
    [Builtin.SET.ordinal] = &builtin_set,
    [Builtin.SET_ITERATOR_NEXT.ordinal] = &builtin_set_iterator_next,
    [Builtin.SET_PROTO_ADD.ordinal] = &builtin_set_proto_add,
    [Builtin.SET_PROTO_SIZE_GET.ordinal] = &builtin_set_proto_size_get,
    [Builtin.SET_PROTO_CLEAR.ordinal] = &builtin_set_proto_clear,
    [Builtin.SET_PROTO_DELETE.ordinal] = &builtin_set_proto_delete,
    [Builtin.SET_PROTO_ENTRIES.ordinal] = &builtin_set_proto_entries,
    [Builtin.SET_PROTO_FOREACH.ordinal] = &builtin_set_proto_forEach,
    [Builtin.SET_PROTO_HAS.ordinal] = &builtin_set_proto_has,
    [Builtin.SET_PROTO_VALUES.ordinal] = &builtin_set_proto_values,
    [Builtin.STRING.ordinal] = &builtin_string,
    [Builtin.STRING_FROMCHARCODE.ordinal] = &builtin_string_fromcharcode,
    [Builtin.STRING_FROMCODEPOINT.ordinal] = &builtin_string_fromcodepoint,
    [Builtin.STRING_RAW.ordinal] = &builtin_string_raw,
    [Builtin.STRING_ITERATOR_NEXT.ordinal] = &builtin_string_iterator_next,
    [Builtin.STRING_PROTO_AT.ordinal] = &builtin_string_proto_at,
    [Builtin.STRING_PROTO_CHARAT.ordinal] = &builtin_string_proto_charAt,
    [Builtin.STRING_PROTO_CHARCODEAT.ordinal] = &builtin_string_proto_charCodeAt,
    [Builtin.STRING_PROTO_CODEPOINTAT.ordinal] = &builtin_string_proto_codePointAt,
    [Builtin.STRING_PROTO_CONCAT.ordinal] = &builtin_string_proto_concat,
    [Builtin.STRING_PROTO_ENDSWITH.ordinal] = &builtin_string_proto_endsWith,
    [Builtin.STRING_PROTO_INCLUDES.ordinal] = &builtin_string_proto_includes,
    [Builtin.STRING_PROTO_INDEXOF.ordinal] = &builtin_string_proto_indexOf,
    [Builtin.STRING_PROTO_LASTINDEXOF.ordinal] = &builtin_string_proto_lastIndexOf,
    [Builtin.STRING_PROTO_MATCH.ordinal] = &builtin_string_proto_match,
    [Builtin.STRING_PROTO_MATCHALL.ordinal] = &builtin_string_proto_matchAll,
    [Builtin.STRING_PROTO_NORMALIZE.ordinal]    = &builtin_string_proto_normalize,
    [Builtin.STRING_PROTO_ISWELLFORMED.ordinal] = &builtin_string_proto_isWellFormed,
    [Builtin.STRING_PROTO_TOWELLFORMED.ordinal] = &builtin_string_proto_toWellFormed,
    [Builtin.STRING_PROTO_PADEND.ordinal] = &builtin_string_proto_padEnd,
    [Builtin.STRING_PROTO_PADSTART.ordinal] = &builtin_string_proto_padStart,
    [Builtin.STRING_PROTO_REPEAT.ordinal] = &builtin_string_proto_repeat,
    [Builtin.STRING_PROTO_REPLACE.ordinal] = &builtin_string_proto_replace,
    [Builtin.STRING_PROTO_REPLACEALL.ordinal] = &builtin_string_proto_replaceAll,
    [Builtin.STRING_PROTO_SEARCH.ordinal] = &builtin_string_proto_search,
    [Builtin.STRING_PROTO_SLICE.ordinal] = &builtin_string_proto_slice,
    [Builtin.STRING_PROTO_SPLIT.ordinal] = &builtin_string_proto_split,
    [Builtin.STRING_PROTO_STARTSWITH.ordinal] = &builtin_string_proto_startsWith,
    [Builtin.STRING_PROTO_SUBSTR.ordinal] = &builtin_string_proto_substr,
    [Builtin.STRING_PROTO_SUBSTRING.ordinal] = &builtin_string_proto_substring,
    [Builtin.STRING_PROTO_SYMBOL_ITER.ordinal] = &builtin_string_proto_symbol_iter,
    [Builtin.STRING_PROTO_TOLOWERCASE.ordinal] = &builtin_string_proto_toLowerCase,
    [Builtin.STRING_PROTO_TOSTRING.ordinal] = &builtin_string_proto_toString,
    [Builtin.STRING_PROTO_TOUPPERCASE.ordinal] = &builtin_string_proto_toUpperCase,
    [Builtin.STRING_PROTO_TRIM.ordinal] = &builtin_string_proto_trim,
    [Builtin.STRING_PROTO_TOLOCALELOWERCASE.ordinal] = &builtin_string_proto_toLocaleLowerCase,
    [Builtin.STRING_PROTO_TOLOCALEUPPERCASE.ordinal] = &builtin_string_proto_toLocaleUpperCase,
    [Builtin.STRING_PROTO_LOCALECOMPARE.ordinal] = &builtin_string_proto_localeCompare,
    [Builtin.STRING_PROTO_TRIMEND.ordinal] = &builtin_string_proto_trimEnd,
    [Builtin.STRING_PROTO_TRIMSTART.ordinal] = &builtin_string_proto_trimStart,
    [Builtin.STRING_PROTO_VALUEOF.ordinal] = &builtin_string_proto_valueOf,
    [Builtin.SYMBOL.ordinal] = &builtin_symbol,
    [Builtin.SYMBOL_FOR.ordinal] = &builtin_symbol_for,
    [Builtin.SYMBOL_KEYFOR.ordinal] = &builtin_symbol_keyfor,
    [Builtin.SYMBOL_PROTO_TOSTRING.ordinal] = &builtin_symbol_proto_toString,
    [Builtin.SYMBOL_PROTO_VALUEOF.ordinal] = &builtin_symbol_proto_valueOf,
    [Builtin.SYMBOL_PROTO_TOPRIMITIVE.ordinal] = &builtin_symbol_proto_toprimitive,
    [Builtin.SYMBOL_PROTO_DESCRIPTION_GET.ordinal] = &builtin_symbol_proto_description_get,
    [Builtin.SYNTAX_ERROR.ordinal] = &builtin_syntax_error,
    [Builtin.TYPE_ERROR.ordinal] = &builtin_type_error,
    [Builtin.URI_ERROR.ordinal] = &builtin_uri_error,
    [Builtin.WEAKMAP.ordinal] = &builtin_weakmap,
    [Builtin.WEAKMAP_PROTO_DELETE.ordinal] = &builtin_weakmap_proto_delete,
    [Builtin.WEAKMAP_PROTO_GET.ordinal] = &builtin_weakmap_proto_get,
    [Builtin.WEAKMAP_PROTO_GETORINSERT.ordinal] = &builtin_weakmap_proto_getOrInsert,
    [Builtin.WEAKMAP_PROTO_GETORINSERTCOMPUTED.ordinal] = &builtin_weakmap_proto_getOrInsertComputed,
    [Builtin.WEAKMAP_PROTO_HAS.ordinal] = &builtin_weakmap_proto_has,
    [Builtin.WEAKMAP_PROTO_SET.ordinal] = &builtin_weakmap_proto_set,
    [Builtin.WEAKSET.ordinal] = &builtin_weakset,
    [Builtin.WEAKSET_PROTO_ADD.ordinal] = &builtin_weakset_proto_add,
    [Builtin.WEAKSET_PROTO_DELETE.ordinal] = &builtin_weakset_proto_delete,
    [Builtin.WEAKSET_PROTO_HAS.ordinal] = &builtin_weakset_proto_has,
    [Builtin.WEAKREF.ordinal] = &builtin_weakref,
    [Builtin.WEAKREF_PROTO_DEREF.ordinal] = &builtin_weakref_proto_deref,
    [Builtin.FINALIZATION_REGISTRY.ordinal] = &builtin_finalization_registry,
    [Builtin.FINALIZATION_REGISTRY_PROTO_REGISTER.ordinal] = &builtin_finalization_registry_proto_register,
    [Builtin.FINALIZATION_REGISTRY_PROTO_UNREGISTER.ordinal] = &builtin_finalization_registry_proto_unregister,
    // TypedArray constructors
    [Builtin.INT8ARRAY.ordinal] = &builtin_int8array,
    [Builtin.UINT8ARRAY.ordinal] = &builtin_uint8array,
    [Builtin.UINT8CLAMPEDARRAY.ordinal] = &builtin_uint8clampedarray,
    [Builtin.INT16ARRAY.ordinal] = &builtin_int16array,
    [Builtin.UINT16ARRAY.ordinal] = &builtin_uint16array,
    [Builtin.INT32ARRAY.ordinal] = &builtin_int32array,
    [Builtin.UINT32ARRAY.ordinal] = &builtin_uint32array,
    [Builtin.FLOAT32ARRAY.ordinal] = &builtin_float32array,
    [Builtin.FLOAT64ARRAY.ordinal] = &builtin_float64array,
    [Builtin.BIGINT64ARRAY.ordinal] = &builtin_bigint64array,
    [Builtin.BIGUINT64ARRAY.ordinal] = &builtin_biguint64array,
    // ArrayBuffer core (plan 049 stage 1)
    [Builtin.ARRAYBUFFER.ordinal] = &builtin_arraybuffer,
    [Builtin.ARRAYBUFFER_ISVIEW.ordinal] = &builtin_arraybuffer_isview,
    [Builtin.ARRAYBUFFER_PROTO_BYTELENGTH_GET.ordinal] = &builtin_arraybuffer_proto_bytelength_get,
    [Builtin.ARRAYBUFFER_PROTO_SLICE.ordinal] = &builtin_arraybuffer_proto_slice,
    [Builtin.ARRAYBUFFER_PROTO_DETACHED_GET.ordinal] = &builtin_arraybuffer_proto_detached_get,
    [Builtin.ARRAYBUFFER_SPECIES_GET.ordinal] = &builtin_arraybuffer_species_get,
    [Builtin.ARRAYBUFFER_PROTO_RESIZE.ordinal] = &builtin_arraybuffer_proto_resize,
    [Builtin.ARRAYBUFFER_PROTO_RESIZABLE_GET.ordinal] = &builtin_arraybuffer_proto_resizable_get,
    [Builtin.ARRAYBUFFER_PROTO_MAXBYTELENGTH_GET.ordinal] = &builtin_arraybuffer_proto_maxbytelength_get,
    [Builtin.DETACH_ARRAYBUFFER.ordinal] = &builtin_detach_arraybuffer,
    // TypedArray.prototype accessors (plan 049 stage 2)
    [Builtin.TYPEDARRAY_PROTO_LENGTH_GET.ordinal] = &builtin_typedarray_proto_length_get,
    [Builtin.TYPEDARRAY_PROTO_BYTELENGTH_GET.ordinal] = &builtin_typedarray_proto_bytelength_get,
    [Builtin.TYPEDARRAY_PROTO_BYTEOFFSET_GET.ordinal] = &builtin_typedarray_proto_byteoffset_get,
    [Builtin.TYPEDARRAY_PROTO_BUFFER_GET.ordinal] = &builtin_typedarray_proto_buffer_get,
    [Builtin.TYPEDARRAY_PROTO_TOSTRINGTAG_GET.ordinal] = &builtin_typedarray_proto_tostringtag_get,

    // DataView constructor/prototype (plan 049 stage 3)
    [Builtin.DATAVIEW.ordinal] = &builtin_dataview,
    [Builtin.DATAVIEW_PROTO_BUFFER_GET.ordinal] = &builtin_dataview_proto_buffer_get,
    [Builtin.DATAVIEW_PROTO_BYTELENGTH_GET.ordinal] = &builtin_dataview_proto_bytelength_get,
    [Builtin.DATAVIEW_PROTO_BYTEOFFSET_GET.ordinal] = &builtin_dataview_proto_byteoffset_get,
    [Builtin.DATAVIEW_GET_INT8.ordinal] = &builtin_dataview_get_int8,
    [Builtin.DATAVIEW_GET_UINT8.ordinal] = &builtin_dataview_get_uint8,
    [Builtin.DATAVIEW_GET_INT16.ordinal] = &builtin_dataview_get_int16,
    [Builtin.DATAVIEW_GET_UINT16.ordinal] = &builtin_dataview_get_uint16,
    [Builtin.DATAVIEW_GET_INT32.ordinal] = &builtin_dataview_get_int32,
    [Builtin.DATAVIEW_GET_UINT32.ordinal] = &builtin_dataview_get_uint32,
    [Builtin.DATAVIEW_GET_FLOAT32.ordinal] = &builtin_dataview_get_float32,
    [Builtin.DATAVIEW_GET_FLOAT64.ordinal] = &builtin_dataview_get_float64,
    [Builtin.DATAVIEW_SET_INT8.ordinal] = &builtin_dataview_set_int8,
    [Builtin.DATAVIEW_SET_UINT8.ordinal] = &builtin_dataview_set_uint8,
    [Builtin.DATAVIEW_SET_INT16.ordinal] = &builtin_dataview_set_int16,
    [Builtin.DATAVIEW_SET_UINT16.ordinal] = &builtin_dataview_set_uint16,
    [Builtin.DATAVIEW_SET_INT32.ordinal] = &builtin_dataview_set_int32,
    [Builtin.DATAVIEW_SET_UINT32.ordinal] = &builtin_dataview_set_uint32,
    [Builtin.DATAVIEW_SET_FLOAT32.ordinal] = &builtin_dataview_set_float32,
    [Builtin.DATAVIEW_SET_FLOAT64.ordinal] = &builtin_dataview_set_float64,
    // %TypedArray%.prototype wave A (plan 049 stage 4)
    [Builtin.TA_PROTO_VALUES.ordinal]          = &builtin_ta_proto_values,
    [Builtin.TA_PROTO_KEYS.ordinal]            = &builtin_ta_proto_keys,
    [Builtin.TA_PROTO_ENTRIES.ordinal]         = &builtin_ta_proto_entries,
    [Builtin.TA_PROTO_SET.ordinal]             = &builtin_ta_proto_set,
    [Builtin.TA_PROTO_SUBARRAY.ordinal]        = &builtin_ta_proto_subarray,
    [Builtin.TA_PROTO_FILL.ordinal]            = &builtin_ta_proto_fill,
    [Builtin.TA_PROTO_COPYWITHIN.ordinal]      = &builtin_ta_proto_copyWithin,
    [Builtin.TA_PROTO_SLICE.ordinal]           = &builtin_ta_proto_slice,
    // %TypedArray%.prototype wave B (plan 049 stage 5)
    [Builtin.TA_PROTO_INDEX_OF.ordinal]        = &builtin_ta_proto_indexOf,
    [Builtin.TA_PROTO_LAST_INDEX_OF.ordinal]   = &builtin_ta_proto_lastIndexOf,
    [Builtin.TA_PROTO_INCLUDES.ordinal]        = &builtin_ta_proto_includes,
    [Builtin.TA_PROTO_JOIN.ordinal]            = &builtin_ta_proto_join,
    [Builtin.TA_PROTO_FOR_EACH.ordinal]        = &builtin_ta_proto_forEach,
    [Builtin.TA_PROTO_EVERY.ordinal]           = &builtin_ta_proto_every,
    [Builtin.TA_PROTO_SOME.ordinal]            = &builtin_ta_proto_some,
    [Builtin.TA_PROTO_REDUCE.ordinal]          = &builtin_ta_proto_reduce,
    [Builtin.TA_PROTO_REDUCE_RIGHT.ordinal]    = &builtin_ta_proto_reduceRight,
    [Builtin.TA_PROTO_MAP.ordinal]             = &builtin_ta_proto_map,
    [Builtin.TA_PROTO_FILTER.ordinal]          = &builtin_ta_proto_filter,
    [Builtin.TA_PROTO_FIND.ordinal]            = &builtin_ta_proto_find,
    [Builtin.TA_PROTO_FIND_INDEX.ordinal]      = &builtin_ta_proto_findIndex,
    [Builtin.TA_PROTO_FIND_LAST.ordinal]       = &builtin_ta_proto_findLast,
    [Builtin.TA_PROTO_FIND_LAST_INDEX.ordinal] = &builtin_ta_proto_findLastIndex,
    [Builtin.TA_PROTO_REVERSE.ordinal]         = &builtin_ta_proto_reverse,
    [Builtin.TA_PROTO_TO_REVERSED.ordinal]     = &builtin_ta_proto_toReversed,
    [Builtin.TA_PROTO_AT.ordinal]              = &builtin_ta_proto_at,
    [Builtin.TA_PROTO_SORT.ordinal]            = &builtin_ta_proto_sort,
    [Builtin.TA_PROTO_TO_SORTED.ordinal]       = &builtin_ta_proto_toSorted,
    [Builtin.TA_PROTO_WITH.ordinal]            = &builtin_ta_proto_with,
    [Builtin.TA_PROTO_TO_STRING.ordinal]       = &builtin_ta_proto_toString,
    [Builtin.TA_PROTO_TO_LOCALE_STRING.ordinal] = &builtin_ta_proto_toLocaleString,
    [Builtin.TA_OF.ordinal]                    = &builtin_ta_of,
    [Builtin.TA_FROM.ordinal]                  = &builtin_ta_from,
    [Builtin.UINT8ARRAY_FROM_BASE64.ordinal]       = &builtin_uint8array_from_base64,
    [Builtin.UINT8ARRAY_FROM_HEX.ordinal]          = &builtin_uint8array_from_hex,
    [Builtin.UINT8ARRAY_PROTO_TO_BASE64.ordinal]   = &builtin_uint8array_proto_to_base64,
    [Builtin.UINT8ARRAY_PROTO_TO_HEX.ordinal]      = &builtin_uint8array_proto_to_hex,
    [Builtin.UINT8ARRAY_PROTO_SET_FROM_BASE64.ordinal] = &builtin_uint8array_proto_set_from_base64,
    [Builtin.UINT8ARRAY_PROTO_SET_FROM_HEX.ordinal]    = &builtin_uint8array_proto_set_from_hex,
    [Builtin.TYPEDARRAY_INTRINSIC.ordinal]     = &builtin_typedarray_intrinsic,
    [Builtin.FUNCTION_PROTO_HASINSTANCE.ordinal] = &builtin_function_proto_hasInstance,
    [Builtin.DATE_PROTO_TOPRIMITIVE.ordinal]     = &builtin_date_proto_toPrimitive,
    [Builtin.PROMISE_SPECIES_GETTER.ordinal]     = &builtin_promise_species_getter,
    [Builtin.ASYNC_FUNCTION.ordinal]             = &builtin_async_function,
    [Builtin.PROXY.ordinal]                      = &builtin_proxy,
    [Builtin.PROXY_REVOCABLE.ordinal]            = &builtin_proxy_revocable,
    [Builtin.PROXY_REVOKE.ordinal]               = &builtin_proxy_revoke,
    [Builtin.PROXY_CALL.ordinal]                 = &builtin_proxy_call,
    [Builtin.TA_SPECIES_GET.ordinal]             = &builtin_ta_species_get,
    // evalScript runs its argument as an independent global Script
    // (ES2015 §18.2.1 ScriptEvaluation), not as an eval call.
    [Builtin.EVAL_SCRIPT.ordinal]                = &builtin_eval_script,
    [Builtin.REGEXP_SPECIES_GETTER.ordinal]       = &builtin_regexp_species_getter,
    [Builtin.MODULE_BINDING_GETTER.ordinal]       = &builtin_module_binding_getter,
    [Builtin.REFLECT_GET.ordinal]                 = &builtin_reflect_get,
    [Builtin.REFLECT_SET.ordinal]                 = &builtin_reflect_set,
    [Builtin.REFLECT_HAS.ordinal]                 = &builtin_reflect_has,
    [Builtin.REFLECT_DELETE_PROPERTY.ordinal]     = &builtin_reflect_deleteProperty,
    [Builtin.REFLECT_GET_OWN_PROPERTY_DESCRIPTOR.ordinal] = &builtin_reflect_getOwnPropertyDescriptor,
    [Builtin.REFLECT_DEFINE_PROPERTY.ordinal]     = &builtin_reflect_defineProperty,
    [Builtin.REFLECT_GET_PROTOTYPE_OF.ordinal]    = &builtin_reflect_getPrototypeOf,
    [Builtin.REFLECT_SET_PROTOTYPE_OF.ordinal]    = &builtin_reflect_setPrototypeOf,
    [Builtin.REFLECT_IS_EXTENSIBLE.ordinal]       = &builtin_reflect_isExtensible,
    [Builtin.REFLECT_PREVENT_EXTENSIONS.ordinal]  = &builtin_reflect_preventExtensions,
    [Builtin.REFLECT_APPLY.ordinal]               = &builtin_reflect_apply,
    [Builtin.REFLECT_CONSTRUCT.ordinal]           = &builtin_reflect_construct,
    [Builtin.PROMISE_IDENTITY.ordinal]            = &builtin_promise_identity,
    [Builtin.PROMISE_THROWER.ordinal]             = &builtin_promise_thrower,
    [Builtin.MAP_SPECIES_GETTER.ordinal]          = &builtin_map_species_getter,
    [Builtin.SET_SPECIES_GETTER.ordinal]          = &builtin_set_species_getter,
    [Builtin.DATAVIEW_GET_BIGINT64.ordinal]       = &builtin_dataview_get_bigint64,
    [Builtin.DATAVIEW_GET_BIGUINT64.ordinal]      = &builtin_dataview_get_biguint64,
    [Builtin.DATAVIEW_SET_BIGINT64.ordinal]       = &builtin_dataview_set_bigint64,
    [Builtin.DATAVIEW_SET_BIGUINT64.ordinal]      = &builtin_dataview_set_biguint64,
    [Builtin.FUNCTION_PROTO_RESTRICTED_GETTER.ordinal] = &builtin_function_proto_restricted_getter,
    [Builtin.FUNCTION_PROTO_RESTRICTED_SETTER.ordinal] = &builtin_function_proto_restricted_setter,
    [Builtin.BIGINT.ordinal]                      = &builtin_bigint,
    [Builtin.BIGINT_AS_INTN.ordinal]              = &builtin_bigint_as_intn,
    [Builtin.BIGINT_AS_UINTN.ordinal]             = &builtin_bigint_as_uintn,
    [Builtin.BIGINT_PROTO_TOSTRING.ordinal]       = &builtin_bigint_proto_toString,
    [Builtin.BIGINT_PROTO_VALUEOF.ordinal]        = &builtin_bigint_proto_valueOf,
    [Builtin.ASYNC_FROM_SYNC_NEXT.ordinal]           = &builtin_async_from_sync_next,
    [Builtin.ASYNC_FROM_SYNC_RETURN.ordinal]         = &builtin_async_from_sync_return,
    [Builtin.ASYNC_FROM_SYNC_THROW.ordinal]          = &builtin_async_from_sync_throw,
    [Builtin.ASYNC_FROM_SYNC_VALUE_UNWRAP.ordinal]   = &builtin_async_from_sync_value_unwrap,
    [Builtin.ASYNC_FROM_SYNC_REJECT_FORWARD.ordinal] = &builtin_async_from_sync_reject_forward,
    [Builtin.ARRAY_FROM_ASYNC.ordinal]               = &builtin_array_from_async,
    [Builtin.ARRAY_FROM_ASYNC_STEP_FULFILL.ordinal]  = &builtin_array_from_async_step_fulfill,
    [Builtin.ARRAY_FROM_ASYNC_MAP_FULFILL.ordinal]   = &builtin_array_from_async_map_fulfill,
    [Builtin.ARRAY_FROM_ASYNC_REJECT.ordinal]        = &builtin_array_from_async_reject,
    [Builtin.PROMISE_WITH_RESOLVERS.ordinal]         = &builtin_promise_with_resolvers,
    [Builtin.PROMISE_TRY.ordinal]                    = &builtin_promise_try,
    [Builtin.ERROR_ISERROR.ordinal]                  = &builtin_error_isError,
    [Builtin.SET_PROTO_UNION.ordinal]               = &builtin_set_proto_union,
    [Builtin.SET_PROTO_INTERSECTION.ordinal]        = &builtin_set_proto_intersection,
    [Builtin.SET_PROTO_DIFFERENCE.ordinal]          = &builtin_set_proto_difference,
    [Builtin.SET_PROTO_SYMMETRICDIFFERENCE.ordinal] = &builtin_set_proto_symmetricDifference,
    [Builtin.SET_PROTO_ISSUBSETOF.ordinal]          = &builtin_set_proto_isSubsetOf,
    [Builtin.SET_PROTO_ISSUPERSETOF.ordinal]        = &builtin_set_proto_isSupersetOf,
    [Builtin.SET_PROTO_ISDISJOINTFROM.ordinal]      = &builtin_set_proto_isDisjointFrom,
    [Builtin.REGEXP_ESCAPE.ordinal]                  = &builtin_regexp_escape,
    [Builtin.ITERATOR_CTOR.ordinal]                 = &builtin_iterator_ctor,
    [Builtin.ITERATOR_FROM.ordinal]                 = &builtin_iterator_from,
    [Builtin.ITERATOR_PROTO_CONSTRUCTOR_GET.ordinal] = &builtin_iterator_proto_constructor_get,
    [Builtin.ITERATOR_PROTO_CONSTRUCTOR_SET.ordinal] = &builtin_iterator_proto_constructor_set,
    [Builtin.ITERATOR_PROTO_TOSTRINGTAG_GET.ordinal] = &builtin_iterator_proto_tostringtag_get,
    [Builtin.ITERATOR_PROTO_TOSTRINGTAG_SET.ordinal] = &builtin_iterator_proto_tostringtag_set,
    [Builtin.ITERATOR_PROTO_MAP.ordinal]             = &builtin_iterator_proto_map,
    [Builtin.ITERATOR_PROTO_FILTER.ordinal]          = &builtin_iterator_proto_filter,
    [Builtin.ITERATOR_PROTO_TAKE.ordinal]            = &builtin_iterator_proto_take,
    [Builtin.ITERATOR_PROTO_DROP.ordinal]            = &builtin_iterator_proto_drop,
    [Builtin.ITERATOR_PROTO_FLATMAP.ordinal]         = &builtin_iterator_proto_flatmap,
    [Builtin.ITERATOR_PROTO_REDUCE.ordinal]          = &builtin_iterator_proto_reduce,
    [Builtin.ITERATOR_PROTO_TOARRAY.ordinal]         = &builtin_iterator_proto_toarray,
    [Builtin.ITERATOR_PROTO_FOREACH.ordinal]         = &builtin_iterator_proto_foreach,
    [Builtin.ITERATOR_PROTO_SOME.ordinal]            = &builtin_iterator_proto_some,
    [Builtin.ITERATOR_PROTO_EVERY.ordinal]           = &builtin_iterator_proto_every,
    [Builtin.ITERATOR_PROTO_FIND.ordinal]            = &builtin_iterator_proto_find,
    [Builtin.ITERATOR_CONCAT.ordinal]                = &builtin_iterator_concat,
    [Builtin.WRAP_FOR_VALID_ITERATOR_NEXT.ordinal]   = &builtin_wrap_for_valid_iterator_next,
    [Builtin.WRAP_FOR_VALID_ITERATOR_RETURN.ordinal] = &builtin_wrap_for_valid_iterator_return,
    [Builtin.ITERATOR_HELPER_NEXT.ordinal]           = &builtin_iterator_helper_next,
    [Builtin.ITERATOR_HELPER_RETURN.ordinal]         = &builtin_iterator_helper_return,
};

fn void dispatch_builtin(uint fn_index, BuiltinContext* ctx) {
    if (fn_index >= Builtin.LAST.ordinal) {
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
    print_val.set_lightfunc((void*)(usz)Builtin.PRINT.ordinal);
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

    if (!register_console_methods(console_obj, heap)) return false;

    TVal console_val;
    console_val.set_object(console_obj);
    env::env_declare_nonenum(global_env, console_key, console_val);

    // Register parseInt
    if (!register_simple_builtin(global_env, heap, "parseInt", Builtin.PARSE_INT.ordinal)) return false;

    // Register parseFloat
    if (!register_simple_builtin(global_env, heap, "parseFloat", Builtin.PARSE_FLOAT.ordinal)) return false;

    // Register isNaN
    if (!register_simple_builtin(global_env, heap, "isNaN", Builtin.IS_NAN.ordinal)) return false;

    // Register isFinite
    if (!register_simple_builtin(global_env, heap, "isFinite", Builtin.IS_FINITE.ordinal)) return false;

    // Register eval (ES5 §15.1.2.1)
    if (!register_simple_builtin(global_env, heap, "eval", Builtin.EVAL.ordinal)) return false;

    // Register encodeURI (ES5 §15.1.3.1)
    if (!register_simple_builtin(global_env, heap, "encodeURI", Builtin.ENCODE_URI.ordinal)) return false;

    // Register encodeURIComponent (ES5 §15.1.3.2)
    if (!register_simple_builtin(global_env, heap, "encodeURIComponent", Builtin.ENCODE_URI_COMPONENT.ordinal)) return false;

    // Register decodeURI (ES5 §15.1.3.3)
    if (!register_simple_builtin(global_env, heap, "decodeURI", Builtin.DECODE_URI.ordinal)) return false;

    // Register decodeURIComponent (ES5 §15.1.3.4)
    if (!register_simple_builtin(global_env, heap, "decodeURIComponent", Builtin.DECODE_URI_COMPONENT.ordinal)) return false;

    // Register test262 batch runner helper
    if (!register_simple_builtin(global_env, heap, "__resetGlobals", Builtin.RESET_GLOBALS.ordinal)) return false;

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

    // Register BigInt constructor (plan 056) — after Object.prototype exists.
    if (!register_bigint_constructor(global_env, heap)) return false;

    // Register Math object
    if (!register_math_object(global_env, heap)) return false;

    // Register JSON object (parse, stringify)
    if (!register_json_object(global_env, heap)) return false;

    // Register Reflect object (empty — spec methods added later as needed)
    {
        HObject*? reflect_raw = heap.alloc_object(hobject::ObjClass.REFLECT);
        if (catch err = reflect_raw) return false;
        HObject* reflect = reflect_raw;
        reflect.prototype = heap.object_proto;

        // Set @@toStringTag on Reflect
        HString* tag_key = ensure_tostringtag_symbol(heap);
        if (tag_key != null) {
            TVal tag_tv;
            tag_tv.set_string(builtin_intern_string(heap, "Reflect"));
            reflect.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
        }

        TVal reflect_tv;
        reflect_tv.set_object(null);
        reflect_tv.set_fastint(0);
        reflect_tv.set_object(reflect);
        if (!register_named_value(global_env, heap, "Reflect", reflect_tv)) return false;

        // Register Reflect.ownKeys
        HString* ownkeys_key = builtin_intern_string(heap, "ownKeys");
        TVal ownkeys_tv;
        ownkeys_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_OWNKEYS.ordinal);
        reflect_raw.put_prop(ownkeys_key, ownkeys_tv, hobject::PROP_FLAGS_WC);

        // Register Reflect property-access methods
        HString* get_key = builtin_intern_string(heap, "get");
        TVal get_tv; get_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_GET.ordinal);
        reflect_raw.put_prop(get_key, get_tv, hobject::PROP_FLAGS_WC);

        HString* set_key = builtin_intern_string(heap, "set");
        TVal set_tv; set_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_SET.ordinal);
        reflect_raw.put_prop(set_key, set_tv, hobject::PROP_FLAGS_WC);

        HString* has_key = builtin_intern_string(heap, "has");
        TVal has_tv; has_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_HAS.ordinal);
        reflect_raw.put_prop(has_key, has_tv, hobject::PROP_FLAGS_WC);

        HString* delete_key = builtin_intern_string(heap, "deleteProperty");
        TVal delete_tv; delete_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_DELETE_PROPERTY.ordinal);
        reflect_raw.put_prop(delete_key, delete_tv, hobject::PROP_FLAGS_WC);

        // Register Reflect descriptor / prototype / extensibility methods
        HString* gopd_key = builtin_intern_string(heap, "getOwnPropertyDescriptor");
        TVal gopd_tv; gopd_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_GET_OWN_PROPERTY_DESCRIPTOR.ordinal);
        reflect_raw.put_prop(gopd_key, gopd_tv, hobject::PROP_FLAGS_WC);

        HString* define_key = builtin_intern_string(heap, "defineProperty");
        TVal define_tv; define_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_DEFINE_PROPERTY.ordinal);
        reflect_raw.put_prop(define_key, define_tv, hobject::PROP_FLAGS_WC);

        HString* getproto_key = builtin_intern_string(heap, "getPrototypeOf");
        TVal getproto_tv; getproto_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_GET_PROTOTYPE_OF.ordinal);
        reflect_raw.put_prop(getproto_key, getproto_tv, hobject::PROP_FLAGS_WC);

        HString* setproto_key = builtin_intern_string(heap, "setPrototypeOf");
        TVal setproto_tv; setproto_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_SET_PROTOTYPE_OF.ordinal);
        reflect_raw.put_prop(setproto_key, setproto_tv, hobject::PROP_FLAGS_WC);

        HString* isext_key = builtin_intern_string(heap, "isExtensible");
        TVal isext_tv; isext_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_IS_EXTENSIBLE.ordinal);
        reflect_raw.put_prop(isext_key, isext_tv, hobject::PROP_FLAGS_WC);

        HString* prevent_key = builtin_intern_string(heap, "preventExtensions");
        TVal prevent_tv; prevent_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_PREVENT_EXTENSIONS.ordinal);
        reflect_raw.put_prop(prevent_key, prevent_tv, hobject::PROP_FLAGS_WC);

        // Register Reflect invocation methods
        HString* apply_key = builtin_intern_string(heap, "apply");
        TVal apply_tv; apply_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_APPLY.ordinal);
        reflect_raw.put_prop(apply_key, apply_tv, hobject::PROP_FLAGS_WC);

        HString* construct_key = builtin_intern_string(heap, "construct");
        TVal construct_tv; construct_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_CONSTRUCT.ordinal);
        reflect_raw.put_prop(construct_key, construct_tv, hobject::PROP_FLAGS_WC);
    }

    // Register Error constructors (Error, TypeError, RangeError, ReferenceError, SyntaxError, EvalError)
    if (!register_error_builtins(global_env, heap)) return false;

    // Register Proxy constructor (after Function/Error so prototypes exist)
    if (!register_proxy_constructor(global_env, heap)) return false;

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

    // Register WeakRef constructor and prototype
    if (!register_weakref_constructor(global_env, heap)) return false;

    // Register FinalizationRegistry constructor and prototype
    if (!register_finalization_registry_constructor(global_env, heap)) return false;

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

    // Register the Iterator global constructor, Iterator.prototype's helper
    // methods (map/filter/take/drop/flatMap/reduce/toArray/forEach/some/
    // every/find), %IteratorHelperPrototype%, and
    // %WrapForValidIteratorPrototype% (ES2025 §27.1).
    if (!register_iterator_ctor_and_helpers(global_env, heap)) return false;

    // Register %AsyncFromSyncIteratorPrototype% (ES2018 §27.1.4) — wraps a
    // sync iterator so `for await` can drive it.
    if (!register_async_from_sync_iterator_prototype(heap)) return false;

    // Register TypedArray constructors (Int8Array, Uint8Array, etc.)
    if (!register_typed_array_constructors(global_env, heap)) return false;

    // Register ArrayBuffer constructor and prototype (plan 049 stage 1)
    if (!register_arraybuffer(global_env, heap)) return false;

    // Register DataView constructor and prototype (plan 049 stage 3)
    if (!register_dataview(global_env, heap)) return false;

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
    // ES2025 §27.8.1 %GeneratorPrototype%.[[Prototype]] is %Iterator.prototype%
    // (not Object.prototype directly) now that Iterator Helpers exist — this
    // is what makes `function*(){}().map(...)` etc. work on generators.
    if (heap.generator_proto != null) heap.generator_proto.prototype = heap.iterator_proto;
    if (heap.iterator_proto != null)  heap.iterator_proto.prototype = heap.object_proto;
    if (heap.async_from_sync_iter_proto != null) heap.async_from_sync_iter_proto.prototype = heap.object_proto;

    // Wire constructor functions' [[Prototype]] to Function.prototype.
    // Constructor functions (Object, Number, Function, etc.) are HObjects
    // with ObjClass.FUNCTION whose internal prototype must be Function.prototype
    // so that Function.prototype.isPrototypeOf(Number) and similar work.
    // We look them up in the global environment by name.
    if (heap.function_proto != null) {
        // NativeErrors (TypeError, RangeError, etc.) are excluded here — their [[Prototype]]
        // is the Error constructor HObject (set by register_native_error_ctor), not Function.prototype.
        char[][] ctor_names = { "Object", "Number", "Boolean", "String", "Array", "Function", "Date", "RegExp", "Error", "Map", "Set", "WeakMap", "WeakSet", "Symbol", "Promise", "GeneratorFunction" };
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

    // Wire the global object's [[Prototype]] to Object.prototype (ES2020 §9.3).
    // This is required so that the global object inherits hasOwnProperty, valueOf,
    // toString, etc. from Object.prototype, as mandated by the spec.
    if (heap.object_proto != null) {
        global_env.bindings.prototype = heap.object_proto;
    }

    return true;
}

/// Helper: register all console.* methods on the console object.
fn bool register_console_methods(HObject* console, Heap* heap) {
    if (!register_console_method(console, heap, "log",    Builtin.CONSOLE_LOG.ordinal))    return false;
    if (!register_console_method(console, heap, "info",   Builtin.CONSOLE_INFO.ordinal))   return false;
    if (!register_console_method(console, heap, "debug",  Builtin.CONSOLE_DEBUG.ordinal))  return false;
    if (!register_console_method(console, heap, "trace",  Builtin.CONSOLE_TRACE.ordinal))  return false;
    if (!register_console_method(console, heap, "warn",   Builtin.CONSOLE_WARN.ordinal))   return false;
    if (!register_console_method(console, heap, "error",  Builtin.CONSOLE_ERROR.ordinal))  return false;
    if (!register_console_method(console, heap, "dir",    Builtin.CONSOLE_DIR.ordinal))    return false;
    if (!register_console_method(console, heap, "assert", Builtin.CONSOLE_ASSERT.ordinal)) return false;
    return true;
}

fn bool register_console_method(HObject* console, Heap* heap, char[] name, uint fn_index) {
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
    console.put_prop(key, tv, hobject::PROP_FLAGS_WC);
    return true;
}

fn HObject* alloc_builtin_fn(Heap* heap, uint fn_index, char[] name, int length) {
    HObject*? raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = raw) return null;
    HObject* fobj = raw;
    fobj.flags.callable = true;
    fobj.flags.constructable = false;
    (*fobj.extra_ptr()).func.builtin_fn_index = (int)fn_index;
    fobj.prototype = heap.function_proto;
    set_func_ctor_name_length(fobj, heap, name, length);
    return fobj;
}

/// test262 host globals: __evalScript, __detachArrayBuffer, and the $262
/// object (detachArrayBuffer / evalScript / global) expected by harness
/// files. Installed only by the test harness binaries — never part of the
/// default engine globals.
fn bool register_test262_host(EnvRecord* global_env, Heap* heap) {
    // Every allocated object is declared on the global env (a GC root)
    // before the next allocation — an allocation-triggered GC would
    // otherwise collect the not-yet-reachable objects.
    HString* es_key = builtin_intern_string(heap, "__evalScript");
    HString* d_hidden_key = builtin_intern_string(heap, "__detachArrayBuffer");
    HString* h262_key = builtin_intern_string(heap, "$262");
    HString* d_key = builtin_intern_string(heap, "detachArrayBuffer");
    HString* e_key = builtin_intern_string(heap, "evalScript");
    HString* g_key = builtin_intern_string(heap, "global");
    if (es_key == null || d_hidden_key == null || h262_key == null
        || d_key == null || e_key == null || g_key == null) return false;

    // __evalScript(src) — runs src as a global script so that var/function
    // declarations become non-configurable global properties (unlike eval()
    // which creates a fresh declarative env).
    HObject* es_fn = alloc_builtin_fn(heap, Builtin.EVAL_SCRIPT.ordinal, "evalScript", 1);
    if (es_fn == null) return false;
    TVal es_tv;
    es_tv.set_object(es_fn);
    env::env_declare_nonenum(global_env, es_key, es_tv);

    HObject* detach_fn = alloc_builtin_fn(heap, Builtin.DETACH_ARRAYBUFFER.ordinal, "detachArrayBuffer", 1);
    if (detach_fn == null) return false;
    TVal detach_tv;
    detach_tv.set_object(detach_fn);
    env::env_declare_nonenum(global_env, d_hidden_key, detach_tv);

    HObject*? h262_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = h262_raw) return false;
    HObject* h262 = h262_raw;
    h262.prototype = heap.object_proto;
    TVal h262_tv;
    h262_tv.set_object(h262);
    env::env_declare_nonenum(global_env, h262_key, h262_tv);

    h262.put_prop(d_key, detach_tv, hobject::PROP_FLAGS_WC);
    h262.put_prop(e_key, es_tv, hobject::PROP_FLAGS_WC);
    if (global_env.bindings != null) {
        TVal g_tv;
        g_tv.set_object(global_env.bindings);
        h262.put_prop(g_key, g_tv, hobject::PROP_FLAGS_WC);
    }
    return true;
}
