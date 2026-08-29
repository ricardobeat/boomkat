// Built-in function registry for the boomkat engine.
// Core: shared types, constants, helpers, dispatch table, and registration.
module boomkat::builtins;

import boomkat::types;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hbigint;
import boomkat::hobject;
import boomkat::heap;
import boomkat::env;
import boomkat::compiler;
import boomkat::lexer;
import boomkat::embed::abi;
import boomkat::re_bindings;
import boomkat::vm;
import boomkat::dtoa_bindings;
import boomkat::esm;
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

// No std::math equivalent, these three remain link-time libm externs.
extern fn double math_log1p(double x)         @MathLibc("log1p");
extern fn double math_expm1(double x)         @MathLibc("expm1");
extern fn double math_cbrt(double x)          @MathLibc("cbrt");

// Date/time library externals (link-time resolved via libc)
// The Tm struct mirrors C's struct tm layout exactly.

// ============================================================================
// StrBuf: a growable byte buffer for builtins that assemble a string whose
// final size is not known up front (JSON.stringify, Array.prototype.join's
// toLocaleString sibling, the console formatter).
// ============================================================================
//
// Everything here reports allocation failure through a `bool` return rather
// than truncating. A builtin that silently stops appending would hand back a
// well-formed-looking but corrupt result, which is far worse than an error:
// JSON.stringify did exactly that, returning unterminated JSON as success.

// Bytes held inline before the first heap allocation. Sized so the common
// case (short strings, small objects) never touches the allocator.
const usz STRBUF_INLINE_CAP = 256;

// Pass this by pointer, not by value. A buffer that has not outgrown its
// inline storage points `data` at its own `inline_buf`, so a copy inherits a
// pointer into the source's bytes. Copies of a grown buffer look fine, because
// `data` then points at heap memory, which is what makes the failure depend on
// input size. A copy that cannot be avoided has to rebind `data` afterwards,
// the way the console formatter does when it hands composed rows back.
struct StrBuf {
    Heap*  heap;
    char*  data;      /// Points at `inline_buf` until the first growth.
    usz    len;
    usz    cap;
    char[STRBUF_INLINE_CAP] inline_buf;
}

fn void StrBuf.init(&self, Heap* heap) {
    self.heap = heap;
    self.data = &self.inline_buf[0];
    self.len  = 0;
    self.cap  = STRBUF_INLINE_CAP;
}

// Release the heap block, if the buffer ever outgrew its inline storage.
fn void StrBuf.free(&self) {
    if (self.data != null && self.data != &self.inline_buf[0]) {
        self.heap.free_func(self.heap.heap_udata, self.data);
    }
    self.data = &self.inline_buf[0];
    self.len  = 0;
    self.cap  = STRBUF_INLINE_CAP;
}

// Ensure room for `extra` more bytes. Returns false on allocation failure,
// leaving the buffer usable but unchanged.
fn bool StrBuf.reserve(&self, usz extra) {
    if (self.len + extra <= self.cap) return true;
    usz new_cap = self.cap;
    while (new_cap < self.len + extra) {
        // Overflow guard: a doubling past usz range would wrap to a small
        // capacity and turn this into a heap overflow rather than a failure.
        if (new_cap > (usz)-1 / 2) return false;
        new_cap *= 2;
    }
    char* grown;
    if (self.data == &self.inline_buf[0]) {
        grown = (char*)self.heap.alloc_func(self.heap.heap_udata, new_cap);
        if (grown == null) return false;
        if (self.len > 0) mem::copy(grown, self.data, (sz)self.len);
    } else {
        grown = (char*)self.heap.realloc_func(self.heap.heap_udata, self.data, new_cap);
        if (grown == null) return false;
    }
    self.data = grown;
    self.cap  = new_cap;
    return true;
}

fn bool StrBuf.append_bytes(&self, char[] bytes) {
    if (bytes.len == 0) return true;
    if (!self.reserve(bytes.len)) return false;
    mem::copy(&self.data[self.len], &bytes[0], (sz)bytes.len);
    self.len += bytes.len;
    return true;
}

fn bool StrBuf.append_char(&self, char c) {
    if (!self.reserve(1)) return false;
    self.data[self.len++] = c;
    return true;
}

// The accumulated bytes. Only valid until the next append.
fn char[] StrBuf.bytes(&self) {
    return self.data[:self.len];
}

// ============================================================================
// BuiltinContext, passed to every builtin handler
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
    // Re-dispatch signal: when true, the CALL handler should re-read the
    // function from the callee slot and re-dispatch with modified args.
    // Used by Function.prototype.call/apply.
    bool  needs_re_dispatch;
    // New argument count for re-dispatch (only valid when needs_re_dispatch).
    ushort re_nargs;
    // Global environment pointer (for eval and other scope-sensitive builtins).
    EnvRecord* global_env;
    // When true, the builtin wants to throw an error (used by JSON.parse etc).
    bool  should_throw;
    // The value to throw (only valid when should_throw is true).
    TVal  throw_value;
    // The function object being called (for builtins that need to access their own properties).
    HObject* callee_obj;
    // ES2015 GetPrototypeFromConstructor: the new.target passed to this constructor
    // invocation.  Set to the subclass constructor when called via super(); set to
    // the callee itself for a plain `new Builtin()`.  Null for non-constructor calls.
    HObject* new_target;
    // Host functions only: 1 + the index of this call's scope in
    // Heap.host_scopes, or 0 when this is not a host call.
    //
    // Biased by one so a zero-initialised context is unambiguously "no
    // scope". It must be recorded per call rather than read as "the
    // innermost scope": a host function that calls back into JS which calls
    // another host function leaves a deeper scope on top, and the outer
    // handler must keep addressing its own.
    uint host_scope_slot;
}

alias BuiltinFunc = fn void(BuiltinContext*);

