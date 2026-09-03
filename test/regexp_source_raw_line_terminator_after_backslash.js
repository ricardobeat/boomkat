// EscapeRegExpPattern (ES2022 21.2.3.2.4), used to compute RegExp.prototype
// .source and .toString(), replaces every raw LineTerminator character
// (LF, CR, U+2028, U+2029) with its two/six-character escape sequence,
// operating on the pattern's characters directly with no notion of
// "already escaped" -- there is no such state in the algorithm.
//
// escape_regexp_pattern's "copy an existing backslash-escape pair verbatim"
// fast path (needed so backslash-slash, backslash-bracket etc. round-trip
// unchanged) didn't account for the escaped character itself being a RAW
// LineTerminator BYTE (not the two-character sequence backslash-n) -- e.g.
// RegExp("\\\n"), a JS string whose value is a literal backslash followed
// by an actual LF byte. That pair got copied through unchanged instead of
// collapsing to the \n escape, leaving a real newline byte inside .source,
// which can't round-trip through a RegularExpressionLiteral
// (eval("/" + re.source + "/") would be a SyntaxError).

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
        failures++;
    }
}

// RegExp("\\\n") -- pattern is [backslash, LF], 2 chars.
check("backslash + raw LF collapses to \\n", RegExp("\\\n").source, "\\n");
// RegExp("\\\r") -- pattern is [backslash, CR], 2 chars.
check("backslash + raw CR collapses to \\r", RegExp("\\\r").source, "\\r");
// RegExp("\\" + LS/PS) -- pattern is [backslash, U+2028 or U+2029], 2 chars.
check("backslash + raw LS collapses to \\u2028", RegExp("\\" + " ").source, "\\u2028");
check("backslash + raw PS collapses to \\u2029", RegExp("\\" + " ").source, "\\u2029");

// Sanity: genuinely already-escaped pairs still round-trip unchanged.
check("existing backslash-slash pair is untouched", RegExp("a\\/b").source, "a\\/b");
check("existing backslash-n (2-char sequence, not a raw LF) is untouched", RegExp("\\n").source, "\\n");

// The result must be re-embeddable as a RegularExpressionLiteral.
var re = RegExp("\\\n");
var roundTripped = eval("/" + re.source + "/");
check("escaped source round-trips through eval", roundTripped.source, re.source);

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
