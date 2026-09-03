// EscapeRegExpPattern (ES2024 22.2.6.13.1) must escape the LineTerminators
// so `source` round-trips: `/<source>/` has to re-parse to the same pattern.
//
// The pattern is stored as UTF-8, but the escape loop compared a single
// BYTE against U+2028 / U+2029, which can never match a three-byte
// sequence (E2 80 A8 / E2 80 A9), so LS and PS were emitted raw and the
// result was not a valid RegularExpressionLiteral.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + JSON.stringify(expected) +
              ", got " + JSON.stringify(actual));
        failures++;
    }
}

var LS = "\u2028", PS = "\u2029";

check("LS is escaped", new RegExp(LS).source, "\\u2028");
check("PS is escaped", new RegExp(PS).source, "\\u2029");
check("LS+PS together", new RegExp(LS + PS).source, "\\u2028\\u2029");
check("toString wraps escaped source", new RegExp(LS + PS).toString(), "/\\u2028\\u2029/");
check("LS inside a character class", new RegExp("[" + LS + "]").source, "[\\u2028]");

// The other line terminators and `/` were already handled; keep them covered
// so a change to this loop cannot regress them silently.
check("LF", new RegExp("\n").source, "\\n");
check("CR", new RegExp("\r").source, "\\r");
check("slash", new RegExp("/").source, "\\/");
check("empty pattern", new RegExp("").source, "(?:)");

// Escaping must not disturb any other multi-byte character.
check("2-byte char", new RegExp("é").source, "é");
check("3-byte CJK", new RegExp("中文").source, "中文");
check("4-byte emoji", new RegExp("😀").source, "😀");
// Bytes adjacent to LS/PS in the same E2 80 xx block must stay raw.
check("U+2027 stays raw", new RegExp("\u2027").source, "\u2027");
check("U+202A stays raw", new RegExp("\u202A").source, "\u202A");

// Round-trip: the escaped source must re-parse and still match the original.
check("LS round-trips",  eval("/" + new RegExp(LS).source + "/").test(LS), true);
check("PS round-trips",  eval("/" + new RegExp(PS).source + "/").test(PS), true);
check("mixed round-trips",
      eval("/" + new RegExp("a" + LS + "b/c\nd").source + "/").test("a" + LS + "b/c\nd"), true);

// Matching itself is unaffected by how the source is spelled.
check("LS still matches", new RegExp(LS).test(LS), true);
check("emoji still matches", new RegExp("😀").test("😀"), true);

if (failures === 0) { print("regexp_source_line_terminator_escape: all checks passed"); }
