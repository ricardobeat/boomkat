// ABI manifest.
//
// The single source of truth for the numeric constants the C ABI exposes.
// scripts/gen_abi_header.py regenerates the matching enum blocks of
// include/boomkat.h from this file, and `make check-abi` fails when the two
// drift apart. The block markers (`// [abi:NAME]`) are what the generator
// keys on; each constant's trailing comment becomes its header comment.
//
// This module imports nothing so both boomkat::embed and boomkat::builtins
// can use it without a module cycle.
module boomkat::embed::abi;

// [abi:status]
const int BK_OK            = 0;
const int BK_ERR_NOMEM     = -1;  // allocation failed
const int BK_ERR_SYNTAX    = -2;  // compile failed
const int BK_ERR_THROW     = -3;  // uncaught JS exception
const int BK_ERR_INTERNAL  = -4;  // engine fault with no JS error attached
const int BK_ERR_INVALID   = -5;  // null/bad argument, or a handle from elsewhere
const int BK_ERR_TYPE      = -6;  // value is not of the requested type
const int BK_ERR_FULL      = -7;  // buffer too small, or the registry is full
const int BK_ERR_INTERRUPT = -8;  // aborted by the interrupt handler

// [abi:type]
const int BK_TYPE_UNDEFINED = 0;
const int BK_TYPE_NULL      = 1;
const int BK_TYPE_BOOLEAN   = 2;
const int BK_TYPE_NUMBER    = 3;
const int BK_TYPE_STRING    = 4;
const int BK_TYPE_OBJECT    = 5;
const int BK_TYPE_FUNCTION  = 6;
const int BK_TYPE_OTHER     = 7;  // symbol, bigint, etc.

// [abi:errkind]
const int BK_ERROR           = 0;
const int BK_ERROR_TYPE      = 1;
const int BK_ERROR_RANGE     = 2;
const int BK_ERROR_REFERENCE = 3;
const int BK_ERROR_SYNTAX    = 4;
