loadAddon("addons/deflate/deflate.dylib");

const s = "hello hello ".repeat(40);
console.log("compress:", Deflate.compress(s) < s.length ? "smaller OK" : "FAIL");
console.log("roundtrip:", Deflate.roundtrip(s) === s ? "OK" : "FAIL");

const d = new Deflater();
d.push("abc"); d.push("defg");
console.log("bytesIn:", d.bytesIn, d.bytesIn === 7 ? "OK" : "FAIL");

const tagged = new Deflater({ marker: "survive-me", n: 42 });
for (let i = 0; i < 200000; i++) { const junk = { a: i, b: [i, i+1] }; }
const t = tagged.tag;
console.log("tag survived GC:", t && t.marker === "survive-me" && t.n === 42 ? "OK" : "FAIL " + JSON.stringify(t));

try { Deflater.prototype.push.call({}, "x"); console.log("brand check: FAIL"); }
catch (e) { console.log("brand check:", e instanceof TypeError ? "OK" : "FAIL"); }
