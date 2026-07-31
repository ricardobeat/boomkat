// String.prototype.normalize()
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/normalize
// ES6 §21.1.3.12 — Unicode normalization (NFC/NFD/NFKC/NFKD).

var pass = 0, fail = 0;
var assert = function(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } };

// ── NFC: Compose decomposed characters ─────────────────────────────
// U+00E9 (é) vs U+0065 U+0301 (e + combining acute)
var composed = "\u00E9";
var decomposed = "\u0065\u0301";

assert(composed.length === 1, "composed é length 1");
assert(decomposed.length === 2, "decomposed é length 2");
assert(composed.normalize() === composed, "NFC of already-NFC é is unchanged");
assert(composed.normalize("NFC") === composed, "NFC('é') explicit NFC is unchanged");
assert(decomposed.normalize() === composed, "NFD('e\u0301') NFC composes to é");
assert(decomposed.normalize("NFC") === composed, "NFC of decomposed e+combining composes");

// ── NFD: Decompose composed characters ─────────────────────────────
assert(composed.normalize("NFD") === decomposed, "NFD(é) decomposes to e+combining");
assert(decomposed.normalize("NFD") === decomposed, "NFD of already-NFD is unchanged");

// ── NFKC / NFKD: Compatibility decomposition ───────────────────────
// U+FB01 (ﬁ ligature) → "fi" (two ASCII chars)
var ligature = "\uFB01";
assert(ligature.length === 1, "ﬁ ligature length 1");
assert(ligature.normalize("NFKC") === "fi", "NFKC(ﬁ) decomposes to fi");
assert(ligature.normalize("NFKD") === "fi", "NFKD(ﬁ) decomposes to fi");

// U+00B2 (superscript 2) → "2" in NFKC/NFKD
var sup2 = "\u00B2";
assert(sup2.normalize("NFKC") === "2", "NFKC(²) = 2");
assert(sup2.normalize("NFKD") === "2", "NFKD(²) = 2");

// ● U+2126 (Ω, Ohm sign) → U+03A9 (Ω, Greek capital omega) in NFC
var ohm = "\u2126";
var omega = "\u03A9";
assert(ohm.normalize("NFC") === omega, "NFC(Ω) = Ω");
assert(ohm.normalize("NFD") === omega, "NFD(Ω) = Ω");
assert(ohm.normalize("NFKC") === omega, "NFKC(Ω) = Ω");
assert(ohm.normalize("NFKD") === omega, "NFKD(Ω) = Ω");
assert(omega.normalize("NFC") === omega, "NFC(Ω) unchanged");

// ── ASCII strings are unchanged by any form ────────────────────────
assert("".normalize() === "", "empty string normalize = empty");
assert("".normalize("NFC") === "", "empty string NFC = empty");
assert("".normalize("NFD") === "", "empty string NFD = empty");
assert("".normalize("NFKC") === "", "empty string NFKC = empty");
assert("".normalize("NFKD") === "", "empty string NFKD = empty");

assert("hello".normalize() === "hello", "ASCII NFC unchanged");
assert("hello".normalize("NFC") === "hello", "ASCII NFC explicit unchanged");
assert("hello".normalize("NFD") === "hello", "ASCII NFD unchanged");
assert("hello".normalize("NFKC") === "hello", "ASCII NFKC unchanged");
assert("hello".normalize("NFKD") === "hello", "ASCII NFKD unchanged");

assert("Hello, World!".normalize() === "Hello, World!", "ASCII + punctuation NFC unchanged");

// ── Case-insensitive form names ────────────────────────────────────
assert(decomposed.normalize("nfc") === composed, "lowercase 'nfc' works");
assert(composed.normalize("nfd") === decomposed, "lowercase 'nfd' works");
assert(composed.normalize("NfD") === decomposed, "mixed case 'NfD' works");
assert(ligature.normalize("Nfkc") === "fi", "mixed case 'Nfkc' works");
assert(ligature.normalize("nfkd") === "fi", "lowercase 'nfkd' works");

// ── Default argument uses NFC ──────────────────────────────────────
assert(decomposed.normalize() === composed, "default arg (undefined) uses NFC");
assert(decomposed.normalize(undefined) === composed, "explicit undefined uses NFC");

// ── Invalid form throws RangeError ─────────────────────────────────
var threw = false;
try {
    "x".normalize("NFCX");
} catch (e) {
    threw = e instanceof RangeError;
}
assert(threw, "invalid form 'NFCX' throws RangeError");

threw = false;
try {
    "x".normalize("NFKDX");
} catch (e) {
    threw = e instanceof RangeError;
}
assert(threw, "invalid form 'NFKDX' throws RangeError");

threw = false;
try {
    "x".normalize("NFC ");
} catch (e) {
    threw = e instanceof RangeError;
}
assert(threw, "form with trailing space throws RangeError");

// ── Round-trip: NFC ∘ NFD = NFC  and  NFD ∘ NFC = NFD ────────────
var round1 = composed.normalize("NFD").normalize("NFC");
assert(round1 === composed, "NFC(NFD(é)) = é (idempotent)");
var round2 = decomposed.normalize("NFC").normalize("NFD");
assert(round2 === decomposed, "NFD(NFC(e+combining)) = e+combining (idempotent)");

// ── NFKC is a superset of NFC; NFKD is a superset of NFD ──────────
// NFKC removes compatibility distinctions that NFC preserves.
// Ohm sign → Omega in both NFC and NFKC, so this is same.
// But ﬁ ligature → fi in NFKC/KC, NFC preserves it:
assert(ligature.normalize("NFC") === "\uFB01", "NFC preserves ﬁ ligature");
assert(ligature.normalize("NFD") === "\uFB01", "NFD preserves ﬁ ligature (no decomposition)");

print("engine/normalize: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
