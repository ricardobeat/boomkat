// The primitive a ToPrimitive call returns lives only in the VM's call-result
// slot until the next call replaces it. Every operator and builtin that
// converts an operand and then runs more user code must hold the first result.
var fail = 0;
var check = function (name, got, want) {
  if (got !== want) { fail++; print("FAIL " + name + ": " + String(got) + " !== " + String(want)); }
};
// Fresh, non-interned strings: join allocates a new string each call.
var fresh = function (s) { return [s, "x"].join(""); };
var freshNum = function (s) { return [s.slice(0, 8), s.slice(8)].join(""); };
var N = 3000;

// Numeric operators on objects whose valueOf yields a fresh numeric string.
var a = { valueOf: function () { return freshNum("1000000000000000"); } };
var b = { valueOf: function () { return freshNum("3000000000000000"); } };
for (var i = 0; i < N; i++) {
  check("sub", a - b, 1e15 - 3e15);
  check("mul", a * b, 3e30);
  check("div", b / a, 3);
  check("mod", b % a, 0);
  check("exp", a ** b, Infinity);
  check("shl", a << b, (1e15 | 0) << ((3e15 | 0) & 31));
  check("shr", a >> b, (1e15 | 0) >> ((3e15 | 0) & 31));
  check("ushr", a >>> b, (1e15 >>> 0) >>> ((3e15 | 0) & 31));
  check("band", a & b, (1e15 | 0) & (3e15 | 0));
  check("bor", a | b, (1e15 | 0) | (3e15 | 0));
  check("bxor", a ^ b, (1e15 | 0) ^ (3e15 | 0));
}

// BigInt results of the first conversion survive the second.
var bigA = { valueOf: function () { return BigInt(freshNum("1000000000000000")); } };
var bigB = { valueOf: function () { return BigInt(freshNum("3")); } };
for (var j = 0; j < N; j++) {
  check("bigint-sub", bigA - bigB, 999999999999997n);
  check("bigint-mul", bigA * bigB, 3000000000000000n);
  check("bigint-shl", bigB << bigB, 24n);
  check("bigint-band", bigA & bigB, 1000000000000000n & 3n);
}

// Array.prototype.join: the separator is converted first, then every element.
var sep = { toString: function () { return fresh("--"); } };
var el = { toString: function () { return fresh("elem"); } };
for (var k = 0; k < N; k++) {
  check("join", [el, el].join(sep), "elem" + "x" + "--x" + "elemx");
}

// Object.defineProperty: the key is converted before the descriptor's getters run.
var key = { toString: function () { return fresh("property-name-long-enough"); } };
var desc = {};
Object.defineProperty(desc, "value", { get: function () { return fresh("v"); }, enumerable: true });
Object.defineProperty(desc, "writable", { get: function () { return true; }, enumerable: true });
for (var m = 0; m < N; m++) {
  var target = {};
  Object.defineProperty(target, key, desc);
  check("defineProperty", target[fresh("property-name-long-enough")], "vx");
}

// Reflect.get on a proxy: the key is converted before the trap runs and is
// checked against the target afterwards.
var frozenTarget = Object.freeze({ "frozen-key-long-enough-x": 7 });
var proxy = new Proxy(frozenTarget, { get: function (t, p) { fresh("trap"); return t[p]; } });
var pkey = { toString: function () { return fresh("frozen-key-long-enough-"); } };
for (var n = 0; n < N; n++) {
  check("reflect-get", Reflect.get(proxy, pkey), 7);
  check("proxy-has", Reflect.has(proxy, pkey), true);
}

// String.prototype.replace with a function replacer and an object search value.
var search = { toString: function () { return fresh("needle-long-enough-"); } };
var hay = "a needle-long-enough-x b";
for (var q = 0; q < N; q++) {
  check("replace", hay.replace(search, function () { return fresh("R"); }), "a Rx b");
}

if (fail === 0) print("PASS");
