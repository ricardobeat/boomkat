// Builtin calls a leaf entry answers agree with the full builtins.

function fail(message) { throw new Error(message); }

var S = "Hello, World", W = "hāllo";
var cases = [
 () => S.charAt(0), () => S.charAt(-1), () => S.charAt(99), () => S.charAt(), () => W.charAt(1), () => S.charAt(undefined),
 () => S.charCodeAt(1), () => S.charCodeAt(-1), () => S.charCodeAt(12), () => W.charCodeAt(1), () => S.charCodeAt(),
 () => String.fromCharCode(65), () => String.fromCharCode(0x10041), () => String.fromCharCode(-1), () => String.fromCharCode(0x101), () => String.fromCharCode(65, 66),
 () => S.indexOf("o"), () => S.indexOf("o", 5), () => S.indexOf("o", -3), () => S.indexOf("o", 99), () => S.indexOf(""), () => S.indexOf("", 99), () => W.indexOf("l"), () => S.indexOf("zz"),
 () => S.lastIndexOf("o"), () => S.lastIndexOf(""), () => S.lastIndexOf("Hel"),
 () => S.substring(1, 4), () => S.substring(4, 1), () => S.substring(-5, 3), () => S.substring(3), () => S.substring(3, undefined), () => S.substring(0, 99), () => W.substring(1, 3),
 () => S.slice(1, 4), () => S.slice(-3), () => S.slice(-3, -1), () => S.slice(4, 1), () => S.slice(-99, 2), () => S.slice(2, 99),
 () => "a".toUpperCase(), () => "Z".toLowerCase(), () => "123".toUpperCase(), () => "ab".toUpperCase(), () => "AB".toLowerCase(), () => "".toUpperCase(),
 () => { var a = [1, 2, 3]; var r = a.pop(); return [r, a.length, a.join()]; },
 () => { var a = []; var r = a.pop(); return [r, a.length]; },
 () => { var a = [1, , 3]; a.pop(); var r = a.pop(); return [r, a.length]; },
 () => { Array.prototype[1] = "proto"; var a = [1, , 3]; a.pop(); var r = a.pop(); delete Array.prototype[1]; return [r, a.length]; },
 () => { var a = Object.freeze([1, 2]); try { a.pop(); return "no"; } catch (e) { return e.constructor.name + a.length; } },
 () => { var a = [1, 2]; Object.defineProperty(a, "length", { writable: false }); try { a.pop(); return "no"; } catch (e) { return e.constructor.name + a.length; } },
 () => { var a = [1, 2]; a.push(3); a.push(undefined); return [a.length, a.hasOwnProperty(3)]; },
 () => { class B extends Array {} var b = new B(); b.push(1); return [b.pop(), b.length, b instanceof B]; },
 () => [Array.isArray([]), Array.isArray({}), Array.isArray(new Proxy([], {})), Array.isArray(1), Array.isArray()],
 () => [parseInt(12.9), parseInt(-12.9), parseInt(1e21), parseInt(0.0000001), parseInt(-0)],
 () => [parseFloat("12.5"), parseFloat("-0"), 1 / parseFloat("-0"), parseFloat("007"), parseFloat(".5"), parseFloat("1."), parseFloat("-"), parseFloat("1e3"), parseFloat(" 1"), parseFloat(-0), 1 / parseFloat(-0), parseFloat("0.1"), parseFloat("123456789012345"), parseFloat("1234567890123456"), parseFloat("3.14159265358979")],
 () => [isNaN(1), isNaN(NaN), isNaN("x"), isNaN(1.5)],
 () => [Math.abs(-3), Math.abs(-0), 1 / Math.abs(-0), Math.floor(2.7), Math.floor(-2.5), Math.ceil(2.1), 1 / Math.ceil(-0.5), Math.sqrt(2), Math.sqrt(-1)],
 () => [Math.round(2.5), Math.round(-2.5), 1 / Math.round(-0.4), Math.round(0.49999999999999994), Math.round(-0), Math.round(NaN), Math.round(Infinity), Math.round(1e300), 1 / Math.round(-0.5), Math.round(-0.6)],
 () => [Math.min(1, 2), Math.max(1, 2), 1 / Math.min(0, -0), 1 / Math.max(-0, 0), Math.min(NaN, 1), Math.max(1.5, -2)],
 () => [Math.pow(2, 10), Math.pow(1, Infinity), Math.pow(-1, -Infinity), Math.pow(NaN, 0), Math.pow(2, NaN), Math.pow(2, 0.5)],
 () => { var o = { charAt: String.prototype.charAt }; try { return o.charAt(0); } catch (e) { return "e"; } },
 () => { try { return String.prototype.charAt.call(null, 0); } catch (e) { return e.constructor.name; } },
 () => String.prototype.charAt.call(123, 1),
];
var out = [];
for (var rep = 0; rep < 3; rep++) for (var i = 0; i < cases.length; i++) { var v = cases[i](); out.push(JSON.stringify(v, (k, x) => typeof x === "number" && 1 / x === -Infinity ? "-0" : (x !== x ? "NaN" : (x === Infinity ? "Inf" : (x === -Infinity ? "-Inf" : x))))); }

