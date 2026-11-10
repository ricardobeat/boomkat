// String.prototype.charCodeAt called as a method with one argument, through
// the inline path and every case that leaves it.
var log = [];
function at(s, i) { return s.charCodeAt(i); }
function warm() { for (var k = 0; k < 200; k++) at("warm", k & 3); }
warm();
log.push([at("abc", 0), at("abc", 2), at("abc", 3), at("abc", -1), at("abc", 1.5), at("abc", "1"),
          at("abc", NaN), at("abc", undefined), at("abc", null), at("abc", 4294967296), at("abc", 2147483648),
          at("", 0), at("été", 0), at("a世", 1), at("😀", 1), at("\x00", 0)].join());
log.push([at(new String("xyz"), 1), at(Symbol("q").description, 0), at(12345 + "", 4)].join());
try { at(null, 0); } catch (e) { log.push(e instanceof TypeError); }
try { at(undefined, 0); } catch (e) { log.push(e instanceof TypeError); }
try { at({}, 0); } catch (e) { log.push(e instanceof TypeError); }
try { at(Symbol("s"), 0); log.push("sym ok"); } catch (e) { log.push(e instanceof TypeError); }
var obj = { charCodeAt: function (i) { return "obj" + i; } };
log.push(at(obj, 5));
var s1 = "abcdef";
var s2 = s1 + "ghi";
var r = "";
for (var i = 0; i < 12; i++) r += at(s2, i) + ",";
log.push(r);
var wide = "abĀcd";
r = "";
for (var i = 0; i < 6; i++) r += at(wide, i) + ",";
log.push(r);
var ropeLike = "";
for (var i = 0; i < 50; i++) ropeLike += String.fromCharCode(65 + (i % 26));
r = 0;
for (var i = 0; i < 50; i++) r += at(ropeLike, i);
log.push(r);
var saved = String.prototype.charCodeAt;
String.prototype.charCodeAt = function (i) { return -7; };
log.push(at("abc", 1));
String.prototype.charCodeAt = saved;
log.push(at("abc", 1));
Object.defineProperty(Number.prototype, "charCodeAt", { value: function (i) { return "num" + i + this; }, configurable: true });
log.push(at(5, 2));
var f = String.prototype.charCodeAt;
log.push(f.call("hi", 1));
var bound = f.bind("bound");
log.push(bound(2));
function ex(s, i) { var o = { s: s }; return o.s.charCodeAt(i) + 1; }
for (var k = 0; k < 100; k++) ex("loop", k % 4);
log.push(ex("zz", 1), ex("zz", 9));
// Latin-1 strings, whose units are their bytes as for ASCII ones, built at run time and in a hot
// loop, next to wide ones.
var bin = "";
for (var i = 0; i < 256; i++) bin += String.fromCharCode(i);
var sum = 0;
for (var k = 0; k < 40; k++) for (var i = 0; i < 260; i++) { var c = at(bin, i); sum += c === c ? c : 1000; }
log.push(sum, at("é", 0), at("\xff\x80", 1), at(bin + "Ā", 255), at(bin + "Ā", 256));
print(log.join("\n"));