// Stable identifiers for every native builtin function, indexed into
// builtin_dispatch_table via `.ordinal`. Never serialized to bytecode or
// disk, builtin_fn_index is a runtime-only field on the function object
// (HObjectFunction / HObjectProxy), so members may be appended freely
// without a stable numbering scheme.
//
// Each member carries its own metadata as associated enum values:
//  - js_name/js_arity: `.name`/`.length` for LIGHTFUNC values (empty name/-1
//    arity for internal-only builtins with no JS-visible identity).
//  - handler: the native implementation, or null for internal-only ordinals
//    that are never dispatched through builtin_dispatch_table.
// builtin_get_metadata() and builtin_dispatch_table are both generated from
// this single declaration at compile time (see below), adding a builtin
// requires exactly one new line here.
enum Builtin : uint (String js_name, int js_arity, BuiltinFunc handler) {
    PRINT {"print", 1, &builtin_print},
    CONSOLE_LOG {"log", 1, &builtin_console_log},
    CONSOLE_INFO {"info", 1, &builtin_console_info},
    CONSOLE_DEBUG {"debug", 1, &builtin_console_debug},
    CONSOLE_TRACE {"trace", 1, &builtin_console_trace},
    CONSOLE_WARN {"warn", 1, &builtin_console_warn},
    CONSOLE_ERROR {"error", 1, &builtin_console_error},
    CONSOLE_DIR {"dir", 1, &builtin_console_dir},
    CONSOLE_ASSERT {"assert", 1, &builtin_console_assert},
    PARSE_INT {"parseInt", 2, &builtin_parse_int},
    PARSE_FLOAT {"parseFloat", 1, &builtin_parse_float},
    IS_NAN {"isNaN", 1, &builtin_is_nan},
    IS_FINITE {"isFinite", 1, &builtin_is_finite},
    ERROR {"Error", 1, &builtin_error},
    TYPE_ERROR {"TypeError", 1, &builtin_type_error},
    RANGE_ERROR {"RangeError", 1, &builtin_range_error},
    REFERENCE_ERROR {"ReferenceError", 1, &builtin_reference_error},
    SYNTAX_ERROR {"SyntaxError", 1, &builtin_syntax_error},
    EVAL_ERROR {"EvalError", 1, &builtin_eval_error},
    ERROR_PROTO_TOSTRING {"toString", 0, &builtin_error_prototype_to_string},
    BOOLEAN {"Boolean", 1, &builtin_boolean},
    BOOLEAN_PROTO_TOSTRING {"toString", 0, &builtin_boolean_proto_toString},
    BOOLEAN_PROTO_VALUEOF {"valueOf", 0, &builtin_boolean_proto_valueOf},
    STRING {"String", 1, &builtin_string},
    STRING_PROTO_TOSTRING {"toString", 0, &builtin_string_proto_toString},
    STRING_PROTO_VALUEOF {"valueOf", 0, &builtin_string_proto_valueOf},
    NUMBER {"Number", 1, &builtin_number},
    NUMBER_PROTO_TOSTRING {"toString", 0, &builtin_number_proto_toString},
    NUMBER_PROTO_VALUEOF {"valueOf", 0, &builtin_number_proto_valueOf},
    OBJECT {"Object", 1, &builtin_object},
    OBJECT_PROTO_TOSTRING {"toString", 0, &builtin_object_proto_toString},
    OBJECT_PROTO_VALUEOF {"valueOf", 0, &builtin_object_proto_valueOf},
    OBJECT_PROTO___PROTO___GETTER {"get __proto__", 0, &builtin_object_proto___proto___getter},
    OBJECT_PROTO___PROTO___SETTER {"set __proto__", 1, &builtin_object_proto___proto___setter},
    ARRAY {"Array", 0, &builtin_array},
    MATH_ABS {"abs", 1, &builtin_math_abs},
    MATH_FLOOR {"floor", 1, &builtin_math_floor},
    MATH_CEIL {"ceil", 1, &builtin_math_ceil},
    MATH_ROUND {"round", 1, &builtin_math_round},
    MATH_MAX {"max", 2, &builtin_math_max},
    MATH_MIN {"min", 2, &builtin_math_min},
    MATH_POW {"pow", 2, &builtin_math_pow},
    MATH_SQRT {"sqrt", 1, &builtin_math_sqrt},
    MATH_EXP {"exp", 1, &builtin_math_exp},
    MATH_LOG {"log", 1, &builtin_math_log},
    MATH_SIN {"sin", 1, &builtin_math_sin},
    MATH_COS {"cos", 1, &builtin_math_cos},
    MATH_TAN {"tan", 1, &builtin_math_tan},
    MATH_RANDOM {"random", 0, &builtin_math_random},
    STRING_PROTO_CHARAT {"charAt", 1, &builtin_string_proto_charAt},
    STRING_PROTO_CHARCODEAT {"charCodeAt", 1, &builtin_string_proto_charCodeAt},
    STRING_PROTO_INDEXOF {"indexOf", 1, &builtin_string_proto_indexOf},
    STRING_PROTO_SLICE {"slice", 2, &builtin_string_proto_slice},
    STRING_PROTO_SUBSTRING {"substring", 2, &builtin_string_proto_substring},
    STRING_PROTO_SUBSTR {"substr", 2, &builtin_string_proto_substr},
    STRING_PROTO_TOUPPERCASE {"toUpperCase", 0, &builtin_string_proto_toUpperCase},
    STRING_PROTO_TOLOWERCASE {"toLowerCase", 0, &builtin_string_proto_toLowerCase},
    STRING_PROTO_TRIM {"trim", 0, &builtin_string_proto_trim},
    STRING_PROTO_SPLIT {"split", 2, &builtin_string_proto_split},
    STRING_PROTO_CONCAT {"concat", 1, &builtin_string_proto_concat},
    STRING_PROTO_REPLACE {"replace", 2, &builtin_string_proto_replace},
    ARRAY_PROTO_TOSTRING {"toString", 0, &builtin_array_proto_toString},
    ARRAY_PROTO_JOIN {"join", 1, &builtin_array_proto_join},
    ARRAY_PROTO_TOLOCALESTRING {"toLocaleString", 0, &builtin_array_proto_toLocaleString},
    ARRAY_PROTO_POP {"pop", 0, &builtin_array_proto_pop},
    ARRAY_PROTO_PUSH {"push", 1, &builtin_array_proto_push},
    ARRAY_PROTO_REVERSE {"reverse", 0, &builtin_array_proto_reverse},
    ARRAY_PROTO_SHIFT {"shift", 0, &builtin_array_proto_shift},
    ARRAY_PROTO_SLICE {"slice", 2, &builtin_array_proto_slice},
    ARRAY_PROTO_SORT {"sort", 1, &builtin_array_proto_sort},
    ARRAY_PROTO_SPLICE {"splice", 2, &builtin_array_proto_splice},
    ARRAY_PROTO_UNSHIFT {"unshift", 1, &builtin_array_proto_unshift},
    ARRAY_PROTO_INDEXOF {"indexOf", 1, &builtin_array_proto_indexOf},
    ARRAY_PROTO_LASTINDEXOF {"lastIndexOf", 1, &builtin_array_proto_lastIndexOf},
    ARRAY_PROTO_CONCAT {"concat", 1, &builtin_array_proto_concat},
    NUMBER_PROTO_TOFIXED {"toFixed", 1, &builtin_number_proto_toFixed},
    NUMBER_PROTO_TOEXPONENTIAL {"toExponential", 1, &builtin_number_proto_toExponential},
    NUMBER_PROTO_TOPRECISION {"toPrecision", 1, &builtin_number_proto_toPrecision},
    FUNCTION_PROTO_CALL {"call", 1, &builtin_function_proto_call},
    FUNCTION_PROTO_APPLY {"apply", 2, &builtin_function_proto_apply},
    FUNCTION_PROTO_BIND {"bind", 1, &builtin_function_proto_bind},
    BOUND_CALL {"bind", 1, &builtin_bound_call},
    EVAL {"eval", 1, &builtin_eval},
    JSON_PARSE {"parse", 2, &builtin_json_parse},
    JSON_STRINGIFY {"stringify", 3, &builtin_json_stringify},
    DATE {"Date", 7, &builtin_date},
    DATE_NOW {"now", 0, &builtin_date_now},
    DATE_UTC {"UTC", 7, &builtin_date_utc},
    DATE_PARSE {"parse", 1, &builtin_date_parse},
    DATE_PROTO_TOSTRING {"toString", 0, &builtin_date_proto_toString},
    DATE_PROTO_TOJSON {"toJSON", 1, &builtin_date_proto_toJSON},
    DATE_PROTO_VALUEOF {"valueOf", 0, &builtin_date_proto_valueOf},
    DATE_PROTO_GETTIME {"getTime", 0, &builtin_date_proto_getTime},
    DATE_PROTO_GETFULLYEAR {"getFullYear", 0, &builtin_date_proto_getFullYear},
    DATE_PROTO_GETMONTH {"getMonth", 0, &builtin_date_proto_getMonth},
    DATE_PROTO_GETDATE {"getDate", 0, &builtin_date_proto_getDate},
    DATE_PROTO_GETDAY {"getDay", 0, &builtin_date_proto_getDay},
    DATE_PROTO_GETHOURS {"getHours", 0, &builtin_date_proto_getHours},
    DATE_PROTO_GETMINUTES {"getMinutes", 0, &builtin_date_proto_getMinutes},
    DATE_PROTO_GETSECONDS {"getSeconds", 0, &builtin_date_proto_getSeconds},
    DATE_PROTO_GETMILLISECONDS {"getMilliseconds", 0, &builtin_date_proto_getMilliseconds},
    DATE_PROTO_GETTIMEZONEOFFSET {"", -1, &builtin_date_proto_getTimezoneOffset},
    FUNCTION {"Function", 1, &builtin_function},
    RESET_GLOBALS {"", -1, &builtin_reset_globals},
    REGEXP {"RegExp", 2, &builtin_regexp},
    REGEXP_PROTO_TEST {"test", 1, &builtin_regexp_proto_test},
    REGEXP_PROTO_EXEC {"exec", 1, &builtin_regexp_proto_exec},
    REGEXP_PROTO_TOSTRING {"toString", 0, &builtin_regexp_proto_toString},
    OBJECT_PROTO_HASOWNPROPERTY {"hasOwnProperty", 1, &builtin_object_proto_hasOwnProperty},
    OBJECT_PROTO_PROPERTYISENUMERABLE {"propertyIsEnumerable", 1, &builtin_object_proto_propertyIsEnumerable},
    OBJECT_PROTO_ISPROTOTYPEOF {"isPrototypeOf", 1, &builtin_object_proto_isPrototypeOf},
    OBJECT_PROTO_DEFINEGETTER {"__defineGetter__", 2, &builtin_object_proto_defineGetter},
    OBJECT_PROTO_DEFINESETTER {"__defineSetter__", 2, &builtin_object_proto_defineSetter},
    OBJECT_PROTO_LOOKUPGETTER {"__lookupGetter__", 1, &builtin_object_proto_lookupGetter},
    OBJECT_PROTO_LOOKUPSETTER {"__lookupSetter__", 1, &builtin_object_proto_lookupSetter},
    OBJECT_PROTO_TOLOCALESTRING {"toLocaleString", 0, &builtin_object_proto_toLocaleString},
    DATE_PROTO_TOLOCALESTRING {"toLocaleString", 0, &builtin_date_proto_toLocaleString},
    DATE_PROTO_TOLOCALEDATESTRING {"toLocaleDateString", 0, &builtin_date_proto_toLocaleDateString},
    DATE_PROTO_TOLOCALETIMESTRING {"toLocaleTimeString", 0, &builtin_date_proto_toLocaleTimeString},
    PROMISE_RESOLVE_CALLBACK {"", 1, &builtin_promise_resolve_callback},
    PROMISE_REJECT_CALLBACK {"", 1, &builtin_promise_reject_callback},
    PROMISE_ALL_RESOLVE_ELEMENT {"", -1, &builtin_promise_all_resolve_element},
    PROMISE_ALL_REJECT_ELEMENT {"", -1, &builtin_promise_all_reject_element},
    PROMISE_ALLSETTLED_RESOLVE_ELEMENT {"", -1, &builtin_promise_allsettled_resolve_element},
    PROMISE_ALLSETTLED_REJECT_ELEMENT {"", -1, &builtin_promise_allsettled_reject_element},
    PROMISE_ANY_RESOLVE_ELEMENT {"", -1, &builtin_promise_any_resolve_element},
    PROMISE_ANY_REJECT_ELEMENT {"", -1, &builtin_promise_any_reject_element},
    ARRAY_ITERATOR_NEXT {"next", 0, &builtin_array_iterator_next},
    STRING_ITERATOR_NEXT {"next", 0, &builtin_string_iterator_next},
    STRING_PROTO_SYMBOL_ITER {"[Symbol.iterator]", 0, &builtin_string_proto_symbol_iter},
    ARRAY_PROTO_KEYS {"keys", 0, &builtin_array_proto_keys},
    ARRAY_PROTO_VALUES {"values", 0, &builtin_array_proto_values},
    ARRAY_PROTO_ENTRIES {"entries", 0, &builtin_array_proto_entries},
    OBJECT_FROMENTRIES {"fromEntries", 1, &builtin_object_fromEntries},
    OBJECT_GROUPBY {"groupBy", 2, &builtin_object_groupBy},
    MAP_GROUPBY {"groupBy", 2, &builtin_map_groupBy},
    REGEXP_PROTO_GET_FLAGS {"", -1, &builtin_regexp_proto_get_flags},
    REGEXP_PROTO_GET_SOURCE {"", -1, &builtin_regexp_proto_get_source},
    REGEXP_PROTO_GET_GLOBAL {"", -1, &builtin_regexp_proto_get_global},
    REGEXP_PROTO_GET_IGNORECASE {"", -1, &builtin_regexp_proto_get_ignoreCase},
    REGEXP_PROTO_GET_MULTILINE {"", -1, &builtin_regexp_proto_get_multiline},
    REGEXP_PROTO_GET_DOTALL {"", -1, &builtin_regexp_proto_get_dotAll},
    REGEXP_PROTO_GET_STICKY {"", -1, &builtin_regexp_proto_get_sticky},
    REGEXP_PROTO_GET_UNICODE {"", -1, &builtin_regexp_proto_get_unicode},
    ARRAY_FROM {"from", 1, &builtin_array_from},
    ITERATOR_PROTO_SYMBOL_ITER {"", -1, &builtin_iterator_proto_symbol_iter},
    MAP_ITERATOR_NEXT {"", -1, &builtin_map_iterator_next},
    SET_ITERATOR_NEXT {"", -1, &builtin_set_iterator_next},
    ARRAY_PROTO_FOREACH {"forEach", 1, &builtin_array_proto_forEach},
    ARRAY_PROTO_MAP {"map", 1, &builtin_array_proto_map},
    ARRAY_PROTO_FILTER {"filter", 1, &builtin_array_proto_filter},
    ARRAY_PROTO_EVERY {"every", 1, &builtin_array_proto_every},
    ARRAY_PROTO_SOME {"some", 1, &builtin_array_proto_some},
    ARRAY_PROTO_REDUCE {"reduce", 1, &builtin_array_proto_reduce},
    ARRAY_PROTO_REDUCERIGHT {"reduceRight", 1, &builtin_array_proto_reduceRight},
    STRING_PROTO_TOLOCALELOWERCASE {"toLocaleLowerCase", 0, &builtin_string_proto_toLocaleLowerCase},
    STRING_PROTO_TOLOCALEUPPERCASE {"toLocaleUpperCase", 0, &builtin_string_proto_toLocaleUpperCase},
    STRING_PROTO_LOCALECOMPARE {"localeCompare", 1, &builtin_string_proto_localeCompare},
    ARRAY_PROTO_FINDLAST {"findLast", 1, &builtin_array_proto_findLast},
    ARRAY_PROTO_FINDLASTINDEX {"findLastIndex", 1, &builtin_array_proto_findLastIndex},
    FUNCTION_PROTO_TOSTRING {"toString", 0, &builtin_function_proto_toString},
    INT8ARRAY {"", -1, &builtin_int8array},
    UINT8ARRAY {"", -1, &builtin_uint8array},
    UINT8CLAMPEDARRAY {"", -1, &builtin_uint8clampedarray},
    INT16ARRAY {"", -1, &builtin_int16array},
    UINT16ARRAY {"", -1, &builtin_uint16array},
    INT32ARRAY {"", -1, &builtin_int32array},
    UINT32ARRAY {"", -1, &builtin_uint32array},
    FLOAT16ARRAY {"", -1, &builtin_float16array},
    FLOAT32ARRAY {"", -1, &builtin_float32array},
    FLOAT64ARRAY {"", -1, &builtin_float64array},
    BIGINT64ARRAY {"", -1, &builtin_bigint64array},
    BIGUINT64ARRAY {"", -1, &builtin_biguint64array},
    REGEXP_PROTO_SYMBOL_MATCH {"[Symbol.match]", 1, &builtin_regexp_proto_symbol_match},
    REGEXP_PROTO_SYMBOL_SEARCH {"[Symbol.search]", 1, &builtin_regexp_proto_symbol_search},
    REGEXP_PROTO_SYMBOL_REPLACE {"[Symbol.replace]", 2, &builtin_regexp_proto_symbol_replace},
    REGEXP_PROTO_SYMBOL_SPLIT {"[Symbol.split]", 2, &builtin_regexp_proto_symbol_split},
    REGEXP_PROTO_SYMBOL_MATCHALL {"[Symbol.matchAll]", 1, &builtin_regexp_proto_symbol_matchAll},
    REGEXP_STRING_ITERATOR_NEXT {"next", 0, &builtin_regexp_string_iterator_next},
    ASYNC_RESUME {"", -1, &builtin_async_resume},
    ASYNC_REJECT {"", -1, &builtin_async_reject},
    PROMISE_SYNTHETIC_EXECUTOR {"", -1, &builtin_promise_synthetic_executor},
    REGEXP_PROTO_GET_HASINDICES {"", -1, &builtin_regexp_proto_get_hasIndices},
    REGEXP_PROTO_GET_UNICODESETS {"", -1, &builtin_regexp_proto_get_unicodeSets},
    ARRAYBUFFER {"ArrayBuffer", 1, &builtin_arraybuffer},
    ARRAYBUFFER_ISVIEW {"isView", 1, &builtin_arraybuffer_isview},
    ARRAYBUFFER_PROTO_BYTELENGTH_GET {"", -1, &builtin_arraybuffer_proto_bytelength_get},
    ARRAYBUFFER_PROTO_SLICE {"slice", 2, &builtin_arraybuffer_proto_slice},
    ARRAYBUFFER_PROTO_DETACHED_GET {"", -1, &builtin_arraybuffer_proto_detached_get},
    ARRAYBUFFER_SPECIES_GET {"", -1, &builtin_arraybuffer_species_get},
    DETACH_ARRAYBUFFER {"", -1, &builtin_detach_arraybuffer},
    TYPEDARRAY_PROTO_LENGTH_GET {"", -1, &builtin_typedarray_proto_length_get},
    TYPEDARRAY_PROTO_BYTELENGTH_GET {"", -1, &builtin_typedarray_proto_bytelength_get},
    TYPEDARRAY_PROTO_BYTEOFFSET_GET {"", -1, &builtin_typedarray_proto_byteoffset_get},
    TYPEDARRAY_PROTO_BUFFER_GET {"", -1, &builtin_typedarray_proto_buffer_get},
    TYPEDARRAY_PROTO_TOSTRINGTAG_GET {"", -1, &builtin_typedarray_proto_tostringtag_get},
    DATAVIEW {"DataView", 1, &builtin_dataview},
    DATAVIEW_PROTO_BUFFER_GET {"", -1, &builtin_dataview_proto_buffer_get},
    DATAVIEW_PROTO_BYTELENGTH_GET {"", -1, &builtin_dataview_proto_bytelength_get},
    DATAVIEW_PROTO_BYTEOFFSET_GET {"", -1, &builtin_dataview_proto_byteoffset_get},
    DATAVIEW_GET_INT8 {"getInt8", 1, &builtin_dataview_get_int8},
    DATAVIEW_GET_UINT8 {"getUint8", 1, &builtin_dataview_get_uint8},
    DATAVIEW_GET_INT16 {"getInt16", 1, &builtin_dataview_get_int16},
    DATAVIEW_GET_UINT16 {"getUint16", 1, &builtin_dataview_get_uint16},
    DATAVIEW_GET_INT32 {"getInt32", 1, &builtin_dataview_get_int32},
    DATAVIEW_GET_UINT32 {"getUint32", 1, &builtin_dataview_get_uint32},
    DATAVIEW_GET_FLOAT16 {"getFloat16", 1, &builtin_dataview_get_float16},
    DATAVIEW_GET_FLOAT32 {"getFloat32", 1, &builtin_dataview_get_float32},
    DATAVIEW_GET_FLOAT64 {"getFloat64", 1, &builtin_dataview_get_float64},
    DATAVIEW_SET_INT8 {"setInt8", 2, &builtin_dataview_set_int8},
    DATAVIEW_SET_UINT8 {"setUint8", 2, &builtin_dataview_set_uint8},
    DATAVIEW_SET_INT16 {"setInt16", 2, &builtin_dataview_set_int16},
    DATAVIEW_SET_UINT16 {"setUint16", 2, &builtin_dataview_set_uint16},
    DATAVIEW_SET_INT32 {"setInt32", 2, &builtin_dataview_set_int32},
    DATAVIEW_SET_UINT32 {"setUint32", 2, &builtin_dataview_set_uint32},
    DATAVIEW_SET_FLOAT16 {"setFloat16", 2, &builtin_dataview_set_float16},
    DATAVIEW_SET_FLOAT32 {"setFloat32", 2, &builtin_dataview_set_float32},
    DATAVIEW_SET_FLOAT64 {"setFloat64", 2, &builtin_dataview_set_float64},
    TA_PROTO_VALUES {"values", 0, &builtin_ta_proto_values},
    TA_PROTO_KEYS {"keys", 0, &builtin_ta_proto_keys},
    TA_PROTO_ENTRIES {"entries", 0, &builtin_ta_proto_entries},
    TA_PROTO_SET {"set", 1, &builtin_ta_proto_set},
    TA_PROTO_SUBARRAY {"subarray", 2, &builtin_ta_proto_subarray},
    TA_PROTO_FILL {"fill", 1, &builtin_ta_proto_fill},
    TA_PROTO_COPYWITHIN {"copyWithin", 2, &builtin_ta_proto_copyWithin},
    TA_PROTO_SLICE {"slice", 2, &builtin_ta_proto_slice},
    TA_PROTO_INDEX_OF {"indexOf", 1, &builtin_ta_proto_indexOf},
    TA_PROTO_LAST_INDEX_OF {"lastIndexOf", 1, &builtin_ta_proto_lastIndexOf},
    TA_PROTO_INCLUDES {"includes", 1, &builtin_ta_proto_includes},
    TA_PROTO_JOIN {"join", 1, &builtin_ta_proto_join},
    TA_PROTO_FOR_EACH {"forEach", 1, &builtin_ta_proto_forEach},
    TA_PROTO_EVERY {"every", 1, &builtin_ta_proto_every},
    TA_PROTO_SOME {"some", 1, &builtin_ta_proto_some},
    TA_PROTO_REDUCE {"reduce", 1, &builtin_ta_proto_reduce},
    TA_PROTO_REDUCE_RIGHT {"reduceRight", 1, &builtin_ta_proto_reduceRight},
    TA_PROTO_MAP {"map", 1, &builtin_ta_proto_map},
    TA_PROTO_FILTER {"filter", 1, &builtin_ta_proto_filter},
    TA_PROTO_FIND {"find", 1, &builtin_ta_proto_find},
    TA_PROTO_FIND_INDEX {"findIndex", 1, &builtin_ta_proto_findIndex},
    TA_PROTO_FIND_LAST {"findLast", 1, &builtin_ta_proto_findLast},
    TA_PROTO_FIND_LAST_INDEX {"findLastIndex", 1, &builtin_ta_proto_findLastIndex},
    TA_PROTO_REVERSE {"reverse", 0, &builtin_ta_proto_reverse},
    TA_PROTO_TO_REVERSED {"toReversed", 0, &builtin_ta_proto_toReversed},
    TA_PROTO_AT {"at", 1, &builtin_ta_proto_at},
    TA_PROTO_SORT {"sort", 1, &builtin_ta_proto_sort},
    TA_PROTO_TO_SORTED {"toSorted", 1, &builtin_ta_proto_toSorted},
    TA_PROTO_WITH {"with", 2, &builtin_ta_proto_with},
    TA_PROTO_TO_STRING {"toString", 0, &builtin_ta_proto_toString},
    TA_PROTO_TO_LOCALE_STRING {"toLocaleString", 0, &builtin_ta_proto_toLocaleString},
    TA_OF {"of", 0, &builtin_ta_of},
    TA_FROM {"from", 1, &builtin_ta_from},
    // Uint8Array base64/hex (tc39 proposal-arraybuffer-base64)
    UINT8ARRAY_FROM_BASE64 {"fromBase64", 1, &builtin_uint8array_from_base64},
    UINT8ARRAY_FROM_HEX {"fromHex", 1, &builtin_uint8array_from_hex},
    UINT8ARRAY_PROTO_TO_BASE64 {"toBase64", 0, &builtin_uint8array_proto_to_base64},
    UINT8ARRAY_PROTO_TO_HEX {"toHex", 0, &builtin_uint8array_proto_to_hex},
    UINT8ARRAY_PROTO_SET_FROM_BASE64 {"setFromBase64", 1, &builtin_uint8array_proto_set_from_base64},
    UINT8ARRAY_PROTO_SET_FROM_HEX {"setFromHex", 1, &builtin_uint8array_proto_set_from_hex},
    TYPEDARRAY_INTRINSIC {"TypedArray", 0, &builtin_typedarray_intrinsic},
    FUNCTION_PROTO_HASINSTANCE {"[Symbol.hasInstance]", 1, &builtin_function_proto_hasInstance},
    DATE_PROTO_TOPRIMITIVE {"[Symbol.toPrimitive]", 1, &builtin_date_proto_toPrimitive},
    OBJECT_GETOWNPROPERTYDESCRIPTORS {"getOwnPropertyDescriptors", 1, &builtin_object_getOwnPropertyDescriptors},
    PROMISE_SPECIES_GETTER {"", -1, &builtin_promise_species_getter},
    ASYNC_FUNCTION {"", -1, &builtin_async_function},
    PROXY {"Proxy", 2, &builtin_proxy},
    PROXY_REVOCABLE {"revocable", 2, &builtin_proxy_revocable},
    PROXY_REVOKE {"", 0, &builtin_proxy_revoke},
    PROXY_CALL {"", -1, &builtin_proxy_call},
    TA_SPECIES_GET {"", -1, &builtin_ta_species_get},
    EVAL_SCRIPT {"", -1, &builtin_eval_script},
    REGEXP_SPECIES_GETTER {"", -1, &builtin_regexp_species_getter},
    MODULE_BINDING_GETTER {"", -1, &builtin_module_binding_getter},
    PROMISE_RESOLVE_THENABLE_JOB {"", -1, &builtin_promise_resolve_thenable_job},
    DYNAMIC_IMPORT_JOB {"", -1, &esm::builtin_dynamic_import_job},
    MODULE_SETTLED_FULFILLED {"", -1, &esm::builtin_module_settled_fulfilled},
    MODULE_SETTLED_REJECTED {"", -1, &esm::builtin_module_settled_rejected},
    PROMISE_THEN_FINALLY {"", -1, &builtin_promise_then_finally},
    PROMISE_CATCH_FINALLY {"", -1, &builtin_promise_catch_finally},
    ARRAY_SPECIES_GETTER {"", -1, &builtin_array_species_getter},
    PROMISE_IDENTITY {"", -1, &builtin_promise_identity},
    REFLECT_GET {"get", 2, &builtin_reflect_get},
    REFLECT_SET {"set", 3, &builtin_reflect_set},
    REFLECT_HAS {"has", 2, &builtin_reflect_has},
    REFLECT_DELETE_PROPERTY {"deleteProperty", 2, &builtin_reflect_deleteProperty},
    REFLECT_GET_OWN_PROPERTY_DESCRIPTOR {"getOwnPropertyDescriptor", 2, &builtin_reflect_getOwnPropertyDescriptor},
    REFLECT_DEFINE_PROPERTY {"defineProperty", 3, &builtin_reflect_defineProperty},
    REFLECT_GET_PROTOTYPE_OF {"getPrototypeOf", 1, &builtin_reflect_getPrototypeOf},
    REFLECT_SET_PROTOTYPE_OF {"setPrototypeOf", 2, &builtin_reflect_setPrototypeOf},
    REFLECT_IS_EXTENSIBLE {"isExtensible", 1, &builtin_reflect_isExtensible},
    REFLECT_PREVENT_EXTENSIONS {"preventExtensions", 1, &builtin_reflect_preventExtensions},
    REFLECT_APPLY {"apply", 3, &builtin_reflect_apply},
    REFLECT_CONSTRUCT {"construct", 2, &builtin_reflect_construct},
    PROMISE_THROWER {"", -1, &builtin_promise_thrower},
    MAP_SPECIES_GETTER {"[Symbol.species]", 0, &builtin_map_species_getter},
    SET_SPECIES_GETTER {"[Symbol.species]", 0, &builtin_set_species_getter},
    DATAVIEW_GET_BIGINT64 {"getBigInt64", 1, &builtin_dataview_get_bigint64},
    DATAVIEW_GET_BIGUINT64 {"getBigUint64", 1, &builtin_dataview_get_biguint64},
    DATAVIEW_SET_BIGINT64 {"setBigInt64", 2, &builtin_dataview_set_bigint64},
    DATAVIEW_SET_BIGUINT64 {"setBigUint64", 2, &builtin_dataview_set_biguint64},
    FUNCTION_PROTO_RESTRICTED_GETTER {"", -1, &builtin_function_proto_restricted_getter},
    FUNCTION_PROTO_RESTRICTED_SETTER {"", -1, &builtin_function_proto_restricted_setter},
    MAP {"Map", 0, &builtin_map},
    MAP_PROTO_SET {"set", 2, &builtin_map_proto_set},
    MAP_PROTO_GET {"get", 1, &builtin_map_proto_get},
    MAP_PROTO_HAS {"has", 1, &builtin_map_proto_has},
    MAP_PROTO_DELETE {"delete", 1, &builtin_map_proto_delete},
    MAP_PROTO_CLEAR {"clear", 0, &builtin_map_proto_clear},
    MAP_PROTO_KEYS {"keys", 0, &builtin_map_proto_keys},
    MAP_PROTO_VALUES {"values", 0, &builtin_map_proto_values},
    MAP_PROTO_ENTRIES {"entries", 0, &builtin_map_proto_entries},
    MAP_PROTO_FOREACH {"forEach", 1, &builtin_map_proto_forEach},
    MAP_PROTO_GETORINSERT {"getOrInsert", 2, &builtin_map_proto_getOrInsert},
    MAP_PROTO_GETORINSERTCOMPUTED {"getOrInsertComputed", 2, &builtin_map_proto_getOrInsertComputed},
    SET {"Set", 0, &builtin_set},
    SET_PROTO_ADD {"add", 1, &builtin_set_proto_add},
    SET_PROTO_HAS {"has", 1, &builtin_set_proto_has},
    SET_PROTO_DELETE {"delete", 1, &builtin_set_proto_delete},
    SET_PROTO_CLEAR {"clear", 0, &builtin_set_proto_clear},
    SET_PROTO_VALUES {"values", 0, &builtin_set_proto_values},
    SET_PROTO_ENTRIES {"entries", 0, &builtin_set_proto_entries},
    SET_PROTO_FOREACH {"forEach", 1, &builtin_set_proto_forEach},
    WEAKMAP {"WeakMap", 0, &builtin_weakmap},
    WEAKMAP_PROTO_SET {"set", 2, &builtin_weakmap_proto_set},
    WEAKMAP_PROTO_GET {"get", 1, &builtin_weakmap_proto_get},
    WEAKMAP_PROTO_HAS {"has", 1, &builtin_weakmap_proto_has},
    WEAKMAP_PROTO_DELETE {"delete", 1, &builtin_weakmap_proto_delete},
    WEAKMAP_PROTO_GETORINSERT {"getOrInsert", 2, &builtin_weakmap_proto_getOrInsert},
    WEAKMAP_PROTO_GETORINSERTCOMPUTED {"getOrInsertComputed", 2, &builtin_weakmap_proto_getOrInsertComputed},
    WEAKSET {"WeakSet", 0, &builtin_weakset},
    WEAKSET_PROTO_ADD {"add", 1, &builtin_weakset_proto_add},
    WEAKSET_PROTO_HAS {"has", 1, &builtin_weakset_proto_has},
    WEAKSET_PROTO_DELETE {"delete", 1, &builtin_weakset_proto_delete},
    WEAKREF {"WeakRef", 1, &builtin_weakref},
    WEAKREF_PROTO_DEREF {"deref", 0, &builtin_weakref_proto_deref},
    FINALIZATION_REGISTRY {"FinalizationRegistry", 1, &builtin_finalization_registry},
    FINALIZATION_REGISTRY_PROTO_REGISTER {"register", 2, &builtin_finalization_registry_proto_register},
    FINALIZATION_REGISTRY_PROTO_UNREGISTER {"unregister", 1, &builtin_finalization_registry_proto_unregister},
    SYMBOL {"Symbol", 1, &builtin_symbol},
    SYMBOL_FOR {"for", 1, &builtin_symbol_for},
    SYMBOL_KEYFOR {"keyFor", 1, &builtin_symbol_keyfor},
    SYMBOL_PROTO_TOSTRING {"toString", 0, &builtin_symbol_proto_toString},
    SYMBOL_PROTO_VALUEOF {"valueOf", 0, &builtin_symbol_proto_valueOf},
    SYMBOL_PROTO_TOPRIMITIVE {"", -1, &builtin_symbol_proto_toprimitive},
    SYMBOL_PROTO_DESCRIPTION_GET {"", -1, &builtin_symbol_proto_description_get},
    MAP_PROTO_SIZE_GET {"", -1, &builtin_map_proto_size_get},
    SET_PROTO_SIZE_GET {"", -1, &builtin_set_proto_size_get},
    PROMISE {"Promise", 1, &builtin_promise},
    PROMISE_PROTO_THEN {"then", 2, &builtin_promise_proto_then},
    PROMISE_PROTO_CATCH {"catch", 1, &builtin_promise_proto_catch},
    PROMISE_PROTO_FINALLY {"finally", 1, &builtin_promise_proto_finally},
    PROMISE_RESOLVE {"resolve", 1, &builtin_promise_resolve},
    PROMISE_REJECT {"reject", 1, &builtin_promise_reject},
    PROMISE_ALL {"all", 1, &builtin_promise_all},
    PROMISE_RACE {"race", 1, &builtin_promise_race},
    PROMISE_ALLSETTLED {"allSettled", 1, &builtin_promise_allsettled},
    PROMISE_ANY {"any", 1, &builtin_promise_any},
    AGGREGATE_ERROR {"AggregateError", 2, &builtin_aggregate_error},
    GENERATOR_FUNCTION {"Function", 1, &builtin_generator_function},
    GENERATOR_PROTO_NEXT {"next", 1, &builtin_generator_proto_next},
    GENERATOR_PROTO_THROW {"throw", 1, &builtin_generator_proto_throw},
    GENERATOR_PROTO_RETURN {"return", 1, &builtin_generator_proto_return},
    OBJECT_KEYS {"keys", 1, &builtin_object_keys},
    OBJECT_GETPROTOTYPEOF {"getPrototypeOf", 1, &builtin_object_getPrototypeOf},
    OBJECT_ISEXTENSIBLE {"isExtensible", 1, &builtin_object_isExtensible},
    OBJECT_PREVENTEXTENSIONS {"preventExtensions", 1, &builtin_object_preventExtensions},
    OBJECT_GETOWNPROPERTYDESCRIPTOR {"getOwnPropertyDescriptor", 2, &builtin_object_getOwnPropertyDescriptor},
    OBJECT_DEFINEPROPERTY {"defineProperty", 3, &builtin_object_defineProperty},
    OBJECT_GETOWNPROPERTYNAMES {"getOwnPropertyNames", 1, &builtin_object_getOwnPropertyNames},
    OBJECT_GETOWNPROPERTYSYMBOLS {"getOwnPropertySymbols", 1, &builtin_object_getOwnPropertySymbols},
    OBJECT_DEFINEPROPERTIES {"defineProperties", 2, &builtin_object_defineProperties},
    OBJECT_CREATE {"create", 2, &builtin_object_create},
    OBJECT_SEAL {"seal", 1, &builtin_object_seal},
    OBJECT_FREEZE {"freeze", 1, &builtin_object_freeze},
    OBJECT_ISSEALED {"isSealed", 1, &builtin_object_isSealed},
    OBJECT_ISFROZEN {"isFrozen", 1, &builtin_object_isFrozen},
    OBJECT_ENTRIES {"entries", 1, &builtin_object_entries},
    OBJECT_VALUES {"values", 1, &builtin_object_values},
    OBJECT_ASSIGN {"assign", 2, &builtin_object_assign},
    NUMBER_ISNAN {"isNaN", 1, &builtin_number_isNaN},
    NUMBER_ISFINITE {"isFinite", 1, &builtin_number_isFinite},
    NUMBER_ISINTEGER {"isInteger", 1, &builtin_number_isInteger},
    NUMBER_ISSAFEINTEGER {"isSafeInteger", 1, &builtin_number_isSafeInteger},
    MATH_ACOS {"acos", 1, &builtin_math_acos},
    MATH_ASIN {"asin", 1, &builtin_math_asin},
    MATH_ATAN {"atan", 1, &builtin_math_atan},
    MATH_ATAN2 {"atan2", 2, &builtin_math_atan2},
    MATH_COSH {"cosh", 1, &builtin_math_cosh},
    MATH_SINH {"sinh", 1, &builtin_math_sinh},
    MATH_TANH {"tanh", 1, &builtin_math_tanh},
    MATH_ACOSH {"acosh", 1, &builtin_math_acosh},
    MATH_ASINH {"asinh", 1, &builtin_math_asinh},
    MATH_ATANH {"atanh", 1, &builtin_math_atanh},
    MATH_LOG2 {"log2", 1, &builtin_math_log2},
    MATH_LOG10 {"log10", 1, &builtin_math_log10},
    MATH_LOG1P {"log1p", 1, &builtin_math_log1p},
    MATH_EXPM1 {"expm1", 1, &builtin_math_expm1},
    MATH_CBRT {"cbrt", 1, &builtin_math_cbrt},
    MATH_HYPOT {"hypot", 2, &builtin_math_hypot},
    MATH_TRUNC {"trunc", 1, &builtin_math_trunc},
    MATH_SIGN {"sign", 1, &builtin_math_sign},
    MATH_FROUND {"fround", 1, &builtin_math_fround},
    MATH_F16ROUND {"f16round", 1, &builtin_math_f16round},
    MATH_CLZ32 {"clz32", 1, &builtin_math_clz32},
    MATH_IMUL {"imul", 2, &builtin_math_imul},
    MATH_SUMPRECISE {"sumPrecise", 1, &builtin_math_sumPrecise},
    ARRAY_ISARRAY {"isArray", 1, &builtin_array_isArray},
    STRING_FROMCHARCODE {"fromCharCode", 1, &builtin_string_fromcharcode},
    OBJECT_IS {"is", 2, &builtin_object_is},
    OBJECT_HASOWN {"hasOwn", 2, &builtin_object_hasOwn},
    OBJECT_SETPROTOTYPEOF {"setPrototypeOf", 2, &builtin_object_setPrototypeOf},
    ARRAY_PROTO_FLAT {"flat", 0, &builtin_array_proto_flat},
    ARRAY_PROTO_FLATMAP {"flatMap", 1, &builtin_array_proto_flatMap},
    STRING_FROMCODEPOINT {"fromCodePoint", 1, &builtin_string_fromcodepoint},
    ENCODE_URI {"encodeURI", 1, &builtin_encode_uri},
    ENCODE_URI_COMPONENT {"encodeURIComponent", 1, &builtin_encode_uri_component},
    DECODE_URI {"decodeURI", 1, &builtin_decode_uri},
    DECODE_URI_COMPONENT {"decodeURIComponent", 1, &builtin_decode_uri_component},
    URI_ERROR {"URIError", 1, &builtin_uri_error},
    ARRAY_PROTO_TOREVERSED {"toReversed", 0, &builtin_array_proto_toReversed},
    ARRAY_PROTO_TOSORTED {"toSorted", 1, &builtin_array_proto_toSorted},
    ARRAY_PROTO_TOSPLICED {"toSpliced", 2, &builtin_array_proto_toSpliced},
    ARRAY_PROTO_WITH {"with", 2, &builtin_array_proto_with},
    STRING_PROTO_MATCH {"match", 1, &builtin_string_proto_match},
    STRING_PROTO_SEARCH {"search", 1, &builtin_string_proto_search},
    STRING_PROTO_INCLUDES {"includes", 1, &builtin_string_proto_includes},
    STRING_PROTO_STARTSWITH {"startsWith", 1, &builtin_string_proto_startsWith},
    STRING_PROTO_ENDSWITH {"endsWith", 1, &builtin_string_proto_endsWith},
    STRING_PROTO_REPEAT {"repeat", 1, &builtin_string_proto_repeat},
    STRING_PROTO_TRIMSTART {"trimStart", 0, &builtin_string_proto_trimStart},
    STRING_PROTO_TRIMEND {"trimEnd", 0, &builtin_string_proto_trimEnd},
    STRING_PROTO_CODEPOINTAT {"codePointAt", 1, &builtin_string_proto_codePointAt},
    STRING_PROTO_AT {"at", 1, &builtin_string_proto_at},
    STRING_PROTO_PADSTART {"padStart", 1, &builtin_string_proto_padStart},
    STRING_PROTO_PADEND {"padEnd", 1, &builtin_string_proto_padEnd},
    STRING_PROTO_LASTINDEXOF {"lastIndexOf", 1, &builtin_string_proto_lastIndexOf},
    ARRAY_OF {"of", 0, &builtin_array_of},
    ARRAY_PROTO_FILL {"fill", 1, &builtin_array_proto_fill},
    ARRAY_PROTO_FIND {"find", 1, &builtin_array_proto_find},
    ARRAY_PROTO_FINDINDEX {"findIndex", 1, &builtin_array_proto_findIndex},
    ARRAY_PROTO_INCLUDES {"includes", 1, &builtin_array_proto_includes},
    ARRAY_PROTO_AT {"at", 1, &builtin_array_proto_at},
    ARRAY_PROTO_COPYWITHIN {"copyWithin", 2, &builtin_array_proto_copyWithin},
    DATE_PROTO_GETUTCFULLYEAR {"getUTCFullYear", 0, &builtin_date_proto_getUTCFullYear},
    DATE_PROTO_GETUTCMONTH {"getUTCMonth", 0, &builtin_date_proto_getUTCMonth},
    DATE_PROTO_GETUTCDATE {"getUTCDate", 0, &builtin_date_proto_getUTCDate},
    DATE_PROTO_GETUTCDAY {"getUTCDay", 0, &builtin_date_proto_getUTCDay},
    DATE_PROTO_GETUTCHOURS {"getUTCHours", 0, &builtin_date_proto_getUTCHours},
    DATE_PROTO_GETUTCMINUTES {"getUTCMinutes", 0, &builtin_date_proto_getUTCMinutes},
    DATE_PROTO_GETUTCSECONDS {"getUTCSeconds", 0, &builtin_date_proto_getUTCSeconds},
    DATE_PROTO_GETUTCMILLISECONDS {"getUTCMilliseconds", 0, &builtin_date_proto_getUTCMilliseconds},
    DATE_PROTO_SETTIME {"setTime", 1, &builtin_date_proto_setTime},
    DATE_PROTO_SETMILLISECONDS {"setMilliseconds", 1, &builtin_date_proto_setMilliseconds},
    DATE_PROTO_SETSECONDS {"setSeconds", 2, &builtin_date_proto_setSeconds},
    DATE_PROTO_SETMINUTES {"setMinutes", 3, &builtin_date_proto_setMinutes},
    DATE_PROTO_SETHOURS {"setHours", 4, &builtin_date_proto_setHours},
    DATE_PROTO_SETDATE {"setDate", 1, &builtin_date_proto_setDate},
    DATE_PROTO_SETMONTH {"setMonth", 2, &builtin_date_proto_setMonth},
    DATE_PROTO_SETFULLYEAR {"setFullYear", 3, &builtin_date_proto_setFullYear},
    DATE_PROTO_SETUTCMILLISECONDS {"setUTCMilliseconds", 1, &builtin_date_proto_setUTCMilliseconds},
    DATE_PROTO_SETUTCSECONDS {"setUTCSeconds", 2, &builtin_date_proto_setUTCSeconds},
    DATE_PROTO_SETUTCMINUTES {"setUTCMinutes", 3, &builtin_date_proto_setUTCMinutes},
    DATE_PROTO_SETUTCHOURS {"setUTCHours", 4, &builtin_date_proto_setUTCHours},
    DATE_PROTO_SETUTCDATE {"setUTCDate", 1, &builtin_date_proto_setUTCDate},
    DATE_PROTO_SETUTCMONTH {"setUTCMonth", 2, &builtin_date_proto_setUTCMonth},
    DATE_PROTO_SETUTCFULLYEAR {"setUTCFullYear", 3, &builtin_date_proto_setUTCFullYear},
    DATE_PROTO_TOISOSTRING {"toISOString", 0, &builtin_date_proto_toISOString},
    DATE_PROTO_TOUTCSTRING {"toUTCString", 0, &builtin_date_proto_toUTCString},
    DATE_PROTO_TODATESTRING {"toDateString", 0, &builtin_date_proto_toDateString},
    DATE_PROTO_TOTIMESTRING {"toTimeString", 0, &builtin_date_proto_toTimeString},
    STRING_PROTO_REPLACEALL {"replaceAll", 2, &builtin_string_proto_replaceAll},
    STRING_PROTO_MATCHALL {"matchAll", 1, &builtin_string_proto_matchAll},
    STRING_PROTO_NORMALIZE {"normalize", 0, &builtin_string_proto_normalize},
    STRING_PROTO_ISWELLFORMED {"isWellFormed", 0, &builtin_string_proto_isWellFormed},
    STRING_PROTO_TOWELLFORMED {"toWellFormed", 0, &builtin_string_proto_toWellFormed},
    REFLECT_OWNKEYS {"ownKeys", 1, &builtin_reflect_ownKeys},
    ERROR_CAPTURE_STACK_TRACE {"captureStackTrace", 2, &builtin_error_captureStackTrace},
    STRING_RAW {"raw", 1, &builtin_string_raw},
    // --- BigInt (plan 056) ---
    BIGINT {"BigInt", 1, &builtin_bigint},                                             // BigInt(x)
    BIGINT_AS_INTN {"asIntN", 2, &builtin_bigint_as_intn},                             // BigInt.asIntN(bits, x)
    BIGINT_AS_UINTN {"asUintN", 2, &builtin_bigint_as_uintn},                          // BigInt.asUintN(bits, x)
    BIGINT_PROTO_TOSTRING {"toString", 0, &builtin_bigint_proto_toString},             // BigInt.prototype.toString([radix])
    BIGINT_PROTO_VALUEOF {"valueOf", 0, &builtin_bigint_proto_valueOf},                // BigInt.prototype.valueOf()
    BIGINT_PROTO_TOLOCALESTRING {"", -1, null},                                        // BigInt.prototype.toLocaleString()
    // --- %AsyncFromSyncIteratorPrototype% (plan 057, ES2018 §27.1.4) ---
    ASYNC_FROM_SYNC_NEXT {"next", 1, &builtin_async_from_sync_next},                   // %AsyncFromSyncIteratorPrototype%.next(value)
    ASYNC_FROM_SYNC_RETURN {"return", 1, &builtin_async_from_sync_return},             // %AsyncFromSyncIteratorPrototype%.return(value)
    ASYNC_FROM_SYNC_THROW {"throw", 1, &builtin_async_from_sync_throw},                // %AsyncFromSyncIteratorPrototype%.throw(value)
    ASYNC_FROM_SYNC_VALUE_UNWRAP {"", 1, &builtin_async_from_sync_value_unwrap},       // native fulfill reaction: builds {value, done}
    ASYNC_FROM_SYNC_REJECT_FORWARD {"", 1, &builtin_async_from_sync_reject_forward},   // native reject reaction: forwards rejection
    PROMISE_WITH_RESOLVERS {"withResolvers", 0, &builtin_promise_with_resolvers},      // Promise.withResolvers() (ES2024)
    PROMISE_TRY {"try", 1, &builtin_promise_try},                                      // Promise.try(callbackfn, ...args) (ES2026)
    ERROR_ISERROR {"isError", 1, &builtin_error_isError},                              // Error.isError(arg) (ES2026)
    // --- Set methods proposal (ES2025 §24.2.4) ---
    SET_PROTO_UNION {"union", 1, &builtin_set_proto_union},                            // Set.prototype.union(other)
    SET_PROTO_INTERSECTION {"intersection", 1, &builtin_set_proto_intersection},       // Set.prototype.intersection(other)
    SET_PROTO_DIFFERENCE {"difference", 1, &builtin_set_proto_difference},             // Set.prototype.difference(other)
    SET_PROTO_SYMMETRICDIFFERENCE {"symmetricDifference", 1, &builtin_set_proto_symmetricDifference}, // Set.prototype.symmetricDifference(other)
    SET_PROTO_ISSUBSETOF {"isSubsetOf", 1, &builtin_set_proto_isSubsetOf},             // Set.prototype.isSubsetOf(other)
    SET_PROTO_ISSUPERSETOF {"isSupersetOf", 1, &builtin_set_proto_isSupersetOf},       // Set.prototype.isSupersetOf(other)
    SET_PROTO_ISDISJOINTFROM {"isDisjointFrom", 1, &builtin_set_proto_isDisjointFrom}, // Set.prototype.isDisjointFrom(other)
    REGEXP_ESCAPE {"escape", 1, &builtin_regexp_escape},                               // RegExp.escape(string) (ES2026 proposal-regex-escaping)
    // --- Iterator Helpers (ES2025 §27.1) ---
    ITERATOR_CTOR {"Iterator", 0, &builtin_iterator_ctor},                             // Iterator(), throws (abstract, subclassable)
    ITERATOR_FROM {"from", 1, &builtin_iterator_from},                                 // Iterator.from(obj)
    ITERATOR_PROTO_CONSTRUCTOR_GET {"get constructor", 0, &builtin_iterator_proto_constructor_get}, // get Iterator.prototype.constructor
    ITERATOR_PROTO_CONSTRUCTOR_SET {"set constructor", 1, &builtin_iterator_proto_constructor_set}, // set Iterator.prototype.constructor
    ITERATOR_PROTO_TOSTRINGTAG_GET {"get [Symbol.toStringTag]", 0, &builtin_iterator_proto_tostringtag_get}, // get Iterator.prototype[Symbol.toStringTag]
    ITERATOR_PROTO_TOSTRINGTAG_SET {"set [Symbol.toStringTag]", 1, &builtin_iterator_proto_tostringtag_set}, // set Iterator.prototype[Symbol.toStringTag]
    ITERATOR_PROTO_MAP {"map", 1, &builtin_iterator_proto_map},
    ITERATOR_PROTO_FILTER {"filter", 1, &builtin_iterator_proto_filter},
    ITERATOR_PROTO_TAKE {"take", 1, &builtin_iterator_proto_take},
    ITERATOR_PROTO_DROP {"drop", 1, &builtin_iterator_proto_drop},
    ITERATOR_PROTO_FLATMAP {"flatMap", 1, &builtin_iterator_proto_flatmap},
    ITERATOR_PROTO_REDUCE {"reduce", 1, &builtin_iterator_proto_reduce},
    ITERATOR_PROTO_TOARRAY {"toArray", 0, &builtin_iterator_proto_toarray},
    ITERATOR_PROTO_FOREACH {"forEach", 1, &builtin_iterator_proto_foreach},
    ITERATOR_PROTO_SOME {"some", 1, &builtin_iterator_proto_some},
    ITERATOR_PROTO_EVERY {"every", 1, &builtin_iterator_proto_every},
    ITERATOR_PROTO_FIND {"find", 1, &builtin_iterator_proto_find},
    ITERATOR_CONCAT {"concat", -1, &builtin_iterator_concat},
    WRAP_FOR_VALID_ITERATOR_NEXT {"next", 0, &builtin_wrap_for_valid_iterator_next},
    WRAP_FOR_VALID_ITERATOR_RETURN {"return", 0, &builtin_wrap_for_valid_iterator_return},
    ITERATOR_HELPER_NEXT {"next", 0, &builtin_iterator_helper_next},
    ITERATOR_HELPER_RETURN {"return", 0, &builtin_iterator_helper_return},
    JSON_RAW_JSON {"rawJSON", 1, &builtin_json_raw_json},
    JSON_IS_RAW_JSON {"isRawJSON", 1, &builtin_json_is_raw_json},
    // --- Array.fromAsync (proposal-array-from-async, ES2026) ---
    ARRAY_FROM_ASYNC {"fromAsync", 1, &builtin_array_from_async},                      // Array.fromAsync(asyncItems, mapfn, thisArg)
    ARRAY_FROM_ASYNC_STEP_FULFILL {"", 1, &builtin_array_from_async_step_fulfill},     // native reaction: awaited next()/element ready
    ARRAY_FROM_ASYNC_MAP_FULFILL {"", 1, &builtin_array_from_async_map_fulfill},       // native reaction: awaited mapped value ready
    ARRAY_FROM_ASYNC_REJECT {"", 1, &builtin_array_from_async_reject},                 // native reaction: reject → close iterator, reject outer
    // --- Resizable ArrayBuffer (ES2024) ---
    ARRAYBUFFER_PROTO_RESIZE {"resize", 1, &builtin_arraybuffer_proto_resize},
    ARRAYBUFFER_PROTO_RESIZABLE_GET {"", -1, &builtin_arraybuffer_proto_resizable_get},
    ARRAYBUFFER_PROTO_MAXBYTELENGTH_GET {"", -1, &builtin_arraybuffer_proto_maxbytelength_get},
    ARRAYBUFFER_PROTO_TRANSFER {"transfer", 0, &builtin_arraybuffer_proto_transfer},
    ARRAYBUFFER_PROTO_TRANSFER_TO_FIXED_LENGTH {"transferToFixedLength", 0, &builtin_arraybuffer_proto_transfer_to_fixed_length},
    // --- SharedArrayBuffer (single-agent) ---
    SHAREDARRAYBUFFER {"SharedArrayBuffer", 1, &builtin_sharedarraybuffer},
    SHAREDARRAYBUFFER_PROTO_BYTELENGTH_GET {"", -1, &builtin_sharedarraybuffer_proto_bytelength_get},
    SHAREDARRAYBUFFER_PROTO_GROWABLE_GET {"", -1, &builtin_sharedarraybuffer_proto_growable_get},
    SHAREDARRAYBUFFER_PROTO_MAXBYTELENGTH_GET {"", -1, &builtin_sharedarraybuffer_proto_maxbytelength_get},
    SHAREDARRAYBUFFER_PROTO_GROW {"grow", 1, &builtin_sharedarraybuffer_proto_grow},
    SHAREDARRAYBUFFER_PROTO_SLICE {"slice", 2, &builtin_sharedarraybuffer_proto_slice},
    SHAREDARRAYBUFFER_SPECIES_GET {"", -1, &builtin_sharedarraybuffer_species_get},
    // --- Atomics ---
    ATOMICS_ADD {"", -1, &builtin_atomics_add},
    ATOMICS_AND {"", -1, &builtin_atomics_and},
    ATOMICS_COMPAREEXCHANGE {"", -1, &builtin_atomics_compareexchange},
    ATOMICS_EXCHANGE {"", -1, &builtin_atomics_exchange},
    ATOMICS_LOAD {"", -1, &builtin_atomics_load},
    ATOMICS_OR {"", -1, &builtin_atomics_or},
    ATOMICS_STORE {"", -1, &builtin_atomics_store},
    ATOMICS_SUB {"", -1, &builtin_atomics_sub},
    ATOMICS_XOR {"", -1, &builtin_atomics_xor},
    ATOMICS_ISLOCKFREE {"", -1, &builtin_atomics_islockfree},
    ATOMICS_WAIT {"", -1, &builtin_atomics_wait},
    ATOMICS_NOTIFY {"", -1, &builtin_atomics_notify},
    ATOMICS_WAITASYNC {"", -1, &builtin_atomics_waitasync},
    // --- Async generators (plan 060, ES2018 §27.6) ---
    ASYNC_ITERATOR_PROTO_SYMBOL_ASYNCITER {"[Symbol.asyncIterator]", 0, &builtin_async_iterator_proto_symbol_asynciter}, // %AsyncIteratorPrototype%[@@asyncIterator]() → this
    ASYNC_GENERATOR_PROTO_NEXT {"next", 1, &builtin_async_generator_proto_next},       // %AsyncGeneratorPrototype%.next(value)
    ASYNC_GENERATOR_PROTO_RETURN {"return", 1, &builtin_async_generator_proto_return}, // %AsyncGeneratorPrototype%.return(value)
    ASYNC_GENERATOR_PROTO_THROW {"throw", 1, &builtin_async_generator_proto_throw},    // %AsyncGeneratorPrototype%.throw(value)
    ASYNC_GENERATOR_FUNCTION {"AsyncGeneratorFunction", 1, &builtin_async_generator_function}, // %AsyncGeneratorFunction% constructor
    ASYNC_GEN_AWAIT_RESUME {"", -1, &builtin_async_gen_await_resume},                  // native reaction: internal await fulfilled → re-drive body
    ASYNC_GEN_AWAIT_REJECT {"", -1, &builtin_async_gen_await_reject},                  // native reaction: internal await rejected → inject throw
    ASYNC_GEN_RETURN_FULFILL {"", -1, &builtin_async_gen_return_fulfill},              // native reaction: AwaitReturn value fulfilled → settle {value,done:true}
    ASYNC_GEN_RETURN_REJECT {"", -1, &builtin_async_gen_return_reject},                // native reaction: AwaitReturn value rejected → reject request
    ASYNC_GEN_YRET_FULFILL {"", -1, &builtin_async_gen_yret_fulfill},                  // native reaction: yield-resumption return value fulfilled → resume body w/ return
    ASYNC_GEN_YRET_REJECT {"", -1, &builtin_async_gen_yret_reject},                    // native reaction: yield-resumption return value rejected → resume body w/ throw
    REGEXP_PROTO_COMPILE {"compile", 2, &builtin_regexp_proto_compile},                // RegExp.prototype.compile(pattern, flags) (Annex B §B.2.4.1)
    ATOMICS_PAUSE {"", -1, &builtin_atomics_pause},                                    // Atomics.pause([iterationNumber]), microwait hint (ES2025 §25.4.6)
    // --- error-stack-accessor proposal ---
    ERROR_PROTO_STACK_GET {"get stack", 0, &builtin_error_proto_stack_get},            // get Error.prototype.stack
    ERROR_PROTO_STACK_SET {"set stack", 1, &builtin_error_proto_stack_set},            // set Error.prototype.stack
    ESCAPE {"escape", 1, &builtin_escape},                                             // escape(string) (Annex B §B.2.1.1)
    UNESCAPE {"unescape", 1, &builtin_unescape},                                       // unescape(string) (Annex B §B.2.1.2)
    LAST {"", -1, null}, // sentinel, one past the highest valid builtin; not a real builtin
}

