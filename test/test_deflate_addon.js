// 1. one-shot namespace fns
// Long enough that deflate's block overhead is outweighed; a 47-byte input
// actually grows, which is correct deflate behaviour, not a bug.
const s = "hello hello ".repeat(40);
console.log("compress:", Deflate.compress(s) < s.length ? "smaller OK" : "FAIL");
console.log("roundtrip:", Deflate.roundtrip(s) === s ? "OK" : "FAIL got " + Deflate.roundtrip(s));

// 2. host class with payload state
const d = new Deflater();
console.log("initial bytesIn:", d.bytesIn);
d.push("abc");
d.push("defg");
console.log("after push:", d.bytesIn, d.bytesIn === 7 ? "OK" : "FAIL");

// 3. the load-bearing test: a tag held ONLY by the payload, across a GC.
const tagged = new Deflater({ marker: "survive-me", n: 42 });
for (let i = 0; i < 200000; i++) { const junk = { a: i, b: [i, i + 1] }; }
const t = tagged.tag;
console.log("tag survived GC:", t && t.marker === "survive-me" && t.n === 42 ? "OK" : "FAIL " + JSON.stringify(t));

// 4. brand check
try { Deflater.prototype.push.call({}, "x"); console.log("brand check: FAIL"); }
catch (e) { console.log("brand check:", e instanceof TypeError ? "OK" : "FAIL " + e); }
