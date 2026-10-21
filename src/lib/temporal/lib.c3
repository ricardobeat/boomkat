// boomkat::lib::temporal — proleptic Gregorian calendar arithmetic, ISO 8601
// formatting, and an IANA tzdb lookup, expressed as value types. No engine
// dependencies: imports only the C3 standard library.
//
// Consumers: src/builtins/date.c3 (calendar math lifted from here) and
// src/builtins/temporal/ (the JS-bound Temporal implementation).
//
// Standalone: copy src/lib/temporal/ into another C3 project with stdlib
// available and the calendar/timezone arithmetic compiles unchanged.
module boomkat::lib::temporal;

import std::math;
