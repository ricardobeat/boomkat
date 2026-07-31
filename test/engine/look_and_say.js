// Look-and-say sequence
// Each term describes the run-length encoding of the previous.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function lookAndSay(s) {
    var out = "";
    var i = 0;
    while (i < s.length) {
        var ch = s[i];
        var count = 0;
        for (var j = i; j < s.length; j++) {
            if (s[j] === ch) count++;
            else break;
        }
        out += count + ch;
        i += count;
    }
    return out;
}

assert(lookAndSay("1") === "11", "1 -> 11");
assert(lookAndSay("11") === "21", "11 -> 21");
assert(lookAndSay("21") === "1211", "21 -> 1211");
assert(lookAndSay("1211") === "111221", "1211 -> 111221");
assert(lookAndSay("111221") === "312211", "111221 -> 312211");

// Build sequence up to n terms
function lookAndSaySeq(n) {
    var seq = ["1"];
    for (var i = 1; i < n; i++) seq.push(lookAndSay(seq[i - 1]));
    return seq;
}

var seq = lookAndSaySeq(7);
assert(seq.length === 7, "seq length");
assert(seq[0] === "1", "seq[0]");
assert(seq[1] === "11", "seq[1]");
assert(seq[5] === "312211", "seq[5]");
assert(seq[6] === "13112221", "seq[6]");

// Length property: each term grows
assert(seq[6].length > seq[5].length, "term 7 grows");
assert(seq[5].length === 6, "term 6 length 6");

print("engine/look_and_say: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");