// String methods index and compare by UTF-16 code unit whatever the characters.
function eq(a, b, msg) {
    if (!Object.is(a, b)) throw new Error(msg + ": got " + JSON.stringify(a) + ", want " + JSON.stringify(b));
}

const mixed = "a\u00e9\u4e2d\ud83d\ude00z\ud800";
eq(mixed.length, 7, "length");
eq(mixed.charCodeAt(3), 0xd83d, "high half");
eq(mixed.charCodeAt(4), 0xde00, "low half");
eq(mixed.codePointAt(3), 0x1f600, "codePointAt pair");
eq(mixed.codePointAt(6), 0xd800, "codePointAt lone");
eq(mixed.at(-1), "\ud800", "at");
eq(mixed.indexOf("\ud83d\ude00"), 3, "indexOf pair");
eq(mixed.indexOf("z", 5), 5, "indexOf from");
eq(mixed.indexOf("", 99), 7, "indexOf empty past end");
eq(mixed.lastIndexOf("\u4e2d"), 2, "lastIndexOf");
eq(mixed.lastIndexOf("a", 0), 0, "lastIndexOf at 0");
eq(mixed.slice(2, 5), "\u4e2d\ud83d\ude00".slice(0, 3), "slice");
eq(mixed.substring(5, 1), "\u00e9\u4e2d\ud83d\ude00", "substring swap");
eq(mixed.substr(-3, 2), "\ude00z", "substr negative");
eq(mixed.split("").length, 7, "split units");
eq(mixed.split("\u4e2d").join("|"), "a\u00e9|\ud83d\ude00z\ud800", "split on cjk");
eq(mixed.replace("\u4e2d", "[$&|$`|$']"), "a\u00e9[\u4e2d|a\u00e9|\ud83d\ude00z\ud800]\ud83d\ude00z\ud800", "replace substitution");
eq("\u00e9\u00e9".replaceAll("\u00e9", "e"), "ee", "replaceAll latin1");
eq("".replaceAll("", "-"), "-", "replaceAll empty");
eq("\ud83d\ude00".replaceAll("", "-"), "-\ud83d-\ude00-", "replaceAll empty splits pair");
eq(mixed.startsWith("\u00e9", 1), true, "startsWith");
eq(mixed.endsWith("z", 6), true, "endsWith");
eq(mixed.includes("\ud800", 6), true, "includes");
eq("\u4e2d".padStart(4, "\ud83d\ude00"), "\ud83d\ude00\ud83d\u4e2d", "padStart cuts the fill");
eq("x".padEnd(3, "\u00e9"), "x\u00e9\u00e9", "padEnd");
eq("\u00e9".repeat(3), "\u00e9\u00e9\u00e9", "repeat");
eq("\u00a0\u3000 x \u2028".trim(), "x", "trim unicode");
eq("\u00a0x".trimStart(), "x", "trimStart");
eq("x\u00a0".trimEnd(), "x", "trimEnd");
eq(mixed.isWellFormed(), false, "isWellFormed");
eq(mixed.toWellFormed(), "a\u00e9\u4e2d\ud83d\ude00z\ufffd", "toWellFormed");
eq("\u00c5".toLowerCase(), "\u00e5", "toLowerCase latin1");
eq("\u00df".toUpperCase(), "SS", "toUpperCase expands");
eq("\ud801\udc00".toLowerCase(), "\ud801\udc28", "toLowerCase astral");
eq("A\u030a".normalize("NFC"), "\u00c5", "normalize");
eq(String.fromCharCode(0xd83d, 0xde00), "\ud83d\ude00", "fromCharCode");
eq(String.fromCodePoint(0x1f600, 0x41), "\ud83d\ude00A", "fromCodePoint");
eq(String.raw`\u00e9${1}\u4e2d`, "\\u00e91\\u4e2d", "raw");
eq("a".concat("\u00e9", "\u4e2d", 1), "a\u00e9\u4e2d1", "concat");
eq(Number("\u00a0 12 \u2003"), 12, "Number with unicode space");
eq(Number("\u0661"), NaN, "Number non-ascii digit");
eq("\u00e9".localeCompare("e\u0301"), 0, "localeCompare canonical equivalence");

// The normalization form is matched exactly.
for (const form of ["nfc", "NFc", "NFX", "", "\u212bFC"]) {
    let threw = false;
    try { "a".normalize(form); } catch (e) { threw = e instanceof RangeError; }
    eq(threw, true, "normalize(" + JSON.stringify(form) + ") throws");
}
eq("a".normalize("NFKD"), "a", "normalize NFKD");
console.log("ok");