// ES2015 §9.1.14 OrdinaryCreateFromConstructor / §9.1.15 GetPrototypeFromConstructor.
//
// If ctx.new_target is non-null, perform a full `Get(C, "prototype")` on it;
// if the result is an object, return it as the instance prototype.  Otherwise
// return default_proto.  This makes `class Sub extends Builtin {}` produce
// instances whose __proto__ is Sub.prototype rather than the built-in prototype.
//
// Uses full Get semantics (not get_prop_proto) so an accessor "prototype"
// getter on `new_target` is actually invoked, and a throwing getter propagates
// as an abrupt completion via ctx.should_throw per ES2015 §9.1.14 step 3
// (test262 built-ins/Promise/get-prototype-abrupt).  Returns default_proto on
// error so the VM can still consult ctx.should_throw / ctx.throw_value to
// raise the original error when the calling builtin returns.
fn HObject* builtin_proto_from_new_target(BuiltinContext* ctx, HObject* default_proto) {
    HObject* nt = ctx.new_target;
    if (nt == null) return default_proto;
    // Avoid the trivial case: if new_target is the builtin itself (plain `new Builtin()`)
    // its ".prototype" IS default_proto, so we'd return the same value, but it's still
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

// ES5 §8.12.3 [[Get]] / ES2020 §10.1.8.1 OrdinaryGet, for builtins that
// need full Get semantics on a property (walks prototype chain, invokes
// accessor getters). Returns the resolved TVal, or faults on throw (per
// ES2017 §25.4.1.5 step 7 `ReturnIfAbrupt`). A `null`/missing key
// returns `undefined` (no fault). Used by Map/Set/WeakMap/WeakSet
// constructors per ES6 §23.1.1 / §23.2.1 / §23.3.1 / §23.4.1.
fn TVal? builtins_generic_get(HObject* obj, HString* key, BuiltinContext* ctx) {
    if (obj == null || key == null) {
        TVal undef; undef.set_undefined();
        return undef;
    }
    if (obj != null) ((HeapHeader*)obj).set_temproot();
    if (key != null) ((HeapHeader*)key).set_temproot();
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto((void*)key, true, ctx.heap);
    switch (res.kind) {
        case hobject::PropLookupKind.PROP_DATA:
            return res.data_val;
        case hobject::PropLookupKind.PROP_ACCESSOR: {
            // ES5 §8.12.3 / ES2020 §10.1.8.1 step 6: invoke the accessor's
            // getter with `this` set to the object where the accessor was
            // found (not the receiver). For prototype accessors this is
            // critical, calling the getter with the derived instance as
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

// ToObject(value) for property lookup only (ES2015 §7.1.13). Objects are
// returned as-is; a primitive is wrapped in a throwaway object whose
// prototype is chosen from the primitive's own type, so user-installed
// methods on String/Number/Boolean/BigInt.prototype stay reachable.
// undefined/null return null, callers decide whether that is a TypeError.
// The wrapper is only for reading; it is not exposed to script.
fn HObject* to_object_for_lookup(Heap* heap, TVal value) {
    if (value.is_object() && value.get_heapptr() != null) {
        return (HObject*)value.get_heapptr();
    }
    if (value.is_undefined() || value.is_null()) return null;
    HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch wrapped) return null;
    HObject* obj = wrapped;
    HObject* wrap_proto = heap.string_proto;
    if (value.is_string()) {
        // Retained so String.prototype methods relying on the primitive
        // (e.g. the @@iterator returned here) see the right value.
        (*obj.extra_ptr()).prim.primitive_value = value;
    } else if (value.is_fastint() || value.is_number()) {
        wrap_proto = heap.number_proto;
    } else if (value.is_boolean()) {
        wrap_proto = heap.bool_proto;
    } else if (value.is_bigint()) {
        wrap_proto = heap.bigint_proto;
    }
    obj.prototype = wrap_proto;
    return obj;
}

// Stdout byte sink for write_cesu8_as_utf8. A PutByteFn must accept a udata
// pointer; this destination is a fixed stream, so it is unused.
fn void putc_stdout(char c, void* udata) {
    io::putchar(c);
}

fn void print_tval(Heap* heap, TVal* val) {
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
                if ((double)iv == v && iv >= types::MIN_SAFE_INT && iv <= types::MAX_SAFE_INT) {
                    io::printf("%d", iv);
                } else {
                    // Shortest round-trip form, same as ToString(Number).
                    char[64] nbuf;
                    char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] ntmp;
                    int nlen = dtoa_bindings::boomkat_js_dtoa(&nbuf, v, 10, 0,
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
                hstring::write_cesu8_as_utf8(s.get_data(), &putc_stdout);
            } else {
                io::printf("[null string]");
            }
        case OBJECT:
            io::printf("[object Object]");
        case LIGHTFUNC:
            io::printf("[function]");
        case BIGINT:
            char[48] bbuf;
            char* bheap;
            char[] bs = hbigint::hbigint_to_decimal(heap, val.get_bigint(), bbuf[..], &bheap);
            defer if (bheap != null) heap.free((void*)bheap);
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

// ECMAScript whitespace (ASCII subset: Tab, VT, FF, Space, NBSP, LF, CR).
// Used by ToNumber which only needs ASCII whitespace.
fn bool is_ecma_whitespace(char c) @inline {
    return c == 0x09 || c == 0x0B || c == 0x0C
        || c == 0x20 || c == 0xA0
        || c == 0x0A || c == 0x0D;
}

// ECMAScript whitespace check at the Unicode codepoint level (ES5 §7.2 + §7.3).
// Handles the full Unicode range including Zs (Space_Separator) characters.
// Used by String.prototype.trim which must strip all Unicode whitespace.
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

// Decode a UTF-8 codepoint starting at `data[off]`. Returns the codepoint
// and sets `*seq_len` to the number of bytes consumed (1-4). Returns 0 on
// invalid/truncated input.
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
    // Invalid lead byte, skip one byte
    *seq_len = 1;
    return 0;
}

// ECMAScript ToNumber for strings (§7.1.3.1).
//
// Converts an HString* to a double, trimming ECMAScript whitespace and
// parsing numeric literals (decimal, hex, Infinity).  Returns NaN when
// the string does not represent a valid numeric literal.
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

    // --- Binary integer literal (0b... / 0B...), ES2015 §7.1.3.1 ---
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

    // --- Octal integer literal (0o... / 0O...), ES2015 §7.1.3.1 ---
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

// Convert any TVal to a numeric TVal per ES5 §9.3.
// Preserves FASTINT where possible.
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
            // Try fastint preservation, but not for -0 (fastint can't represent it)
            if (d != 0.0 || !math::signbit(d)) {
                long fi = (long)d;
                if ((double)fi == d && fi >= types::MIN_SAFE_INT && fi <= types::MAX_SAFE_INT) {
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

// Simplified ToPrimitive for builtins, unwraps Boolean/Number/String wrapper objects.
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
            return !val.get_bigint().is_zero();   // ToBoolean(0n) = false
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
    // Heap.str_intern normalizes raw 4-byte UTF-8 astral sequences to CESU-8
    // before hashing, so one logical string cannot intern under two different
    // byte encodings.
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
            HString* msg_key = ctx.heap.str(heap::BuiltinStr.MESSAGE);
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC, ctx.heap);
        }
        TVal err_val;
        err_val.set_object(err);
        ctx.should_throw = true;
        ctx.throw_value = err_val;
    }
    return null;
}

// ============================================================================
// CanBeHeldWeakly (ES2023 §7.2.11), shared by WeakMap key / WeakSet value /
// WeakRef target / FinalizationRegistry target+token checks.
// ============================================================================

// True if `val` is an object, or a Symbol that is not in the global Symbol
// registry (i.e. not created via Symbol.for, well-known symbols like
// Symbol.iterator are fine, since only Symbol.for results are registered).
fn bool can_be_held_weakly(Heap* heap, TVal val) {
    if (val.is_object() && val.get_heapptr() != null) return true;
    // A LIGHTFUNC builtin is an Object, so CanBeHeldWeakly is true for it. It
    // is also immortal -- its identity is a builtin index, not an allocation --
    // so a weak reference to one simply never clears, which is the same
    // observable behaviour as a strongly reachable target.
    if (val.is_lightfunc()) return true;
    if (is_symbol_val(val)) {
        HString* sym = (HString*)val.get_heapptr();
        return symbol_registry_get_key(heap, sym) == null;
    }
    return false;
}

// ============================================================================
// Array part search helper (shared by Map, Set, WeakMap, WeakSet)
// ============================================================================

// Find the index in array_part where a value matches using SameValueZero.
// stride=2 for Map/WeakMap (key-value pairs), stride=1 for Set/WeakSet (values).
// Returns -1 if not found.
// Mix a double's bits, folding -0 onto +0 so the two hash alike.
fn uint coll_hash_double(double d) @inline {
    if (d == 0.0) { d = 0.0; }
    ulong x = bitcast(d, ulong);
    x ^= x >> 33;
    x *= 0xFF51AFD7ED558CCDu;
    x ^= x >> 29;
    return (uint)x;
}

// Hash a collection key so SameValueZero-equal values always collide.
//
// Must agree with same_value_impl(.., false): a fastint and a double holding
// the same value are equal despite their different tags, every NaN equals
// every other, -0 equals +0, and strings compare by content rather than
// pointer (strings over MAX_INTERN_BYTES are not interned, so two equal
// strings can be distinct objects).
//
// Numeric keys are therefore canonicalised to a double before hashing, NaN
// maps to one fixed code, and strings hash their bytes. Hashing two EQUAL keys
// differently loses entries; hashing unequal keys alike only costs a probe.
fn uint coll_hash_key(TVal v, heap::Heap* h) {
    if (v.is_fastint()) return coll_hash_double((double)v.get_fastint());
    if (v.is_number()) {
        double d = v.get_number();
        if (math::is_nan(d)) return 0x7FF80000u;
        return coll_hash_double(d);
    }
    if (v.is_string()) {
        hstring::HString* hs = (hstring::HString*)v.get_heapptr();
        return hs != null ? h.content_hash(hs) : 0u;
    }
    if (v.is_boolean()) return v.get_boolean() ? 0x9E3779B9u : 0x85EBCA6Bu;
    if (v.is_undefined()) return 0xC2B2AE35u;
    if (v.is_null()) return 0x27D4EB2Fu;
    if (v.is_bigint()) {
        long b = (long)v.get_bigint();
        return ((uint)b) ^ ((uint)(b >> 32));
    }
    // Objects and symbols are compared by identity, so they hash by it too.
    ulong p = (ulong)(uptr)v.get_heapptr();
    return (uint)(p >> 4) ^ (uint)(p >> 32);
}

// Drop a collection's lookup index, so the next operation rebuilds it.
fn void coll_hash_drop(HObject* obj, heap::Heap* h) {
    hobject::CollHashInfo* ci = obj.coll_hash;
    if (ci == null) return;
    if (ci.slots != null) { h.free_func(h.heap_udata, ci.slots); }
    h.free_func(h.heap_udata, ci);
    obj.coll_hash = null;
}

// Build (or rebuild) the index over array_part, sized to the current entry
// count. Leaves coll_hash null if anything fails, which only costs speed:
// every caller falls back to the linear scan.
fn void coll_hash_build(HObject* obj, uint stride, heap::Heap* h) {
    coll_hash_drop(obj, h);

    uint entries = obj.array_used / stride;
    // Keep the load factor near 0.5, so probe chains stay short.
    uint cap = 16;
    while (cap < entries * 2) {
        if (cap >= 0x40000000u) return;   // refuse rather than overflow
        cap *= 2;
    }

    hobject::CollHashInfo* ci =
        (hobject::CollHashInfo*)h.alloc_func(h.heap_udata, hobject::CollHashInfo::size);
    if (ci == null) return;
    uint* slots = (uint*)h.alloc_func(h.heap_udata, (usz)cap * uint::size);
    if (slots == null) { h.free_func(h.heap_udata, ci); return; }
    for (uint i = 0; i < cap; i++) { slots[i] = 0; }

    ci.slots = slots;
    ci.mask = cap - 1;
    ci.used = 0;
    ci.built = obj.array_used;
    obj.coll_hash = ci;

    // A tombstoned entry keeps its array slot (live iterators depend on that)
    // but must not be indexed, or a lookup would resolve to a deleted value.
    TVal* ap = obj.array_part();
    if (ap == null) { coll_hash_drop(obj, h); return; }
    for (uint i = 0; i < obj.array_used; i += stride) {
        if (ap[i].is_deleted()) continue;
        uint slot = coll_hash_key(ap[i], h) & ci.mask;
        while (slots[slot] != 0) { slot = (slot + 1) & ci.mask; }
        slots[slot] = i + 1;   // 1-based, so 0 can mean empty
        ci.used++;
    }
}

fn int find_in_array_part(HObject* obj, TVal val, uint stride) {
    uint count = obj.array_used;
    for (uint i = 0; i < count; i += stride) {
        if (same_value_zero(obj.array_part()[i], val)) {
            return (int)i;
        }
    }
    return -1;
}

// find_in_array_part, but using the collection's hash index once it is worth
// having one.
//
// Map/Set/WeakMap/WeakSet keep entries in array_part, and scanning it on
// every add, has, get and delete makes building a collection quadratic:
// a linear scan of a 100k Set costs 24s against QuickJS's 9ms, over 90% of
// it inside same_value_zero.
//
// The index stores 1-based array_part indices rather than a copy of each key,
// so array_part stays the single source of truth for iteration order,
// tombstones and GC tracing, and the extra memory is one uint per slot at a
// ~0.5 load factor instead of a second copy of every key.
//
// Falls back to the scan whenever the index is absent -- below the size
// threshold, or after an allocation failure -- so behaviour never depends on
// it existing.
fn int coll_find(HObject* obj, TVal val, uint stride, heap::Heap* h) {
    uint entries = obj.array_used / stride;
    if (entries < hobject::COLL_HASH_MIN_ENTRIES) {
        return find_in_array_part(obj, val, stride);
    }

    hobject::CollHashInfo* ci = obj.coll_hash;

    // Entries appended since the last build are indexed incrementally rather
    // than by rebuilding: an append happens on every add/set, and rebuilding
    // there would restore the very O(n)-per-insert cost this index removes.
    // A full rebuild is only for the cases incremental catch-up cannot serve --
    // no index yet, a shrunk array (delete-compaction in the Weak collections),
    // or a load factor that has crept too high.
    if (ci != null && ci.built < obj.array_used && ci.used * 2 <= ci.mask) {
        TVal* ap_add = obj.array_part();
        if (ap_add != null) {
            for (uint i = ci.built; i < obj.array_used; i += stride) {
                if (ap_add[i].is_deleted()) continue;
                uint slot = coll_hash_key(ap_add[i], h) & ci.mask;
                while (ci.slots[slot] != 0
                       && ci.slots[slot] != hobject::COLL_SLOT_DELETED) {
                    slot = (slot + 1) & ci.mask;
                }
                ci.slots[slot] = i + 1;
                ci.used++;
            }
            ci.built = obj.array_used;
        }
    }

    if (ci == null || ci.built != obj.array_used || ci.used * 2 > ci.mask) {
        coll_hash_build(obj, stride, h);
        ci = obj.coll_hash;
        if (ci == null) return find_in_array_part(obj, val, stride);
    }

    TVal* ap = obj.array_part();
    if (ap == null) return -1;

    uint slot = coll_hash_key(val, h) & ci.mask;
    while (true) {
        uint e = ci.slots[slot];
        if (e == 0) return -1;                       // empty: the key is absent
        if (e != hobject::COLL_SLOT_DELETED) {
            uint idx = e - 1;
            if (idx < obj.array_used && same_value_zero(ap[idx], val)) {
                return (int)idx;
            }
        }
        slot = (slot + 1) & ci.mask;                 // step over tombstones
    }
}

// ============================================================================
// Collection constructor helper (shared by Map, Set, WeakMap, WeakSet)
// ============================================================================

// Throws a TypeError built from `msg` and marks ctx to throw / return undefined.
// Allocs an Error object with the given prototype and message, then marks
// ctx to throw it. Does not touch ctx.result, callers that need
// ctx.result.set_undefined() (the common case for builtin call handlers)
// should call builtin_throw() instead.
fn void builtin_throw_no_result_change(BuiltinContext* ctx, HObject* proto, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = proto;
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        if (msg_str != null) {
            TVal msg_val; msg_val.set_string(msg_str);
            err.put_prop(ctx.heap.str(heap::BuiltinStr.MESSAGE), msg_val, hobject::PROP_FLAGS_WC, ctx.heap);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
}

// Allocs an Error object with the given prototype and message, marks ctx to
// throw it, and sets ctx.result to undefined (the standard pattern for
// builtin call handlers that bail out immediately after throwing).
fn void builtin_throw(BuiltinContext* ctx, HObject* proto, char[] msg) {
    builtin_throw_no_result_change(ctx, proto, msg);
    ctx.result.set_undefined();
}

fn void coll_throw(BuiltinContext* ctx, char[] msg) {
    builtin_throw(ctx, ctx.heap.type_err_proto, msg);
}

// Shared constructor body for Map/Set/WeakMap/WeakSet (ES6 §23.1.1, §23.2.1,
// §23.3.1, §23.4.1). Allocates the collection object, then if an iterable
// argument is provided populates it via the adder method ("set" for
// Map/WeakMap, "add" for Set/WeakSet) using the iterator protocol.
//
// is_pair: true for Map/WeakMap (entries are [k,v], adder called with 2 args),
//          false for Set/WeakSet (entries are single values, adder called with 1 arg).
// allow_array_fallback: reserved for array-like indexed iteration when
//          @@iterator is missing. Map/Set/WeakMap/WeakSet all pass false,
//          @@iterator must be callable or construction throws "iterable
//          argument is not iterable" (ES2015 §7.4.1 GetIterator; matches
//          V8/SpiderMonkey, there is no array-like fallback in the spec).
// requires_new_msg / arg_not_object_msg / adder_not_callable_msg / not_iterable_msg:
//          pre-built full error messages (avoids runtime string formatting).
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
            if (try found_iter_fn = iterable_obj.get_prop_proto(iter_sym, ctx.heap)) { iter_fn = found_iter_fn; }
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

                if (coll != null) ((HeapHeader*)coll).set_temproot();
                if (iter_obj != null) ((HeapHeader*)iter_obj).set_temproot();
                iterator.set_temproot();
                adder.set_temproot();

                while (true) {
                    TVal next_fn;
                    next_fn.set_undefined();
                    if (try found_next_fn = iter_obj.get_prop_proto(next_key, ctx.heap)) { next_fn = found_next_fn; }
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
                    HString* done_key = ctx.heap.str(heap::BuiltinStr.DONE);
                    TVal done_val;
                    done_val.set_undefined();
                    if (done_key != null) {
                        if (try d = builtins_generic_get(res_obj, done_key, ctx)) { done_val = d; }
                    }
                    if (ctx.should_throw) {
                        // done getter threw, close iterator then propagate.
                        arr_iterator_close_after_throw(ctx, iterator);
                        ctx.result.set_undefined();
                        return;
                    }
                    if (done_val.is_boolean() && done_val.get_boolean()) break;

                    HString* value_key = ctx.heap.str(heap::BuiltinStr.VALUE);
                    TVal val_tv;
                    val_tv.set_undefined();
                    if (value_key != null) {
                        if (try v = builtins_generic_get(res_obj, value_key, ctx)) { val_tv = v; }
                    }
                    if (ctx.should_throw) {
                        // value getter threw, close iterator then propagate (ES2022 §7.4.5).
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
                                // Getter for key[0] threw, close iterator then propagate.
                                arr_iterator_close_after_throw(ctx, iterator);
                                ctx.result.set_undefined();
                                return;
                            }
                            if (key1 != null) {
                                if (try vv = builtins_generic_get(pair_obj, key1, ctx)) { v = vv; }
                            }
                            if (ctx.should_throw) {
                                // Getter for key[1] threw, close iterator then propagate.
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
                                // adder threw, close iterator then propagate.
                                arr_iterator_close_after_throw(ctx, iterator);
                                ctx.result.set_undefined();
                                return;
                            }
                        } else {
                            // pair entry is not an object, ES2022 §23.1.1.1 step 9f requires TypeError.
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
                            // adder threw, close iterator then propagate.
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

// Shared body for Map.prototype.set / WeakMap.prototype.set (ES6 §23.1.3.9 / §23.3.3.5).
// require_object_key: true for WeakMap (throws "Invalid value used as weak map key"
// unless CanBeHeldWeakly(key), object or non-registered symbol), false for Map
// (any key allowed).
// grow_hwm: true for Map (array_used is a high-water mark that must include slots
// with undefined keys/values for iteration), false for WeakMap (not iterable).
// array_used is always widened to include the value slot regardless of
// grow_hwm, set_array_idx only tracks non-undefined writes, so a value of
// undefined (a valid Map/WeakMap value) would otherwise leave array_used
// short of the slot just written, corrupting find_in_array_part's scan
// bound for every later insert.
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
    // CanonicalizeKeyedCollectionKey (§24.5.1): -0 is stored as +0, so an
    // iterated key never surfaces as -0 even when set() was handed one.
    key = canonicalize_keyed_collection_key(key);
    int found = coll_find(coll, key, stride, ctx.heap);
    if (found >= 0) {
        // Overwrite the existing value slot directly (not via set_array_idx):
        // this slot is already counted in array_used, and a value of undefined
        // is a legitimate Map/WeakMap value, not a hole, set_array_idx's
        // undefined-transition bookkeeping would corrupt array_used here.
        TVal* v_slot = &coll.array_part()[(uint)found + 1];
        if (value.is_heap_allocated() && value.get_heapptr() != null) {
            ((types::HeapHeader*)value.get_heapptr()).incref();
        }
        ctx.heap.decref_tval(v_slot);
        *v_slot = value;
    } else {
        uint cnt = coll.array_used;
        coll.set_array_idx(cnt, key, ctx.heap);
        coll.set_array_idx(cnt + 1, value, ctx.heap);
        if (coll.array_used <= cnt + 1) {
            coll.array_used = (uint)(cnt + 2);
        }
    }
    ctx.result.set_object(coll);
}

// CanonicalizeKeyedCollectionKey (ES2025 §24.1.1.3): -0 -> +0, otherwise unchanged.
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

// Shared body for Map.prototype.getOrInsert / WeakMap.prototype.getOrInsert
// (ES2025 §24.1.3.9 / §24.3.3.6). require_weak_key: true for WeakMap (throws
// unless CanBeHeldWeakly(key)), false for Map. grow_hwm: see coll_set_entry.
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

    int found = coll_find(coll, key, 2, ctx.heap);
    if (found >= 0) {
        *ctx.result = coll.array_part()[(uint)found + 1];
        return;
    }
    uint cnt = coll.array_used;
    coll.set_array_idx(cnt, key, ctx.heap);
    coll.set_array_idx(cnt + 1, value, ctx.heap);
    if (coll.array_used <= cnt + 1) {
        coll.array_used = (uint)(cnt + 2);
    }
    *ctx.result = value;
}

// Shared body for Map.prototype.getOrInsertComputed / WeakMap.prototype.
// getOrInsertComputed (ES2025 §24.1.3.10 / §24.3.3.7). callbackfn is called
// with `key` as its sole argument and `undefined` as `this`, ONLY when the
// key was absent beforehand. After the callback returns, the map is
// re-searched for `key`: if present (whether because the callback itself
// inserted it, or it was already there), its value is overwritten with the
// callback's result and that value is returned; otherwise a new entry is
// appended. A throwing callback inserts nothing and propagates the throw.
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

    int found = coll_find(coll, key, 2, ctx.heap);
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
    int found2 = coll_find(coll, key, 2, ctx.heap);
    if (found2 >= 0) {
        // Overwrite directly (see coll_set_entry): set_array_idx's
        // undefined-transition bookkeeping would corrupt array_used here,
        // since this slot is already counted and undefined is a valid value.
        TVal* v_slot = &coll.array_part()[(uint)found2 + 1];
        if (value.is_heap_allocated() && value.get_heapptr() != null) {
            ((types::HeapHeader*)value.get_heapptr()).incref();
        }
        ctx.heap.decref_tval(v_slot);
        *v_slot = value;
    } else {
        uint cnt = coll.array_used;
        coll.set_array_idx(cnt, key, ctx.heap);
        coll.set_array_idx(cnt + 1, value, ctx.heap);
        if (coll.array_used <= cnt + 1) {
            coll.array_used = (uint)(cnt + 2);
        }
    }
    *ctx.result = value;
}

