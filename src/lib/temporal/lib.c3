// boomkat::lib::temporal — proleptic Gregorian calendar arithmetic, ISO 8601
// formatting, and an IANA tzdb lookup, expressed as value types. No engine
// dependencies: imports only `boomkat::lib::bigmath` and std::*.
//
// Two consumers in this project:
//   - src/builtins/date.c3     (lifted from here for shared calendar math)
//   - src/builtins/temporal.c3 (the JS-bound Temporal implementation)
//
// Liftable as a standalone library: drop the src/lib/temporal/ and
// src/lib/bigmath/ directories into another C3 project with stdlib available
// and the calendar/timezone arithmetic compiles unchanged.
module boomkat::lib::temporal;

import std::math;
import std::core::string;
import std::core::ascii;

// ASCII case-insensitive equality (the ISO calendar identifiers and their
// `u-ca=` annotation values are matched case-insensitively). `String` is a
// distinct inline typedef, so the stdlib method needs an explicit cast.
fn bool ci_equals(char[] a, char[] b) {
    return ((String)a).compare_to_ignore_case((String)b) == 0;
}
