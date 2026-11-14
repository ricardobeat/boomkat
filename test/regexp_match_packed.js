// RegExp match arrays keep a non-participating capture as an `undefined`
// element in the dense part (a packed array): it must stay an own property
// through every reader, and turn back into an ordinary one before any write
// that could leave a hole. Captured, split, matched and replaced strings must
// work as property keys, Map and Set keys, and in `===` and `switch`.
// Expected lines are node's output for the same code.

function mk() { return /(a)|(b)(c)?/.exec("zb"); }
function keys(o) { return Object.keys(o).join(); }
var out = [];
function p() { out.push(Array.prototype.join.call(arguments, " ")); }
var m = mk();
p(m.length, 0 in m, 1 in m, 3 in m, 4 in m, keys(m), JSON.stringify(m), m.groups);
p(Reflect.ownKeys(m).join(), m.propertyIsEnumerable(1), JSON.stringify(Object.getOwnPropertyDescriptor(m, 1)));
var fi = []; for (var k in m) fi.push(k); p(fi.join());
p([...m].join("|"), [...m].length, Array.from(m).length, JSON.stringify(Object.assign({}, m)), JSON.stringify({...m}));
var c = 0; m.forEach(function (v, i) { c += i; }); p(c, m.every(function (v, i) { return i < 4; }), m.filter(function (v) { return v === undefined; }).length);
p(m.indexOf(undefined), m.lastIndexOf(undefined), m.includes(undefined), m.findIndex(function (v) { return v === undefined; }));
p(m.slice(1).length, 0 in m.slice(1), m.concat([1]).length, 1 in m.concat([]));
var m1 = mk(); Object.defineProperty(m1, 1, { value: 5 }); p(m1[1], keys(m1), JSON.stringify(Object.getOwnPropertyDescriptor(m1, 1)));
var m2 = mk(); Object.defineProperty(m2, 3, { get: function () { return "g"; } }); p(m2[3], keys(m2), 3 in m2);
var m3 = mk(); Object.freeze(m3); p(Object.isFrozen(m3), keys(m3), 1 in m3, m3[1]);
var m4 = mk(); Object.seal(m4); m4[1] = "s"; p(m4[1], keys(m4), Object.isSealed(m4));
var m5 = mk(); m5.copyWithin(0, 1); p(keys(m5), m5.join("|"), 0 in m5);
var m6 = mk(); m6.splice(1, 0, undefined, 9); p(m6.length, keys(m6), m6.join("|"), 1 in m6, 4 in m6);
var m7 = mk(); m7.unshift(undefined); p(m7.length, keys(m7), 2 in m7);
var m8 = mk(); m8.fill(undefined, 0, 1); p(keys(m8), 0 in m8);
var m9 = mk(); m9.length = 2; m9.length = 4; p(keys(m9), 1 in m9, 3 in m9);
var mA = mk(); mA[3] = "x"; delete mA[3]; p(keys(mA), 3 in mA, 1 in mA);
var mB = mk(); mB[1] = undefined; p(keys(mB), 1 in mB);
var mC = mk(); p(delete mC[3], keys(mC), 3 in mC, mC.length);
var mD = mk(); var r = mD.reverse(); p(keys(r), r.join("|"));
var mE = mk(); p(mE.toString(), String(mE), mE.join());
var mF = /(?<x>a)|(?<y>b)/d.exec("b"); p(keys(mF), JSON.stringify(mF.groups), JSON.stringify(mF.indices), JSON.stringify(mF.indices.groups), 1 in mF, 1 in mF.indices);
var mG = /(x)?(y)?(z)?/.exec(""); p(mG.length, keys(mG), JSON.stringify(mG));
Array.prototype[1] = "P"; Array.prototype[5] = "Q"; var mH = mk(); p(mH[1], mH[3], mH[5], mH.join("|")); delete Array.prototype[1]; delete Array.prototype[5];
var big = /(a)|(b)|(c)|(d)|(e)|(f)|(g)|(h)|(i)|(j)|(k)|(l)|(m)|(n)/.exec("n"); p(big.length, keys(big), 1 in big, big[14]);
// captured strings as keys
var s = "k1=v1;k2=v2;k1=v3", re = /(\w+)=(\w+)/g, mm, o = {}, mp = new Map(), st = new Set();
while ((mm = re.exec(s))) { o[mm[1]] = (o[mm[1]] || "") + mm[2]; mp.set(mm[1], (mp.get(mm[1]) || 0) + 1); st.add(mm[1]); }
p(JSON.stringify(o), mp.get("k1"), mp.get("k2"), st.size, st.has("k1"), o.hasOwnProperty("k1"), "k2" in o);
var cap = /(\w+)-(\d+)/.exec("item-42");
p(cap[1] === "item", cap[2] === "42", cap[2] == 42, ({ item: 1 })[cap[1]], [10, 20, 30][cap[2] - 41]);
switch (cap[1]) { case "item": p("sw ok"); break; default: p("sw bad"); }
var arr2 = []; arr2[cap[2]] = 1; p(arr2.length);
var rep = "a-b-c".replace(/-/g, "+"); var ro = {}; ro[rep] = 1; p(rep === "a+b+c", ro["a+b+c"], new Map([[rep, 2]]).get("a+b+c"), Object.keys(ro)[0] === "a+b+c");
var sp = "x,y,x".split(/,/); var so = {}; sp.forEach(function (k) { so[k] = (so[k] || 0) + 1; }); p(JSON.stringify(so), sp[0] === sp[2]);
var ma = "ab12cd34".match(/\d+/g); p(ma.join(), ma[0] === "12", new Set(ma).size);
var str = "zb".replace(/(a)|(b)(c)?/, function (all, x, y, z) { return [all, x, y, z].join(":"); }); p(str);