// Shared body for Set.prototype.add / WeakSet.prototype.add (ES6 §23.2.3.1 / §23.4.3.1).
// require_object_value: true for WeakSet (throws "Invalid value used in weak set"
// unless CanBeHeldWeakly(value), object or non-registered symbol), false for Set
// (any value allowed).
// grow_hwm: true for Set (array_used high-water mark must include undefined slots
// for iteration), false for WeakSet (not iterable).
fn void coll_add_value(BuiltinContext* ctx, HObject* coll, bool require_object_value,
                        char[] invalid_value_msg, bool grow_hwm) {
    TVal value; value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];
    if (require_object_value && !can_be_held_weakly(ctx.heap, value)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, invalid_value_msg);
        ctx.result.set_undefined();
        return;
    }
    // CanonicalizeKeyedCollectionKey (§24.5.1): a Set element is its own key,
    // so -0 is stored as +0 and iteration never surfaces -0.
    value = canonicalize_keyed_collection_key(value);
    int found = coll_find(coll, value, 1, ctx.heap);
    if (found < 0) {
        uint idx = coll.array_used;
        coll.set_array_idx(idx, value, ctx.heap);
        if (grow_hwm && coll.array_used <= idx) {
            coll.array_used = (uint)(idx + 1);
        }
    }
    ctx.result.set_object(coll);
}

