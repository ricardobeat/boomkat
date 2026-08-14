// String.prototype.split and .trim staged each result piece through a
// `char[256]` buffer and CLAMPED the copy to 256 bytes: `copy_len = substr_len
// < 256 ? substr_len : 256`. Any piece longer than 255 bytes was silently
// truncated -- no error, no crash, just a shorter string.
//
// The worst case is the no-match split, `s.split(absent)`, which must yield
// [s] unchanged: every string over 255 bytes came back cut to 256. That is what
// broke semver's regexp builder inside a real bundle, whose `g()` helper is a
// chain of `str.split(x).join(y)` passes -- each pass truncated the pattern
// further until it ended mid-group and RegExp rejected it.
//
// Both pieces are already contiguous in the source string, so the staging
// buffer bought nothing and only imposed the cap.
var out = [];
function t(name, got, want) {
    out.push((got === want ? "ok  " : "FAIL") + " " + name + " => " + String(got));
}

function rep(s, n) { var r = ""; for (var i = 0; i < n; i++) { r += s; } return r; }

// 1. No-match split returns the whole string, at every length around the cap.
var lens = [1, 100, 254, 255, 256, 257, 400, 1000, 5000];
for (var i = 0; i < lens.length; i++) {
    var s = rep("x", lens[i]);
    var parts = s.split("NOT-PRESENT");
    t("nomatch-parts-" + lens[i], parts.length, 1);
    t("nomatch-len-" + lens[i], parts[0].length, lens[i]);
    t("nomatch-identity-" + lens[i], parts[0] === s, true);
}

// 2. Every piece of a matching split keeps its full length, including the tail
//    (which the second clamp handled separately from the per-match pieces).
var head = rep("a", 300);
var mid = rep("b", 700);
var tail = rep("c", 500);
var joined = head + "|" + mid + "|" + tail;
var three = joined.split("|");
t("split3-count", three.length, 3);
t("split3-head", three[0].length, 300);
t("split3-mid", three[1].length, 700);
t("split3-tail", three[2].length, 500);
t("split3-roundtrip", three.join("|") === joined, true);

// 3. split(...).join(...) is refcount- and length-neutral when the separator is
//    absent -- the semver `g()` shape, which chains several such passes.
var pattern = rep("\\d*", 200);
var pass = pattern.split("ZZZ").join("Q");
t("splitjoin-nomatch-len", pass.length, pattern.length);
var chained = pattern;
for (var k = 0; k < 4; k++) { chained = chained.split("ABSENT").join("Q"); }
t("splitjoin-chained-len", chained.length, pattern.length);

// A real substitution chain must GROW, never shrink.
var grow = rep("\\d*", 60);
var grown = grow.split("\\d*").join("\\d{0,256}");
t("splitjoin-grows", grown.length, 60 * "\\d{0,256}".length);

// 4. A regexp built by such a chain still compiles: the original symptom was
//    "invalid group" from a pattern cut off mid-`(?:`.
var built = rep("(?:a|b)", 80).split("(?:").join("(?:");
t("built-len", built.length, 80 * 7);
var ok = true;
try { new RegExp(built); } catch (e) { ok = false; out.push("FAIL regexp-compiles => " + e.message); }
t("regexp-compiles", ok, true);

// 5. trim staged through the same clamped buffer.
for (var m = 0; m < lens.length; m++) {
    var body = rep("y", lens[m]);
    t("trim-len-" + lens[m], ("   " + body + "   ").trim().length, lens[m]);
    t("trim-identity-" + lens[m], ("\n\t" + body + " \r").trim() === body, true);
}
t("trim-all-space", "     ".trim().length, 0);
t("trim-empty", "".trim().length, 0);
t("trim-no-space", rep("z", 900).trim().length, 900);

for (var n = 0; n < out.length; n++) { console.log(out[n]); }
