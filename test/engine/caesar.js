// Caesar cipher
// Letter-shift cipher.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function caesar(text, shift) {
    var out = "";
    for (var i = 0; i < text.length; i++) {
        var c = text.charCodeAt(i);
        if (c >= 65 && c <= 90) {
            out += String.fromCharCode(((c - 65 + shift) % 26 + 26) % 26 + 65);
        } else if (c >= 97 && c <= 122) {
            out += String.fromCharCode(((c - 97 + shift) % 26 + 26) % 26 + 97);
        } else {
            out += text[i];
        }
    }
    return out;
}

assert(caesar("HELLO", 3) === "KHOOR", "HELLO+3=KHOOR");
assert(caesar("hello", 3) === "khoor", "hello+3=khoor");
assert(caesar("ABC", 1) === "BCD", "ABC+1=BCD");
assert(caesar("XYZ", 3) === "ABC", "XYZ+3=ABC (wraps)");
assert(caesar("abc", -1) === "zab", "abc-1=zab");
assert(caesar(caesar("HELLO", 3), -3) === "HELLO", "round trip");
assert(caesar("Hello", 26) === "Hello", "shift 26 = identity");
assert(caesar("Hello, World!", 5) === "Mjqqt, Btwqi!", "Hello World+5");

print("engine/caesar: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");