// Shared body for Map/Set.prototype.delete (tombstone: mark deleted, keep slot,
// preserves array_used as a high-water mark so live iterators continue correctly)
// and WeakMap/WeakSet.prototype.delete (compact: shift subsequent entries down and
// shrink array_used, safe since Weak collections are not iterable).
// stride=2 for Map/WeakMap (key+value slots), stride=1 for Set/WeakSet (value only).
fn void coll_delete(BuiltinContext* ctx, HObject* coll, TVal key, uint stride, bool tombstone) {
    int found = coll_find(coll, key, stride, ctx.heap);
    if (found < 0) { ctx.result.set_boolean(false); return; }
    if (tombstone) {
        for (uint i = 0; i < stride; i++) {
            TVal* slot = &coll.array_part()[(uint)found + i];
            ctx.heap.decref_tval(slot);
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

// Append `value` to the group array for `key` in `groups_obj`, creating a new
// single-element Array the first time `key` is seen. `groups_obj` already has
// its final [[Prototype]] set by the caller (null for Object.groupBy).
fn bool group_by_append_object(BuiltinContext* ctx, HObject* groups_obj, HString* key, TVal value) {
    HObject* group_arr = null;
    PropValue*? existing = groups_obj.find_prop(key, ctx.heap);
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
        groups_obj.put_prop(key, arr_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    }
    uint idx = *group_arr.array_len_ptr();
    group_arr.set_array_idx(idx, value, ctx.heap);
    array_set_length(group_arr, idx + 1, ctx.heap);
    return true;
}

// Append `value` to the group array for `key` (SameValueZero) in `map`,
// creating a new single-element Array the first time `key` is seen.
fn bool group_by_append_map(BuiltinContext* ctx, HObject* map, TVal key, TVal value) {
    int found = map_find_key(map, key, ctx.heap);
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
            map.set_array_idx(cnt, key, ctx.heap);
            map.set_array_idx(cnt + 1, arr_tv, ctx.heap);
            if (map.array_used <= cnt + 1) {
                map.array_used = (uint)(cnt + 2);
            }
        }
    }
    uint idx = *group_arr.array_len_ptr();
    group_arr.set_array_idx(idx, value, ctx.heap);
    array_set_length(group_arr, idx + 1, ctx.heap);
    return true;
}

// GroupBy ( items, callbackfn, coercion ), ES2024 §23.1.2.1.
// `into_map`: false stores groups as data properties of a null-prototype
// object (Object.groupBy), true stores groups keyed by SameValueZero in a
// fresh Map (Map.groupBy, key -0 normalized to +0 per CanonicalizeKeyedCollectionKey).
// `result` receives the produced Object/Map on success, or null on failure,
// callers should check ctx.should_throw afterward to distinguish an in-band
// TypeError from ctx.result being validly unset.
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

    // GetIterator(items), must be an object/primitive with a callable
    // @@iterator; undefined/null @@iterator is a TypeError (no fallback).
    // Primitives are wrapped in a throwaway object whose [[Prototype]] is the
    // matching wrapper prototype, so the @@iterator lookup below walks the
    // real prototype chain (must set items_obj.prototype directly, a named
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
    // a freshly constructed Map (Map.groupBy), created before iteration.
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
    HString* done_key = heap.str(heap::BuiltinStr.DONE);
    HString* value_key = heap.str(heap::BuiltinStr.VALUE);

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

        // ES2024 §23.1.2.1 GroupBy step 6.e: 𝔽(k) as the index arg, beyond
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
            TVal norm_key = canonicalize_keyed_collection_key(key_result);
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

// ToString(Number) per ES2015 §7.1.12.1, shortest round-trip decimal via
// QuickJS js_dtoa (FREE mode), spec exponent format (1e+21, 1e-7).
fn HString* builtin_number_to_hstring(Heap* heap, double d) {
    if (math::is_nan(d)) return (HString*)heap.strs[heap::BuiltinStr.NAN_STR];
    if (math::is_inf(d)) {
        return (d > 0.0)
            ? (HString*)heap.strs[heap::BuiltinStr.POSITIVE_INFINITY]
            : (HString*)heap.strs[heap::BuiltinStr.NEGATIVE_INFINITY];
    }
    // -0 must produce "0"
    if (d == 0.0) return heap.int_to_hstring(0);
    // Integers up to 2^53 (every value in this range is exactly representable
    // and is therefore its own shortest round-trip decimal) use plain decimal
    // notation via printf. Above 2^53, adjacent doubles are more than 1 apart,
    // so the exact binary value's decimal expansion (as printf would produce)
    // is no longer necessarily the shortest round-trip String; those go
    // through dtoa's FREE format below to match ES ToString semantics.
    if (d == math::trunc(d) && d > -9007199254740992.0 && d < 9007199254740992.0) {
        return heap.int_to_hstring((long)d);
    }
    char[64] buf;
    char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] tmp;
    int len = dtoa_bindings::boomkat_js_dtoa(&buf, d, 10, 0,
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
            return heap.int_to_hstring(val.get_fastint());
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
            char* bheap;
            char[] bs = hbigint::hbigint_to_decimal(heap, val.get_bigint(), bbuf[..], &bheap);
            defer if (bheap != null) heap.free((void*)bheap);
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

// VM-aware ToInteger (ES2022 §7.1.5): properly handles objects by calling
// ToPrimitive via the VM (invoking valueOf/toString).  When ToPrimitive
// returns a non-primitive, throws TypeError instead of silently returning 0.
// ToIntegerOrInfinity first calls ToNumber, which throws TypeError for
// Symbol and BigInt arguments (ES2022 §7.1.4), checked before the object
// path since Symbols/BigInts are not objects.
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
            // ToNumber(BigInt) throws TypeError (ES2020 §7.1.4), e.g. a wrapper
            // or @@toPrimitive that yields a BigInt reaches here.
            if (prim.is_bigint()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert a BigInt value to a number");
                return 0.0 / 0.0;
            }
            return builtin_to_integer(&prim);
        }
        // Both valueOf and toString returned non-primitives, ES2022 §7.1.5 step 4b
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert object to primitive value");
        return 0.0 / 0.0;
    }
    return builtin_to_integer(val);
}