var expected = [
    "4 true true true false 0,1,2,3,index,input,groups [\"b\",null,\"b\",null] ",
    "0,1,2,3,length,index,input,groups true {\"writable\":true,\"enumerable\":true,\"configurable\":true}",
    "0,1,2,3,index,input,groups",
    "b||b| 4 4 {\"0\":\"b\",\"2\":\"b\",\"index\":1,\"input\":\"zb\"} {\"0\":\"b\",\"2\":\"b\",\"index\":1,\"input\":\"zb\"}",
    "6 true 2",
    "1 3 true 1",
    "3 true 5 true",
    "5 0,1,2,3,index,input,groups {\"value\":5,\"writable\":true,\"enumerable\":true,\"configurable\":true}",
    "g 0,1,2,3,index,input,groups true",
    "true 0,1,2,3,index,input,groups true ",
    "s 0,1,2,3,index,input,groups true",
    "0,1,2,3,index,input,groups |b|| true",
    "6 0,1,2,3,4,5,index,input,groups b||9||b| true true",
    "5 0,1,2,3,4,index,input,groups true",
    "0,1,2,3,index,input,groups true",
    "0,1,index,input,groups true false",
    "0,1,2,index,input,groups false true",
    "0,1,2,3,index,input,groups true",
    "true 0,1,2,index,input,groups false 4",
    "0,1,2,3,index,input,groups |b||b",
    "b,,b, b,,b, b,,b,",
    "0,1,2,index,input,groups,indices {\"y\":\"b\"} [[0,1],null,[0,1]] {\"y\":[0,1]} true true",
    "4 0,1,2,3,index,input,groups [\"\",null,null,null]",
    "  Q b||b|",
    "15 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,index,input,groups true n",
    "{\"k1\":\"v1v3\",\"k2\":\"v2\"} 2 1 2 true true true",
    "true true true 1 20",
    "sw ok",
    "43",
    "true 1 2 true",
    "{\"x\":2,\"y\":1} true",
    "12,34 true 2",
    "zb::b:"
];
var failures = 0;
for (var i = 0; i < expected.length; i++) {
    if (out[i] !== expected[i]) {
        print("FAIL: line " + (i + 1) + ": expected " + expected[i] + ", got " + out[i]);
        failures++;
    }
}
if (out.length !== expected.length) print("FAIL: " + out.length + " lines, expected " + expected.length);
// The element read in a hot loop, where the JIT tiers read it inline.
var total = 0;
for (var round = 0; round < 3000; round++) {
    var hm = /(a)|(b)(c)?/.exec(round & 1 ? "zb" : "za");
    for (var j = 0; j < hm.length; j++) if (hm[j] !== undefined) total += hm[j].length;
}
if (total !== 6000) print("FAIL: hot loop total " + total);
if (failures === 0) print("OK");
