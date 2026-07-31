// Run-length encoding
// Compress consecutive duplicates: "AAA" -> "3A".

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function encode(s) {
    if (s.length === 0) return "";
    var out = "";
    var i = 0;
    while (i < s.length) {
        var ch = s[i];
        var count = 0;
        for (var j = i; j < s.length; j++) {
            if (s[j] !== ch) break;
            count++;
        }
        if (count > 1) out += count + ch;
        else out += ch;
        i += count;
    }
    return out;
}

function isDigit(ch) {
    var c = ch.charCodeAt(0);
    return c >= 48 && c <= 57;
}

function decode(s) {
    var out = "";
    var i = 0;
    while (i < s.length) {
        var ch = s[i];
        if (isDigit(ch)) {
            var n = 0;
            while (i < s.length && isDigit(s[i])) {
                n = n * 10 + (s.charCodeAt(i) - 48);
                i++;
            }
            var runChar = s[i];
            for (var k = 0; k < n; k++) out += runChar;
            i++;
        } else {
            out += ch;
            i++;
        }
    }
    return out;
}

assert(encode("") === "", "encode empty");
assert(encode("A") === "A", "encode single");
assert(encode("AAA") === "3A", "encode AAA");
assert(encode("AAABBB") === "3A3B", "encode AAABBB");
assert(encode("ABAB") === "ABAB", "encode ABAB");
assert(encode("WWWWAAAR") === "4W3AR", "encode WWWWAAAR");
assert(encode("  hi") === "2 hi", "encode '  hi'");

assert(decode("") === "", "decode empty");
assert(decode("A") === "A", "decode A");
assert(decode("3A") === "AAA", "decode 3A");
assert(decode("3A3B") === "AAABBB", "decode 3A3B");
assert(decode("ABAB") === "ABAB", "decode ABAB");
assert(decode("4W3AR") === "WWWWAAAR", "decode 4W3AR");

// Round trip
function roundTrip(s) { return decode(encode(s)); }
assert(roundTrip("") === "", "rt empty");
assert(roundTrip("hello world") === "hello world", "rt hello world");
assert(roundTrip("aaaaa") === "aaaaa", "rt aaaaa");

// Compression of repeated input
var compressed = encode("aaaaaaaaaaaaaaaaaaaaa");
assert(compressed.length < 21, "compresses well");

print("engine/run_length: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");