// Helper: clamp to int and coerce to range [0, len].
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

// Full IsRegExp check per ES2015 §7.2.8 with VM access for abrupt completions.
//
// Returns: 1 = is RegExp, 0 = is not RegExp, -1 = abrupt completion (throw pending).
// The algorithm:
//  1. If Type(argument) is not Object, return false.
//  2. Let isRegExp be Get(argument, @@match).
//  3. ReturnIfAbrupt(isRegExp).
//  4. If isRegExp is not undefined, return ToBoolean(isRegExp).
//  5. If argument has [[RegExpMatcher]] internal slot, return true.
//  6. Return false.
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
    // ToNumber(Symbol) throws TypeError (ES2022 §7.1.3). This is the single
    // check for both the direct argument and the primitive that
    // builtin_to_number_vm's ToPrimitive produced, which routes back here.
    if (val.is_string()) {
        HString* hs = (HString*)val.get_heapptr();
        if (hs != null && hs.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert a Symbol value to a number");
            return 0.0 / 0.0;
        }
    }
    TVal num;
    builtin_to_number(val, &num);
    if (num.is_fastint()) return (double)num.get_fastint();
    return num.get_number();
}

// ToNumber for builtins with VM access, calls ToPrimitive(value) then ToNumber.
// This properly handles objects by calling valueOf() first, then toString().
fn double builtin_to_number_vm(BuiltinContext* ctx, TVal* val) {
    // Only the object case differs from the plain conversion: it needs
    // ToPrimitive first. Everything else (including the BigInt and Symbol
    // TypeErrors) is builtin_to_number_getdouble's job, and the ToPrimitive
    // result below is handed back to it for exactly those checks.
    if (!val.is_object() || ctx.vm == null) return builtin_to_number_getdouble(ctx, val);
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
        // Both valueOf and toString returned non-primitives, ES2022
        // §7.1.1.1 step 3 throws TypeError. Synthesize a TypeError and
        // flag it on the context so the calling builtin propagates.
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert object to primitive value");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = ctx.heap.str(heap::BuiltinStr.MESSAGE);
                if (msg_key != null) {
                    err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC, ctx.heap);
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

// ToString for builtins with VM access, calls ToPrimitive(value, "string") then ToString.
// This properly handles objects by calling toString() first, then valueOf().
// Throws TypeError if the value is a Symbol (ToString(symbol) must throw per spec).
fn HString* builtin_to_string_vm(BuiltinContext* ctx, TVal* val) {
    if (val != null) val.set_temproot();
    HString* res = null;
    if (val.is_string()) {
        // Symbols cannot be converted to string, ToString(symbol) must throw TypeError.
        HString* s = (HString*)val.get_heapptr();
        if (s != null && s.is_symbol()) {
            arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
            return null;
        }
        res = s;
    } else if (val.is_object() && ctx.vm != null) {
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
            res = ps;
        } else if (!prim.is_object()) {
            res = builtin_to_string(ctx.heap, &prim);
        }
    } else {
        res = builtin_to_string(ctx.heap, val);
    }
    if (res != null) res.set_temproot();
    return res;
}

// ToPropertyKey (ES §7.1.19): like ToString but a Symbol is a valid property
// key and passes through unchanged (Symbols are HString with is_symbol()).
// Use this, not builtin_to_string_vm, anywhere a value is being coerced to a
// property key (defineProperty, hasOwn, getOwnPropertyDescriptor, in, etc.),
// since ToString(Symbol) throws TypeError but a Symbol key must not.
fn HString* builtin_to_property_key_vm(BuiltinContext* ctx, TVal* val) {
    if (val != null) val.set_temproot();
    HString* res = null;
    if (val.is_string()) {
        // Covers both plain strings and Symbols (is_symbol HStrings).
        res = (HString*)val.get_heapptr();
    } else if (val.is_object() && ctx.vm != null) {
        Vm* vm_ptr = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(vm_ptr, val, 1);  // hint "string"
        if (vm_ptr.throw_pending) {
            ctx.should_throw = true;
            ctx.throw_value = vm_ptr.throw_value;
            vm_ptr.throw_pending = false;
            return null;
        }
        if (prim.is_string()) {
            // Plain string or Symbol, both are valid keys, pass through.
            res = (HString*)prim.get_heapptr();
        } else if (!prim.is_object()) {
            res = builtin_to_string(ctx.heap, &prim);
        }
    } else {
        res = builtin_to_string_vm(ctx, val);
    }
    if (res != null) {
        // Property-key comparison is pointer identity, and a string built by
        // concatenation is left un-interned past MAX_INTERN_BYTES. Canonicalize
        // it the way get_prop_key does so find_prop_idx can match it. Symbols
        // pass through: their unique hash keeps them distinct in the table.
        if (!res.flags.is_interned) res = ctx.heap.ensure_interned(res);
        res.set_temproot();
    }
    return res;
}

// ============================================================================
// BuiltinMeta, metadata for LIGHTFUNC builtins
// ============================================================================

// Metadata for LIGHTFUNC builtins: name and expected arity.
// Used by GETPROP to resolve `.name` and `.length` on LIGHTFUNC values.
// Derived directly from the Builtin enum's associated values, see the
// enum declaration for the single per-builtin source of truth.
struct BuiltinMeta {
    char[] name;
    int arity;
}

fn BuiltinMeta builtin_get_metadata(uint idx) {
    if (idx >= Builtin.LAST.ordinal) return { "", -1 };
    Builtin b = (Builtin)idx;
    return { b.js_name, b.js_arity };
}

// ============================================================================
// Registration helpers (shared across submodules)
// ============================================================================

// Helper: register a method on Array.prototype.
// Creates a proper HObject function with .name and .length properties
// (ES6 §17: built-in function objects have non-enumerable .name/.length).
fn bool register_array_proto_method(HObject* proto, Heap* heap, char[] name, uint fn_index) {
    HString* key = heap.str_intern(name);
    if (key == null) return false;
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
            func_obj.put_prop(length_str, len_tv, hobject::PROP_FLAGS_NWC, heap);
        }
    }
    // Set .name (non-writable, non-enumerable, configurable)
    HString* name_prop_key = heap.str(heap::BuiltinStr.NAME);
    HString* name_val = builtin_intern_string(heap, name);
    if (name_prop_key != null && name_val != null) {
        TVal name_tv;
        name_tv.set_string(name_val);
        func_obj.put_prop(name_prop_key, name_tv, hobject::PROP_FLAGS_NWC, heap);
    }
    // Register on prototype, writable:true, enumerable:false, configurable:true (ES5 §15.3.5.1)
    TVal tv;
    tv.set_object(func_obj);
    proto.put_prop(key, tv, hobject::PROP_FLAGS_WC, heap);
    return true;
}

// Helper: compile a JS function expression and register it as a method on a prototype.
// The src must be a complete function expression like "(function(a,b){...})" or "(function name(a){...})".
// Used for callback-based methods (forEach, map, filter, etc.) that can't be LIGHTFUNC builtins.
// length_override: if >= 0, overrides the .length property (for optional params like reduce's initialValue).
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
    HString* name_str = heap.str(heap::BuiltinStr.NAME);
    if (name_str != null) {
        HString* fname = builtin_intern_string(heap, name);
        if (fname != null) {
            TVal name_tv;
            name_tv.set_string(fname);
            func_obj.put_prop(name_str, name_tv, hobject::PROP_FLAGS_NWC, heap);
        }
    }
    HString* length_str = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (length_str != null) {
        TVal len_tv;
        long len_val = length_override >= 0 ? length_override : (long)func.num_formals;
        len_tv.set_fastint(len_val);
        func_obj.put_prop(length_str, len_tv, hobject::PROP_FLAGS_NWC, heap);
    }
    HString* key = heap.str_intern(name);
    if (key == null) return false;
    TVal tv;
    tv.set_object(func_obj);
    proto.put_prop(key, tv, hobject::PROP_FLAGS_WC, heap);
    return true;
}

fn bool register_string_proto_method(HObject* proto, Heap* heap, char[] name, uint fn_index) {
    HString* key = heap.str_intern(name);
    if (key == null) return false;
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
            func_obj.put_prop(length_str, len_tv, hobject::PROP_FLAGS_NWC, heap);
        }
    }
    // Set .name (non-writable, non-enumerable, configurable)
    HString* name_prop_key = heap.str(heap::BuiltinStr.NAME);
    HString* name_val = builtin_intern_string(heap, name);
    if (name_prop_key != null && name_val != null) {
        TVal name_tv;
        name_tv.set_string(name_val);
        func_obj.put_prop(name_prop_key, name_tv, hobject::PROP_FLAGS_NWC, heap);
    }
    // Register on prototype, writable:true, enumerable:false, configurable:true (ES5 §15.3.5.1)
    TVal tv;
    tv.set_object(func_obj);
    proto.put_prop(key, tv, hobject::PROP_FLAGS_WC, heap);
    return true;
}

// Register `alias_name` as an additional name for an already-registered
// method, sharing the *same function object* rather than allocating a second
// one. Several spec aliases (Annex B's String.prototype.trimLeft/trimRight,
// Set.prototype.keys) require identity with their canonical counterpart, and
// the alias keeps the original's `.name`.
fn bool alias_proto_method(HObject* proto, Heap* heap, char[] name, char[] alias_name) {
    HString* key = builtin_intern_string(heap, name);
    HString* alias_key = builtin_intern_string(heap, alias_name);
    if (key == null || alias_key == null) return false;
    PropValue*? prop_opt = proto.find_prop(key, heap);
    if (catch prop_opt) return false;
    proto.put_prop(alias_key, *prop_opt, hobject::PROP_FLAGS_WC, heap);
    return true;
}

fn bool set_num_static_prop(HObject* obj, Heap* heap, char[] name, double val) {
    HString* key = heap.str_intern(name);
    if (key == null) return false;
    TVal tv;
    tv.set_number(val);
    PropFlags pflags;
    pflags.writable = false;
    pflags.enumerable = false;
    pflags.configurable = false;
    pflags.is_accessor = false;
    obj.put_prop(key, tv, pflags, heap);
    return true;
}

fn bool register_named_value(EnvRecord* global_env, Heap* heap, char[] name, TVal val) {
    HString* key = heap.str_intern(name);
    if (key == null) return false;
    return env::env_declare_nonenum(global_env, key, val);
}

// Register a global constant with ES5 §15.1 flags:
// {writable: false, enumerable: false, configurable: false}.
// Used for `undefined`, `NaN`, `Infinity`.
fn bool register_global_immutable(EnvRecord* global_env, Heap* heap, char[] name,
                                   TValTag tag, double number_val, long fastint_val) {
    HString* key = heap.str_intern(name);
    if (key == null) return false;
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
    HString* key = heap.str_intern(name);
    if (key == null) return false;

    TVal val;
    val.set_lightfunc((void*)(usz)fn_index);
    env::env_declare_nonenum(global_env, key, val);
    return true;
}

// Set .name and .length on a built-in constructor HObject.
// .name: non-writable, non-enumerable, configurable (ES6 §19)
// .length: non-writable, non-enumerable, configurable (ES5 §15.3.5.1)
fn void set_func_ctor_name_length(HObject* func_obj, Heap* heap, char[] name, int length) {
    // ES2015 §17: built-in function objects have "length" before "name" in
    // own property insertion order.
    HString* length_key = heap.str(heap::BuiltinStr.LENGTH);
    TVal length_tv; length_tv.set_fastint((long)length);
    func_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    HString* name_key = heap.str(heap::BuiltinStr.NAME);
    HString* name_hstr = builtin_intern_string(heap, name);
    TVal name_tv; name_tv.set_string(name_hstr);
    func_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC, heap);
}

// Set .name on a built-in constructor HObject (when .length is already set).
fn void set_func_ctor_name(HObject* func_obj, Heap* heap, char[] name) {
    HString* name_key = heap.str(heap::BuiltinStr.NAME);
    HString* name_hstr = builtin_intern_string(heap, name);
    TVal name_tv; name_tv.set_string(name_hstr);
    func_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC, heap);
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

// Throw a ReferenceError "Cannot access '<name>' before initialization"
// through the builtin should_throw/throw_value channel (mirrors
// arr_throw_type_error in builtins/array.c3, but with ref_err_proto and
// an interpolated binding name).
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
            HString* msg_key = ctx.heap.str(heap::BuiltinStr.MESSAGE);
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC, ctx.heap);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
}

