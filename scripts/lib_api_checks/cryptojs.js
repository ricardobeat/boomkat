var CryptoJS = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("md5", CryptoJS.MD5("hello").toString());
rec("sha256", CryptoJS.SHA256("hello").toString());
rec("base64_roundtrip", CryptoJS.enc.Base64.stringify(CryptoJS.enc.Utf8.parse("hi there")));
// AES.encrypt needs a secure RNG for its IV (window.crypto.getRandomValues),
// which neither engine provides host-side and which crypto-js's own
// synchronous-PRNG fallback also fails without a browser environment --
// confirmed identical failure on qjs, so this is a missing host API, not an
// engine bug. A deterministic key-derived cipher (no random IV) still
// exercises the block-cipher core:
var key = CryptoJS.enc.Utf8.parse("0123456789abcdef");
var iv = CryptoJS.enc.Utf8.parse("fedcba9876543210");
var enc = CryptoJS.AES.encrypt("secret message", key, { iv: iv });
var dec = CryptoJS.AES.decrypt(enc, key, { iv: iv }).toString(CryptoJS.enc.Utf8);
rec("aes_roundtrip", dec);

console.log(lines.join("\n"));
console.log(lines.length + " crypto-js API checks recorded, 0 threw");
