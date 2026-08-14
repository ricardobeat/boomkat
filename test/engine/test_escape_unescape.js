// escape / unescape (ES2024 Annex B §B.2.1.1 and §B.2.1.2) were missing from
// the global object entirely. They are legacy but spec-mandated globals, not
// host APIs: cryptojs's bundle calls unescape() internally and died with
// "unescape is not defined".
//
// They are not encodeURIComponent/decodeURIComponent in disguise. escape's
// unescaped set is `A-Za-z0-9@*_+-./` -- `@ * + /` pass through where
// encodeURIComponent escapes them, and `! ~ ' ( )` are escaped where
// encodeURIComponent passes them. escape also iterates UTF-16 *code units*,
// so a surrogate pair is emitted as two `%uXXXX` escapes rather than being
// recombined into one astral codepoint's UTF-8 bytes, and a lone surrogate is
// legal rather than a URIError. Expectations cross-checked against qjs.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " -- expected " + expected + " got " + actual);
        failures++;
    }
}

check("typeofEscape", typeof escape, "function");
check("typeofUnescape", typeof unescape, "function");

// --- escape: unescaped set, %XX for < 256, %uXXXX above ---
check("escapeSpaceBang", escape("hello world!"), "hello%20world%21");
check("escapeUnreserved", escape("@*_+-./"), "@*_+-./");
check("escapeNotUriComponentSet", escape("~!'()"), "%7E%21%27%28%29");
check("escapeLatin1", escape("café"), "caf%E9");
check("escapeAboveFF", escape("☃"), "%u2603");
// a surrogate pair stays two code units, it is not recombined
check("escapeAstral", escape("😀"), "%uD83D%uDE00");
check("escapeLoneSurrogate", escape("\ud83d"), "%uD83D");
check("escapeNoArgs", escape(), "undefined");

// --- unescape: reverses both forms, passes bad escapes through verbatim ---
check("unescapeBasic", unescape("hello%20world%21"), "hello world!");
check("unescapeFour", unescape("%u2603"), "☃");
check("unescapeAstral", unescape("%uD83D%uDE00"), "😀");
check("unescapeTruncatedTwo", unescape("%2"), "%2");
check("unescapeNonHex", unescape("%zz"), "%zz");
check("unescapeTruncatedFour", unescape("%u12"), "%u12");
check("unescapeBareU", unescape("%u"), "%u");
check("unescapeDoublePercent", unescape("a%%20b"), "a% b");

check("roundtrip", unescape(escape("café ☃")), "café ☃");
check("escapeLength", escape.length, 1);
check("unescapeLength", unescape.length, 1);

if (failures === 0) {
    print("PASS: escape and unescape (Annex B)");
} else {
    print("FAILED: " + failures + " check(s)");
}