// Native getter body: recover (source bindings object, binding key) from
// hidden slots on the getter function itself and read the live value.
// Returns undefined if the binding cannot be found. Throws a
// ReferenceError if the source slot still holds the TDZ sentinel (the
// exporting module's `let`/`const`/`class` declaration has not yet run),
// ECMA-262 SS10.4.6.8 / SS16.2.1.5.5 GetBindingValue for a not-yet-initialized
// binding.
//
// A re-export chain (`export { x } from './a'` re-exported again by a
// third module) means the resolved slot in `bindings` can itself be an
// accessor property installed by this same mechanism (one live binding
// pointing at another). Such a slot is unwrapped and its getter invoked
// via ctx.heap.call_fn, exactly mirroring GETVAR's own accessor-chase.
// A single non-recursive lookup would otherwise return the boxed
// getter/setter pair instead of the underlying value.
fn void builtin_module_binding_getter(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    if (ctx.callee_obj == null) return;
    HString* env_slot_key = ctx.heap.str_intern(MODULE_BINDING_ENV_SLOT);
    HString* key_slot_key = ctx.heap.str_intern(MODULE_BINDING_KEY_SLOT);
    if (env_slot_key == null || key_slot_key == null) return;

    int env_idx = ctx.callee_obj.find_prop_idx((void*)env_slot_key, ctx.heap);
    int key_idx = ctx.callee_obj.find_prop_idx((void*)key_slot_key, ctx.heap);
    if (env_idx < 0 || key_idx < 0) return;

    TVal env_tv = ctx.callee_obj.prop_values()[env_idx];
    TVal key_tv = ctx.callee_obj.prop_values()[key_idx];
    if (!env_tv.is_object() || !key_tv.is_string()) return;

    HObject* bindings = (HObject*)env_tv.get_heapptr();
    HString* key = (HString*)key_tv.get_heapptr();
    int idx = bindings.find_prop_idx((void*)key, ctx.heap);
    if (idx < 0) return;

    if (bindings.get_prop_flags((uint)idx, ctx.heap).is_accessor) {
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

// Build an accessor property VALUE (a boxed getter/setter pair, per
// hobject_create_accessors) that live-reads `key` from `source_bindings`
// (a module env's `.bindings` HObject). Callers install it with
// `put_prop(key, value, accessor_flags)`, setting PropFlags.is_accessor.
// Returns an undefined TVal on allocation failure (caller should skip the
// property rather than fail the whole namespace/import).
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
    func_obj.put_prop((void*)env_slot_key, env_tv, hobject::PROP_FLAGS_NWC, heap);
    func_obj.put_prop((void*)key_slot_key, key_tv, hobject::PROP_FLAGS_NWC, heap);

    TVal getter_tv;
    getter_tv.set_object(func_obj);
    TVal undef;
    undef.set_undefined();
    return hobject::hobject_create_accessors(heap, getter_tv, undef);
}

// Module Namespace Exotic [[Get]] for a resolved own STRING key, used by the
// reflective MOP builtins (getOwnPropertyDescriptor, hasOwnProperty,
// Object.keys, propertyIsEnumerable, for-in) to materialise the DATA-descriptor
// `value`. `ns` must be a Module Namespace Exotic Object. Returns:
//   - `found=false` when `key` is not an own property (absent export).
//   - `found=true` with `*out` = the live binding value on success.
// If the export binding is still in TDZ, the invoked getter throws a
// ReferenceError: `heap.has_error` is left set and the caller MUST propagate
// it (via proxy_ctx_ok / returning false) rather than treating the result as a
// value. Export bindings are stored as accessors, this invokes the stored
// getter; a non-export own data property (none exist for string keys today) is
// returned verbatim.
fn bool module_ns_get_binding_value(void* vm, Heap* heap, HObject* ns, HString* key, TVal* out) {
    out.set_undefined();
    int idx = ns.find_prop_idx((void*)key, heap);
    if (idx < 0) return false;
    if (ns.get_prop_flags((uint)idx, heap).is_accessor) {
        TVal slot = ns.prop_values()[idx];
        TVal getter = hobject::hobject_access_getter(slot);
        if (!getter.is_object()) return true;
        TVal this_tv; this_tv.set_object(ns);
        *out = heap.call_fn(vm, getter, null, 0, this_tv);
        // A TDZ binding's getter threw ReferenceError: heap.has_error is now
        // set; leave it for the caller to surface. `*out` is meaningless.
        return true;
    }
    *out = ns.prop_values()[idx];
    return true;
}

// ============================================================================
// Dispatch table
// ============================================================================

// Function-pointer dispatch table, populated once at startup from each
// enum member's `handler` associated value, the single per-builtin source
// of truth declared on Builtin above. Builtin.LAST.ordinal is one past the
// highest valid index; the bounds check in dispatch_builtin mirrors the old
// `default:` arm (set_undefined on the result). Ordinals with no JS-visible
// dispatch path (e.g. reserved/unused builtins) carry a null handler and are
// rejected the same way a missing switch arm used to be.
BuiltinFunc[Builtin.LAST.ordinal] builtin_dispatch_table;

// ============================================================================
// Host functions
// ============================================================================

// Base of the host function index range.
//
// A host function is an ordinary FUNCTION object whose builtin_fn_index is
// HOST_FN_BASE + slot, where slot indexes Heap.host_fns. Two properties make
// this work:
//
//   - It is >= Builtin.LAST.ordinal, so dispatch_builtin's out-of-range
//     branch catches it and routes to dispatch_host.
//   - It is positive as an int, so HObject.callable_kind() reports BUILTIN_FN
//     and every existing dispatch site handles it unchanged.
//
// 2^30 rather than Builtin.LAST.ordinal + 1 so a host index is obvious on
// sight in a debugger, and so adding builtins can never collide with one.
const uint HOST_FN_BASE = 0x4000_0000;

// The host trampoline signature. Mirrors BuiltinFunc, with the host's opaque
// udata alongside the context the VM already staged.
alias HostFunc = fn void(BuiltinContext*, void*);

// Cap on nested host-function dispatches.
//
// A host -> JS -> host chain never pushes a VM activation and never re-enters
// Vm.run, so neither MAX_CALLS nor MAX_RUN_DEPTH counts it, yet every level
// consumes native stack for the dispatch frame and the host's own frame.
// Without this bound a recursive host function faults the stack instead of
// throwing.
//
// The limit is native stack, not any engine structure, so it is set per build
// profile: an unoptimised sanitizer build spends roughly 500 KB of stack per
// level (measured: 16 levels overflow an 8 MB stack, 8 levels survive), while
// an optimised build spends a small fraction of that.
const uint MAX_HOST_DEPTH @if($feature(GC_STRESS)) = 8;
const uint MAX_HOST_DEPTH @if(!$feature(GC_STRESS)) = 32;

// Invoke the host function registered in `slot`.
//
// An unregistered slot yields undefined rather than faulting, so a forged or
// stale index degrades safely. The native_frame_depth bracket matches the one
// dispatch_builtin puts around builtin handlers: host code allocates and can
// re-enter the VM, so temproot flags must survive a safepoint for the whole
// call.
fn void dispatch_host(uint slot, BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    if (heap == null) { ctx.result.set_undefined(); return; }
    heap::HostFnEntry* entry = heap.host_fn_at(slot);
    if (entry == null || entry.handler == null) {
        ctx.result.set_undefined();
        return;
    }
    HostFunc handler = (HostFunc)entry.handler;
    ctx.result.set_undefined();

    // Bound host nesting before touching any VM state, so the caller sees an
    // unmodified engine alongside the pending throw. host_scope_depth is
    // exactly the count of host frames currently on the C3 stack.
    if (heap.host_scope_depth >= MAX_HOST_DEPTH) {
        host_throw_error(ctx, HOST_ERR_RANGE, "Maximum call stack size exceeded");
        return;
    }

    heap.native_frame_depth++;

    // ES2015 §9.2.2 OrdinaryCreateFromConstructor. Builtin constructors
    // allocate their own instance and are handed an undefined this_val
    // (vm_calls.c3:2874); a host function has no way to do that itself, so the
    // instance is created here from new.target's .prototype. Done inside the
    // native_frame_depth bracket so the fresh object's temproot survives any
    // collection the host triggers.
    bool made_this = false;
    if (ctx.is_constructor && !ctx.this_val.is_object()) {
        HObject*? inst_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch inst_raw) {
            heap.native_frame_depth--;
            ctx.should_throw = true;
            ctx.throw_value.set_undefined();
            return;
        }
        HObject* inst = inst_raw;
        inst.prototype = heap.object_proto;
        HObject* src = ctx.new_target != null ? ctx.new_target : ctx.callee_obj;
        if (src != null) {
            HString* proto_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
            if (proto_key != null) {
                TVal? pv = src.get_prop_proto(proto_key, ctx.heap);
                if (try p = pv) {
                    if (p.is_object() && p.get_heapptr() != null) {
                        inst.prototype = (HObject*)p.get_heapptr();
                    }
                }
            }
        }
        ctx.this_val.set_object(inst);
        made_this = true;
    }

    // Copy this/new.target/arguments into a scope the host addresses by
    // handle. Copies rather than register references: a bk_call from inside
    // the handler can grow and realloc the valstack, which would leave
    // ctx.regs dangling (vm_calls.c3:1331 documents the same hazard for
    // builtins, which cope by refreshing — a host holding an opaque handle
    // cannot).
    long scope = heap.host_scope_push();
    if (scope < 0) {
        heap.native_frame_depth--;
        ctx.should_throw = true;
        ctx.throw_value.set_undefined();
        return;
    }
    uint depth = (uint)scope;
    ctx.host_scope_slot = depth + 1;
    heap.host_scope_set(depth, heap::HOST_SCOPE_THIS, ctx.this_val);
    TVal nt;
    if (ctx.new_target != null) { nt.set_object(ctx.new_target); } else { nt.set_undefined(); }
    heap.host_scope_set(depth, heap::HOST_SCOPE_NEW_TARGET, nt);
    for (ushort i = 0; i < ctx.argc; i++) {
        heap.host_scope_set(depth, heap::HOST_SCOPE_ARG0 + i, ctx.regs[ctx.base_reg + i]);
    }

    // Handles the add-on takes out during this call are rooted until it
    // returns. Saving the mark and restoring it, rather than clearing, keeps a
    // nested host call from invalidating its caller's handles.
    uint addon_handle_mark = heap.addon_handle_count;
    handler(ctx, entry.udata);
    heap.addon_handle_count = addon_handle_mark;

    // ES2015 §9.2.2 step 13: a [[Construct]] call evaluates to the created
    // object unless the host explicitly returned an object of its own.
    if (made_this && !ctx.should_throw && !ctx.result.is_object()) {
        *ctx.result = ctx.this_val;
    }

    heap.host_scope_pop();
    ctx.host_scope_slot = 0;
    heap.native_frame_depth--;
}

// ----------------------------------------------------------------------------
// Host accessor API
//
// The surface a host callback uses to read its arguments and produce a result.
// Everything is expressed in TVal here; the C ABI layers opaque handles on top
// (Phase 3). Each function tolerates a null or exhausted context by returning
// undefined rather than faulting, so a misbehaving host cannot corrupt the VM.
// ----------------------------------------------------------------------------

// Number of arguments the call was made with.
fn uint host_argc(BuiltinContext* ctx) {
    return ctx == null ? 0 : (uint)ctx.argc;
}

// Argument `i`, or undefined when `i >= argc`.
//
// Reads from the call scope rather than ctx.regs, so the value stays valid
// across a nested bk_call that reallocates the valstack.
fn TVal host_arg(BuiltinContext* ctx, uint i) {
    TVal out;
    out.set_undefined();
    if (ctx == null || ctx.heap == null) return out;
    if (i >= (uint)ctx.argc) return out;
    if (ctx.host_scope_slot == 0) return out;
    ctx.heap.host_scope_get(ctx.host_scope_slot - 1, heap::HOST_SCOPE_ARG0 + i, &out);
    return out;
}

// The `this` receiver. Undefined stays undefined: the engine is strict-only,
// so there is no coercion to the global object.
fn TVal host_this(BuiltinContext* ctx) {
    TVal out;
    out.set_undefined();
    if (ctx == null || ctx.heap == null) return out;
    if (ctx.host_scope_slot == 0) return out;
    ctx.heap.host_scope_get(ctx.host_scope_slot - 1, heap::HOST_SCOPE_THIS, &out);
    return out;
}

// new.target, or undefined on a plain call.
fn TVal host_new_target(BuiltinContext* ctx) {
    TVal out;
    out.set_undefined();
    if (ctx == null || ctx.heap == null) return out;
    if (ctx.host_scope_slot == 0) return out;
    ctx.heap.host_scope_get(ctx.host_scope_slot - 1, heap::HOST_SCOPE_NEW_TARGET, &out);
    return out;
}

// True when invoked through `new` or `super()`.
fn bool host_is_construct(BuiltinContext* ctx) {
    return ctx != null && ctx.is_constructor;
}

// Set the return value. A host that never calls this yields undefined,
// since every dispatch site initialises its result slot that way.
fn void host_return(BuiltinContext* ctx, TVal v) {
    if (ctx == null || ctx.result == null) return;
    *ctx.result = v;
}

// Throw `v` as-is. Does not unwind: control returns to the host, which must
// then return normally. The dispatch sites check should_throw before result,
// so a throw beats a return.
fn void host_throw(BuiltinContext* ctx, TVal v) {
    if (ctx == null) return;
    ctx.throw_value = v;
    ctx.should_throw = true;
}

// Error kinds selectable by host_throw_error. The values live in
// boomkat::embed::abi, the manifest the C header's BK_ERROR_* enum is
// generated from.
const int HOST_ERR_ERROR     = abi::BK_ERROR;
const int HOST_ERR_TYPE      = abi::BK_ERROR_TYPE;
const int HOST_ERR_RANGE     = abi::BK_ERROR_RANGE;
const int HOST_ERR_REFERENCE = abi::BK_ERROR_REFERENCE;
const int HOST_ERR_SYNTAX    = abi::BK_ERROR_SYNTAX;

// Throw a fresh Error of `kind` carrying `msg`. The ergonomic path, and the
// one bindings use: it spares the host from building an Error through the
// value API.
fn void host_throw_error(BuiltinContext* ctx, int kind, char[] msg) {
    if (ctx == null || ctx.heap == null) return;
    Heap* heap = ctx.heap;
    HObject* proto = heap.err_proto;
    switch (kind) {
        case HOST_ERR_TYPE:      proto = heap.type_err_proto;
        case HOST_ERR_RANGE:     proto = heap.range_err_proto;
        case HOST_ERR_REFERENCE: proto = heap.ref_err_proto;
        case HOST_ERR_SYNTAX:    proto = heap.syntax_err_proto;
        default:                 proto = heap.err_proto;
    }
    HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = proto;
        HString* msg_str = builtin_intern_string(heap, msg);
        HString* msg_key = heap.str(heap::BuiltinStr.MESSAGE);
        if (msg_str != null && msg_key != null) {
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC, ctx.heap);
        }
        ctx.throw_value.set_object(err);
    } else {
        ctx.throw_value.set_undefined();
    }
    ctx.should_throw = true;
}

// Call a JS function from host code.
//
// This is what makes host functions composable rather than leaf-only: without
// it there is no setTimeout, no event emitter, no async I/O. Routes through
// heap.call_fn (vm_call_fn_impl), the same entry point builtins use for user
// callbacks, so the run-depth guard added for native re-entry bounds this too.
//
// Arguments are read from the caller's storage and handed straight through;
// vm_call_fn_impl copies them into its own register window. On an exception
// inside the callee, `ok` is set false and the pending error is transferred to
// the context as a throw, so the host can return immediately and let the
// engine propagate it.
fn TVal host_call(BuiltinContext* ctx, TVal func, TVal* args, uint nargs, TVal this_val, bool* ok) {
    TVal out;
    out.set_undefined();
    if (ok != null) *ok = false;
    if (ctx == null || ctx.heap == null || ctx.vm == null) return out;
    Heap* heap = ctx.heap;
    if (heap.call_fn == null) return out;

    // A non-callable target would otherwise fall through to an undefined
    // result that the host cannot distinguish from a successful call.
    if (!func.is_lightfunc()) {
        if (!func.is_object()) {
            host_throw_error(ctx, HOST_ERR_TYPE, "host_call target is not a function");
            return out;
        }
        HObject* fo = (HObject*)func.get_heapptr();
        if (fo == null || !fo.is_callable()) {
            host_throw_error(ctx, HOST_ERR_TYPE, "host_call target is not a function");
            return out;
        }
    }

    heap.has_error = false;
    TVal res = heap.call_fn(ctx.vm, func, args, nargs, this_val);

    // The callee threw. Move the pending error onto the context so it
    // propagates as this host function's own throw once the handler returns.
    if (heap.has_error) {
        ctx.throw_value = heap.error_value;
        ctx.should_throw = true;
        heap.has_error = false;
        return out;
    }
    if (ok != null) *ok = true;
    return res;
}

// Build a JS string from UTF-8 bytes, interned like every other engine string.
fn TVal host_new_string(BuiltinContext* ctx, char[] utf8) {
    TVal out;
    out.set_undefined();
    if (ctx == null || ctx.heap == null) return out;
    HString* s = builtin_intern_string(ctx.heap, utf8);
    if (s == null) return out;
    out.set_string(s);
    return out;
}

// Build a callable FUNCTION object for the host function in `slot`.
//
// Mirrors register_array_proto_method: .length then .name, both as real own
// properties (ES2015 §17). Setting them here rather than teaching
// builtin_get_metadata about host indices keeps that function pure and its 19
// call sites untouched; those call sites read metadata only as a fallback for
// a missing own property.
// Define `key` on `obj` as a getter-only accessor backed by `getter`. Used by
// the add-on API so a module can expose computed properties without reaching
// into PropFlags or the accessor cell layout itself.
fn bool define_host_accessor(Heap* heap, HObject* obj, HString* key, HObject* getter) {
    if (obj == null || key == null || getter == null) return false;
    TVal getter_tv;
    getter_tv.set_object(getter);
    TVal undef;
    undef.set_undefined();
    hobject::PropFlags acc_flags;
    acc_flags.writable = false;
    acc_flags.enumerable = false;
    acc_flags.configurable = true;
    acc_flags.is_accessor = true;
    obj.put_prop(key, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags, heap);
    return true;
}