var expected = ["\"H\"","\"\"","\"\"","\"H\"","\"ā\"","\"H\"","101","\"NaN\"","\"NaN\"","257","72","\"A\"","\"A\"","\"￿\"","\"ā\"","\"AB\"","4","8","4","-1","0","12","2","-1","8","12","0","\"ell\"","\"ell\"","\"Hel\"","\"lo, World\"","\"lo, World\"","\"Hello, World\"","\"āl\"","\"ell\"","\"rld\"","\"rl\"","\"\"","\"He\"","\"llo, World\"","\"A\"","\"z\"","\"123\"","\"AB\"","\"ab\"","\"\"","[3,2,\"1,2\"]","[null,0]","[null,1]","[\"proto\",1]","\"TypeError2\"","\"TypeError2\"","[4,true]","[1,0,true]","[true,false,true,false,false]","[12,-12,1,1,0]","[12.5,\"-0\",\"-Inf\",7,0.5,1,\"NaN\",1000,1,0,\"Inf\",0.1,123456789012345,1234567890123456,3.14159265358979]","[false,true,true,false]","[3,0,\"Inf\",2,-3,3,\"-Inf\",1.4142135623730951,\"NaN\"]","[3,-2,\"-Inf\",0,\"-0\",\"NaN\",\"Inf\",1e+300,\"-Inf\",-1]","[1,2,\"-Inf\",\"Inf\",\"NaN\",1.5]","[1024,\"NaN\",\"NaN\",1,\"NaN\",1.4142135623730951]","\"[\"","\"TypeError\"","\"2\"","\"H\"","\"\"","\"\"","\"H\"","\"ā\"","\"H\"","101","\"NaN\"","\"NaN\"","257","72","\"A\"","\"A\"","\"￿\"","\"ā\"","\"AB\"","4","8","4","-1","0","12","2","-1","8","12","0","\"ell\"","\"ell\"","\"Hel\"","\"lo, World\"","\"lo, World\"","\"Hello, World\"","\"āl\"","\"ell\"","\"rld\"","\"rl\"","\"\"","\"He\"","\"llo, World\"","\"A\"","\"z\"","\"123\"","\"AB\"","\"ab\"","\"\"","[3,2,\"1,2\"]","[null,0]","[null,1]","[\"proto\",1]","\"TypeError2\"","\"TypeError2\"","[4,true]","[1,0,true]","[true,false,true,false,false]","[12,-12,1,1,0]","[12.5,\"-0\",\"-Inf\",7,0.5,1,\"NaN\",1000,1,0,\"Inf\",0.1,123456789012345,1234567890123456,3.14159265358979]","[false,true,true,false]","[3,0,\"Inf\",2,-3,3,\"-Inf\",1.4142135623730951,\"NaN\"]","[3,-2,\"-Inf\",0,\"-0\",\"NaN\",\"Inf\",1e+300,\"-Inf\",-1]","[1,2,\"-Inf\",\"Inf\",\"NaN\",1.5]","[1024,\"NaN\",\"NaN\",1,\"NaN\",1.4142135623730951]","\"[\"","\"TypeError\"","\"2\"","\"H\"","\"\"","\"\"","\"H\"","\"ā\"","\"H\"","101","\"NaN\"","\"NaN\"","257","72","\"A\"","\"A\"","\"￿\"","\"ā\"","\"AB\"","4","8","4","-1","0","12","2","-1","8","12","0","\"ell\"","\"ell\"","\"Hel\"","\"lo, World\"","\"lo, World\"","\"Hello, World\"","\"āl\"","\"ell\"","\"rld\"","\"rl\"","\"\"","\"He\"","\"llo, World\"","\"A\"","\"z\"","\"123\"","\"AB\"","\"ab\"","\"\"","[3,2,\"1,2\"]","[null,0]","[null,1]","[\"proto\",1]","\"TypeError2\"","\"TypeError2\"","[4,true]","[1,0,true]","[true,false,true,false,false]","[12,-12,1,1,0]","[12.5,\"-0\",\"-Inf\",7,0.5,1,\"NaN\",1000,1,0,\"Inf\",0.1,123456789012345,1234567890123456,3.14159265358979]","[false,true,true,false]","[3,0,\"Inf\",2,-3,3,\"-Inf\",1.4142135623730951,\"NaN\"]","[3,-2,\"-Inf\",0,\"-0\",\"NaN\",\"Inf\",1e+300,\"-Inf\",-1]","[1,2,\"-Inf\",\"Inf\",\"NaN\",1.5]","[1024,\"NaN\",\"NaN\",1,\"NaN\",1.4142135623730951]","\"[\"","\"TypeError\"","\"2\""];
for (var j = 0; j < expected.length; j++) if (out[j] !== expected[j]) fail("case " + (j % cases.length) + ": " + out[j] + " !== " + expected[j]);
