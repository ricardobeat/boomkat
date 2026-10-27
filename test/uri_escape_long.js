// encodeURI/escape/unescape/decodeURI handle strings far beyond a fixed buffer.
function check(cond, msg) { if (!cond) throw new Error(msg); }
var s = "a b".repeat(40000);
var enc = encodeURIComponent(s);
check(enc.length === 40000 * 5, "encodeURIComponent length " + enc.length);
check(decodeURIComponent(enc) === s, "decodeURIComponent round trip");
var e = escape(s);
check(e.length === 40000 * 5, "escape length " + e.length);
check(unescape(e) === s, "unescape round trip");
var w = "\u00e9\ud83d\ude00".repeat(30000);
check(decodeURIComponent(encodeURIComponent(w)) === w, "astral round trip");
check(unescape(escape(w)) === w, "escape astral round trip");
check(escape("\ud83d\ude00") === "%uD83D%uDE00", "escape pairs");
var threw = false;
try { encodeURIComponent("\ud800"); } catch (x) { threw = x instanceof URIError; }
check(threw, "lone surrogate throws");
print("ok");