fn HObject*? make_host_function(Heap* heap, uint slot) {
    heap::HostFnEntry* entry = heap.host_fn_at(slot);
    if (entry == null) return heap::HEAP_ALLOC_FAULT~;

    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return err~;
    HObject* func_obj = func_raw;

    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)(HOST_FN_BASE + slot);
    // callable_kind() settles on BUILTIN_FN before it reads comp_func, but
    // vm_execute.c3 reads comp_func directly on some paths, so null is the
    // invariant to hold rather than to rely on alloc_object's zeroing for.
    (*func_obj.extra_ptr()).func.comp_func = null;
    func_obj.flags.callable = true;
    func_obj.flags.constructable = entry.constructable;
    func_obj.prototype = heap.function_proto;

    HString* length_str = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (length_str != null) {
        TVal len_tv;
        len_tv.set_fastint((long)(entry.arity >= 0 ? entry.arity : 0));
        func_obj.put_prop(length_str, len_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* name_key = heap.str(heap::BuiltinStr.NAME);
    if (name_key != null && entry.name != null) {
        TVal name_tv;
        name_tv.set_string((HString*)entry.name);
        func_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    // A constructor needs an own .prototype with a .constructor back-reference
    // (ES2015 §17): `new` derives the instance prototype from it, `class D
    // extends HostCtor` rejects a constructor whose .prototype is not an
    // object, and `instanceof` walks it. Non-constructors get none, matching
    // builtin methods and arrow functions.
    if (entry.constructable) {
        HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try proto_obj = proto_raw) {
            proto_obj.prototype = heap.object_proto;
            HString* ctor_key = heap.str(heap::BuiltinStr.CONSTRUCTOR);
            if (ctor_key != null) {
                TVal ctor_tv;
                ctor_tv.set_object(func_obj);
                proto_obj.put_prop(ctor_key, ctor_tv, hobject::PROP_FLAGS_WC, heap);
            }
            HString* proto_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
            if (proto_key != null) {
                TVal proto_tv;
                proto_tv.set_object(proto_obj);
                func_obj.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_NNC, heap);
            }
        }
    }

    return func_obj;
}

fn void init_builtin_dispatch_table() @init
{
    $foreach $b : Builtin::values:
        $if $b != Builtin.LAST:
            builtin_dispatch_table[$b.ordinal] = $b.handler;
        $endif
    $endforeach
}

fn void dispatch_builtin(uint fn_index, BuiltinContext* ctx) {
    // Every dispatch site declares its BuiltinContext uninitialised and fills
    // only the fields builtins read, so this one is stack garbage until set.
    // Clearing it here rather than at the 11 staging sites keeps the invariant
    // at the single chokepoint every call already passes through; a missed
    // site would otherwise read an arbitrary scope index.
    ctx.host_scope_slot = 0;
    if (fn_index >= Builtin.LAST.ordinal) {
        // Host functions live at HOST_FN_BASE and above, so they arrive here
        // rather than at any of the callable_kind() sites: to those a host
        // function is an ordinary BUILTIN_FN, which is what makes new, super(),
        // accessors and bind work with no changes there.
        if (fn_index >= HOST_FN_BASE) {
            dispatch_host(fn_index - HOST_FN_BASE, ctx);
            return;
        }
        ctx.result.set_undefined();
        return;
    }
    BuiltinFunc handler = builtin_dispatch_table[fn_index];
    if (handler == null) {
        ctx.result.set_undefined();
        return;
    }
    // Builtins routinely allocate a result object and then re-enter the VM
    // (user callbacks, getters, species constructors), leaving that object
    // reachable only from a raw C3 local. Marking the frame keeps GC from
    // clearing its temproot at a safepoint inside that nested execution.
    ctx.heap.native_frame_depth++;
    handler(ctx);
    ctx.heap.native_frame_depth--;
}

// ============================================================================
// __resetGlobals, test262 checkpoint/restore
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
            void* key = globals.prop_key_at(i, ctx.heap);
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
            void* key = globals.prop_key_at(idx, ctx.heap);
            if (key == null) continue;
            bool found = false;
            for (uint j = 0; j < heap.checkpoint_count; j++) {
                if (heap.checkpoint_keys[j] == key) { found = true; break; }
            }
            if (!found) { globals.delete_prop(key, ctx.heap); }
        }
        // Restore checkpoint values
        for (uint i = 0; i < heap.checkpoint_count; i++) {
            globals.put_prop(heap.checkpoint_keys[i], heap.checkpoint_vals[i],
                             hobject::PROP_FLAGS_WC, ctx.heap);
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

    // Register escape (Annex B §B.2.1.1)
    if (!register_simple_builtin(global_env, heap, "escape", Builtin.ESCAPE.ordinal)) return false;

    // Register unescape (Annex B §B.2.1.2)
    if (!register_simple_builtin(global_env, heap, "unescape", Builtin.UNESCAPE.ordinal)) return false;

    // Register test262 batch runner helper
    if (!register_simple_builtin(global_env, heap, "__resetGlobals", Builtin.RESET_GLOBALS.ordinal)) return false;

    // Register global constants: NaN, Infinity, undefined
    // ES5 §15.1: these are {writable: false, enumerable: false, configurable: false}
    if (!register_global_immutable(global_env, heap, "NaN", NUMBER, double::nan, 0)) return false;
    if (!register_global_immutable(global_env, heap, "Infinity", NUMBER, double::inf, 0)) return false;
    {
        // Register `undefined`, ES5 §15.1.1 value is the undefined value
        HString* u_key = heap.str_intern("undefined");
        if (u_key == null) return false;
        TVal u_val;
        u_val.set_undefined();
        env::env_declare_immutable(global_env, u_key, u_val);
    }

    // Register Object constructor FIRST, creates Object.prototype (root of all chains)
    if (!register_object_constructor(global_env, heap)) return false;

    // Register Function constructor and prototype (call, apply, bind)
    // MUST be before all other constructors so that prototype methods created
    // by register_string_proto_method / register_array_proto_method / etc.
    // get [[Prototype]] = Function.prototype (heap.function_proto is set here).
    if (!register_function_constructor(global_env, heap)) return false;

    // Register Number constructor (with prototype and static properties)
    if (!register_number_constructor(global_env, heap)) return false;

    // Register BigInt constructor (plan 056), after Object.prototype exists.
    if (!register_bigint_constructor(global_env, heap)) return false;

    // Register Math object
    if (!register_math_object(global_env, heap)) return false;

    // Register JSON object (parse, stringify)
    if (!register_json_object(global_env, heap)) return false;

    // Register Reflect object (empty, spec methods added later as needed)
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
            reflect.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
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
        reflect_raw.put_prop(ownkeys_key, ownkeys_tv, hobject::PROP_FLAGS_WC, heap);

        // Register Reflect property-access methods
        HString* get_key = builtin_intern_string(heap, "get");
        TVal get_tv; get_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_GET.ordinal);
        reflect_raw.put_prop(get_key, get_tv, hobject::PROP_FLAGS_WC, heap);

        HString* set_key = builtin_intern_string(heap, "set");
        TVal set_tv; set_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_SET.ordinal);
        reflect_raw.put_prop(set_key, set_tv, hobject::PROP_FLAGS_WC, heap);

        HString* has_key = builtin_intern_string(heap, "has");
        TVal has_tv; has_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_HAS.ordinal);
        reflect_raw.put_prop(has_key, has_tv, hobject::PROP_FLAGS_WC, heap);

        HString* delete_key = builtin_intern_string(heap, "deleteProperty");
        TVal delete_tv; delete_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_DELETE_PROPERTY.ordinal);
        reflect_raw.put_prop(delete_key, delete_tv, hobject::PROP_FLAGS_WC, heap);

        // Register Reflect descriptor / prototype / extensibility methods
        HString* gopd_key = builtin_intern_string(heap, "getOwnPropertyDescriptor");
        TVal gopd_tv; gopd_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_GET_OWN_PROPERTY_DESCRIPTOR.ordinal);
        reflect_raw.put_prop(gopd_key, gopd_tv, hobject::PROP_FLAGS_WC, heap);

        HString* define_key = builtin_intern_string(heap, "defineProperty");
        TVal define_tv; define_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_DEFINE_PROPERTY.ordinal);
        reflect_raw.put_prop(define_key, define_tv, hobject::PROP_FLAGS_WC, heap);

        HString* getproto_key = builtin_intern_string(heap, "getPrototypeOf");
        TVal getproto_tv; getproto_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_GET_PROTOTYPE_OF.ordinal);
        reflect_raw.put_prop(getproto_key, getproto_tv, hobject::PROP_FLAGS_WC, heap);

        HString* setproto_key = builtin_intern_string(heap, "setPrototypeOf");
        TVal setproto_tv; setproto_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_SET_PROTOTYPE_OF.ordinal);
        reflect_raw.put_prop(setproto_key, setproto_tv, hobject::PROP_FLAGS_WC, heap);

        HString* isext_key = builtin_intern_string(heap, "isExtensible");
        TVal isext_tv; isext_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_IS_EXTENSIBLE.ordinal);
        reflect_raw.put_prop(isext_key, isext_tv, hobject::PROP_FLAGS_WC, heap);

        HString* prevent_key = builtin_intern_string(heap, "preventExtensions");
        TVal prevent_tv; prevent_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_PREVENT_EXTENSIONS.ordinal);
        reflect_raw.put_prop(prevent_key, prevent_tv, hobject::PROP_FLAGS_WC, heap);

        // Register Reflect invocation methods
        HString* apply_key = builtin_intern_string(heap, "apply");
        TVal apply_tv; apply_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_APPLY.ordinal);
        reflect_raw.put_prop(apply_key, apply_tv, hobject::PROP_FLAGS_WC, heap);

        HString* construct_key = builtin_intern_string(heap, "construct");
        TVal construct_tv; construct_tv.set_lightfunc((void*)(usz)Builtin.REFLECT_CONSTRUCT.ordinal);
        reflect_raw.put_prop(construct_key, construct_tv, hobject::PROP_FLAGS_WC, heap);
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

    // Register %IteratorPrototype% (ES6 §25.1.2), shared prototype for all
    // built-in iterators, providing [Symbol.iterator]() that returns `this`.
    if (!register_iterator_prototype(heap)) return false;

    // Register the Iterator global constructor, Iterator.prototype's helper
    // methods (map/filter/take/drop/flatMap/reduce/toArray/forEach/some/
    // every/find), %IteratorHelperPrototype%, and
    // %WrapForValidIteratorPrototype% (ES2025 §27.1).
    if (!register_iterator_ctor_and_helpers(global_env, heap)) return false;

    // Register %AsyncFromSyncIteratorPrototype% (ES2018 §27.1.4), wraps a
    // sync iterator so `for await` can drive it.
    if (!register_async_from_sync_iterator_prototype(heap)) return false;

    // Register the async-generator prototype chain (plan 060, ES2018 §27.4/§27.6):
    // %AsyncIteratorPrototype%, %AsyncGeneratorPrototype%, %AsyncGenerator%,
    // %AsyncGeneratorFunction%.
    if (!register_async_generator(global_env, heap)) return false;

    // Register TypedArray constructors (Int8Array, Uint8Array, etc.)
    if (!register_typed_array_constructors(global_env, heap)) return false;

    // Register ArrayBuffer constructor and prototype (plan 049 stage 1)
    if (!register_arraybuffer(global_env, heap)) return false;

    // Register SharedArrayBuffer constructor and prototype (single-agent)
    if (!register_sharedarraybuffer(global_env, heap)) return false;

    // Register the Atomics namespace object (single-agent)
    if (!register_atomics_object(global_env, heap)) return false;

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
    // (not Object.prototype directly) now that Iterator Helpers exist, this
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
        // NativeErrors (TypeError, RangeError, etc.) are excluded here, their [[Prototype]]
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

    // Register globalThis (ES2020 §19.2.1), points back to the global object itself.
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

// Helper: register all console.* methods on the console object.
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
    HString* key = heap.str_intern(name);
    if (key == null) return false;
    TVal tv;
    tv.set_lightfunc((void*)(usz)fn_index);
    console.put_prop(key, tv, hobject::PROP_FLAGS_WC, heap);
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

// ============================================================================
// LIGHTFUNC promotion
// ============================================================================

// Return the one HObject that represents the builtin behind `fn_idx`,
// materialising it on first use.
//
// Most builtins are stored as a LIGHTFUNC TVal whose whole payload is a builtin
// index. That is enough to call them and it keeps startup from allocating an
// object per builtin, but it means TVal.is_object() is false for JSON.parse,
// Math.max and friends, so every operation that treats a function AS AN OBJECT
// -- ToObject, instanceof, the `in` operator, Reflect.*, defining or assigning
// a property, using it as a Map or WeakSet key -- has nothing to work with.
// Promotion is the single place that turns such a value into the real thing,
// so those operations can be written once against HObject instead of growing
// another LIGHTFUNC special case each.
//
// Identity is the reason this is a cache and not a constructor. `JSON.parse ===
// JSON.parse` holds today only because the builtin index *is* the value: two
// loads of the same property yield bit-identical TVals. If promotion minted a
// fresh object per call, the first program to use a builtin as an object would
// see its identity split in two -- a far worse defect than the ones promotion
// fixes. One slot per Builtin ordinal makes promotion idempotent, so an object
// compared before and after promotion still compares equal.
//
// The cache array is allocated on the first promotion rather than at startup,
// which preserves the point of LIGHTFUNC: a program that only ever calls its
// builtins allocates nothing here. Heap.mark_roots treats the array as a GC
// root, since a promoted builtin is usually reachable from nothing else.
fn HObject* promote_builtin_fn(Heap* heap, uint fn_idx) {
    // Host functions live above the builtin range and already are real
    // FUNCTION objects, so they never reach promotion; a stray index would
    // otherwise run off the end of the cache.
    if (fn_idx >= Builtin.LAST.ordinal) return null;

    if (heap.promoted_builtins == null) {
        usz bytes = (usz)Builtin.LAST.ordinal * HObject*::size;
        void* raw = heap.alloc_func(heap.heap_udata, bytes);
        if (raw == null) return null;
        mem::clear(raw, (sz)bytes);
        heap.promoted_builtins = (HObject**)raw;
        heap.promoted_builtin_capacity = Builtin.LAST.ordinal;
    }

    HObject* cached = heap.promoted_builtins[fn_idx];
    if (cached != null) return cached;

    BuiltinMeta meta = builtin_get_metadata(fn_idx);
    // An internal-only ordinal carries an empty name and -1 arity. It has no
    // JS-visible identity to promote, and ES2015 SS17 requires .name/.length,
    // so fabricating an object for one would invent a function that no program
    // can legitimately hold.
    if (meta.arity < 0) return null;

    HObject* fobj = alloc_builtin_fn(heap, fn_idx, meta.name, meta.arity);
    if (fobj == null) return null;

    // Published before anything else can allocate: alloc_builtin_fn's own
    // allocations (the object, its shape, the interned name) can each trigger a
    // GC, and until the cache slot names the object the only thing keeping it
    // alive is its temproot flag.
    heap.promoted_builtins[fn_idx] = fobj;
    return fobj;
}

// The promoted object for `fn_idx` if one has already been minted, else null.
//
// Read paths use this rather than promote_builtin_fn: a mere property read must
// not allocate, and a builtin that has never been used as an object has no own
// properties beyond the .name/.length the LIGHTFUNC path already synthesises.
// Once promotion HAS happened the object is the authority, because it is where
// an assignment or defineProperty put the new property, and a read that kept
// consulting the metadata table would not see it.
fn HObject* promoted_builtin_fn(Heap* heap, uint fn_idx) @inline {
    if (heap.promoted_builtins == null || fn_idx >= heap.promoted_builtin_capacity) return null;
    return heap.promoted_builtins[fn_idx];
}

// promoted_builtin_fn for a TVal: the already-promoted object behind a
// LIGHTFUNC, or null for anything else.
fn HObject* promoted_lightfunc_obj(Heap* heap, TVal val) @inline {
    if (!val.is_lightfunc()) return null;
    return promoted_builtin_fn(heap, (uint)(usz)val.get_heapptr());
}

// Promote `val` in place when it is a LIGHTFUNC, so a caller that needs a real
// object can go on to treat every callable uniformly. Any other value is left
// exactly as it was, including an already-promoted OBJECT, which keeps this
// safe to call on the way into a shared path without a tag test at each site.
//
// Returns false only when a LIGHTFUNC could not be promoted (allocation failure
// or an internal-only ordinal), in which case `val` is untouched and the caller
// should fall back to its non-object behaviour.
fn bool promote_lightfunc_tval(Heap* heap, TVal* val) {
    if (!val.is_lightfunc()) return true;
    HObject* fobj = promote_builtin_fn(heap, (uint)(usz)val.get_heapptr());
    if (fobj == null) return false;
    val.set_object(fobj);
    return true;
}

// test262 host globals: __evalScript, __detachArrayBuffer, and the $262
// object (detachArrayBuffer / evalScript / global) expected by harness
// files. Installed only by the test harness binaries, never part of the
// default engine globals.
fn bool register_test262_host(EnvRecord* global_env, Heap* heap) {
    // Every allocated object is declared on the global env (a GC root)
    // before the next allocation, an allocation-triggered GC would
    // otherwise collect the not-yet-reachable objects.
    HString* es_key = builtin_intern_string(heap, "__evalScript");
    HString* d_hidden_key = builtin_intern_string(heap, "__detachArrayBuffer");
    HString* h262_key = builtin_intern_string(heap, "$262");
    HString* d_key = builtin_intern_string(heap, "detachArrayBuffer");
    HString* e_key = builtin_intern_string(heap, "evalScript");
    HString* g_key = heap.str(heap::BuiltinStr.GLOBAL);
    if (es_key == null || d_hidden_key == null || h262_key == null
        || d_key == null || e_key == null || g_key == null) return false;

    // __evalScript(src), runs src as a global script so that var/function
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

    h262.put_prop(d_key, detach_tv, hobject::PROP_FLAGS_WC, heap);
    h262.put_prop(e_key, es_tv, hobject::PROP_FLAGS_WC, heap);
    if (global_env.bindings != null) {
        TVal g_tv;
        g_tv.set_object(global_env.bindings);
        h262.put_prop(g_key, g_tv, hobject::PROP_FLAGS_WC, heap);
    }
    return true;
}
