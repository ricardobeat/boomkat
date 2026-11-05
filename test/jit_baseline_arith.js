// Number arithmetic, comparisons and branches at the edges a native tier's
// inline paths guard: the 48-bit and int32 boundaries, -0, NaN, infinities,
// mixed int and double operands, and operands that need coercion.
var pass = 0;
var fail = 0;

function same(a, b) {
    if (typeof a === "bigint" || typeof b === "bigint") return typeof a === typeof b && a === b;
    return Object.is(a, b);
}

function check(name, got, want) {
    if (same(got, want)) {
        pass = pass + 1;
    } else {
        fail = fail + 1;
        print("FAIL " + name + ": got " + String(got) + ", want " + String(want));
    }
}

function add(a, b) { return a + b; }
function sub(a, b) { return a - b; }
function mul(a, b) { return a * b; }
function div(a, b) { return a / b; }
function addOne(a) { return a + 1; }
function subOne(a) { return a - 1; }
function mulThree(a) { return a * 3; }
function mulMinusTwo(a) { return a * -2; }
function inc(a) { a++; return a; }
function dec(a) { a--; return a; }
function band(a, b) { return a & b; }
function bor(a, b) { return a | b; }
function bxor(a, b) { return a ^ b; }
function shl(a, b) { return a << b; }
function shr(a, b) { return a >> b; }
function ushr(a, b) { return a >>> b; }
function bandI(a) { return a & 0xF0; }
function borI(a) { return a | 3; }
function bxorI(a) { return a ^ 255; }
function shlI(a) { return a << 31; }
function shrI(a) { return a >> 4; }
function ushrI(a) { return a >>> 0; }
function lt(a, b) { return a < b; }
function le(a, b) { return a <= b; }
function gt(a, b) { return a > b; }
function ge(a, b) { return a >= b; }
function eq(a, b) { return a == b; }
function ne(a, b) { return a != b; }
function seq(a, b) { return a === b; }
function sne(a, b) { return a !== b; }
function brLt(a, b) { if (a < b) return "y"; return "n"; }
function brLe(a, b) { if (a <= b) return "y"; return "n"; }
function brGt(a, b) { if (a > b) return "y"; return "n"; }
function brGe(a, b) { if (a >= b) return "y"; return "n"; }
function brSeq(a, b) { if (a === b) return "y"; return "n"; }
function brSne(a, b) { if (a !== b) return "y"; return "n"; }
function brEq(a, b) { if (a == b) return "y"; return "n"; }
function brLtI(a) { if (a < 5) return "y"; return "n"; }
function brGeI(a) { if (a >= -3) return "y"; return "n"; }
function brSeqI(a) { if (a === 7) return "y"; return "n"; }
function truthy(a) { if (a) return "t"; return "f"; }
function falsy(a) { if (!a) return "f"; return "t"; }
function isNull(a) { if (a == null) return "null"; return "value"; }
function consts() { var x = 1.5; var y = -7; var z = true; var w = null; var u; return [x, y, z, w, u]; }
function bigInt() { return 0x7fff1234; }
function hugeInt() { return 0x7fff12345678; }
function move(a) { var b = a; var c = b; return c; }

var MAX48 = 140737488355327;  // 2^47 - 1
var MIN48 = -140737488355328; // -2^47
var I32 = 2147483647;
var obj = { valueOf: function () { return 10; } };
var strObj = { valueOf: function () { return "s"; } };

for (var round = 0; round < 3; round++) {
    // 48-bit boundary: results leave the fastint range and become doubles.
    check("add max48", add(MAX48, 1), 140737488355328);
    check("add min48", add(MIN48, -1), -140737488355329);
    check("sub min48", sub(MIN48, 1), -140737488355329);
    check("sub max48", sub(MAX48, -1), 140737488355328);
    check("addi max48", addOne(MAX48), 140737488355328);
    check("subi min48", subOne(MIN48), -140737488355329);
    check("inc max48", inc(MAX48), 140737488355328);
    check("dec min48", dec(MIN48), -140737488355329);
    check("add fits", add(MAX48 - 1, 1), MAX48);
    check("sub fits", sub(MIN48 + 1, 1), MIN48);
    // int32 boundary: still exact integers.
    check("add i32", add(I32, 1), 2147483648);
    check("sub i32", sub(-I32 - 1, 1), -2147483649);
    check("mul i32", mul(I32, 2), 4294967294);
    check("mul 31-bit", mul(0x40000000, 2), 2147483648);
    check("mul neg 31-bit", mul(-0x40000000, -0x40000000), 1152921504606846976);
    check("mul big", mul(0x100000000, 0x100000000), 18446744073709551616);
    check("mul max48 fits", mul(0x3FFFFFFF, 0x20000), 140737488224256);
    check("mul over48", mul(0x3FFFFFFF, 0x40000), 281474976448512);
    check("muli", mulThree(0x2AAAAAAAAAAA), 140737488355326);
    check("muli neg", mulMinusTwo(12345), -24690);
    check("muli big", mulThree(0x3FFFFFFFFFFF), 211106232532989);
    // -0
    check("mul -0", mul(0, -5), -0);
    check("mul -0 b", mul(-3, 0), -0);
    check("mul +0", mul(0, 0), 0);
    check("muli -0", mulMinusTwo(0), -0);
    check("add -0", add(-0, -0), -0);
    check("add -0 0", add(-0, 0), 0);
    check("sub -0", sub(-0, 0), -0);
    check("sub 0 0", sub(0, 0), 0);
    check("div -0", div(0, -1), -0);
    check("addi -0", addOne(-0), 1);
    check("seq -0", seq(-0, 0), true);
    check("lt -0", lt(-0, 0), false);
    check("dec 1", dec(1), 0);
    // NaN and infinities.
    check("add nan", add(NaN, 1), NaN);
    check("sub inf", sub(Infinity, Infinity), NaN);
    check("mul inf", mul(Infinity, 0), NaN);
    check("mul inf neg", mul(-Infinity, 2), -Infinity);
    check("div zero", div(1, 0), Infinity);
    check("div neg zero", div(1, -0), -Infinity);
    check("div zero zero", div(0, 0), NaN);
    check("lt nan", lt(NaN, 1), false);
    check("ge nan", ge(1, NaN), false);
    check("seq nan", seq(NaN, NaN), false);
    check("sne nan", sne(NaN, NaN), true);
    check("br lt nan", brLt(NaN, 0), "n");
    check("br ge nan", brGe(0, NaN), "n");
    check("br sne nan", brSne(NaN, NaN), "y");
    check("br lti nan", brLtI(NaN), "n");
    check("br gei nan", brGeI(NaN), "n");
    check("lt inf", lt(-Infinity, MIN48), true);
    check("gt inf", gt(Infinity, MAX48), true);
    check("inc nan", inc(NaN), NaN);
    // Mixing int and double.
    check("add mix", add(1, 0.5), 1.5);
    check("add mix b", add(0.25, 2), 2.25);
    check("sub mix", sub(3, 0.5), 2.5);
    check("mul mix", mul(3, 0.5), 1.5);
    check("div int", div(7, 2), 3.5);
    check("div exact", div(6, 3), 2);
    check("addi double", addOne(1.5), 2.5);
    check("subi double", subOne(0.5), -0.5);
    check("inc double", inc(1.5), 2.5);
    check("dec double", dec(-0.5), -1.5);
    check("add doubles to int", add(0.5, 0.5), 1);
    check("lt mix", lt(1, 1.5), true);
    check("le mix", le(2, 2.0), true);
    check("gt mix", gt(2.5, 2), true);
    check("br le mix", brLe(1.5, 1), "n");
    check("br gt mix", brGt(1.5, 1), "y");
    check("br seq mix", brSeq(2, 2.0), "y");
    check("br seqi double", brSeqI(7.0), "y");
    check("br seqi frac", brSeqI(7.5), "n");
    check("br lti double", brLtI(4.5), "y");
    check("br gei double", brGeI(-3.5), "n");
    // Bitwise and shifts.
    check("band", band(0xFF0F, 0x0FF0), 0x0F00);
    check("band neg", band(-1, 0x7FFFFFFF), 0x7FFFFFFF);
    check("bor i32", bor(0x40000000, 0x40000000), 0x40000000);
    check("bor wrap", bor(0x80000000, 0), -2147483648);
    check("bxor", bxor(-1, 0), -1);
    check("band big", band(0x1FFFFFFFF, 0x1FFFFFFFF), -1);
    check("shl", shl(1, 31), -2147483648);
    check("shl mask", shl(1, 33), 2);
    check("shl neg count", shl(1, -1), -2147483648);
    check("shr", shr(-16, 2), -4);
    check("shr mask", shr(-16, 34), -4);
    check("ushr", ushr(-1, 0), 4294967295);
    check("ushr 28", ushr(-16, 28), 15);
    check("band double", band(3.7, 1), 1);
    check("bor double", bor(-1.5, 0), -1);
    check("bandi", bandI(0x1234), 0x30);
    check("bori", borI(-4), -1);
    check("bxori", bxorI(15), 240);
    check("shli", shlI(1), -2147483648);
    check("shri", shrI(-256), -16);
    check("ushri", ushrI(-1), 4294967295);
    check("ushri big", ushrI(0x123456789), 0x23456789);
    check("band nan", band(NaN, -1), 0);
    check("shl inf", shl(Infinity, 1), 0);
    // String plus number and objects with valueOf.
    check("str add", add("a", 1), "a1");
    check("str add b", add(1, "a"), "1a");
    check("str addi", addOne("x"), "x1");
    check("str sub", sub("5", 2), 3);
    check("str mul", mul("4", "2"), 8);
    check("str lt", lt("a", "b"), true);
    check("str lt num", lt("10", 9), false);
    check("obj add", add(obj, 1), 11);
    check("obj sub", sub(obj, 1), 9);
    check("obj mul", mul(obj, obj), 100);
    check("obj addi", addOne(obj), 11);
    check("obj inc", inc(obj), 11);
    check("obj band", band(obj, 3), 2);
    check("obj lt", lt(obj, 11), true);
    check("obj br", brLt(obj, 5), "n");
    check("strobj add", add(strObj, 1), "s1");
    check("bool add", add(true, 1), 2);
    check("null add", add(null, 1), 1);
    check("undef add", add(undefined, 1), NaN);
    // BigInt operands.
    check("big add", add(1n, 2n), 3n);
    check("big sub", sub(1n, 2n), -1n);
    check("big mul", mul(1n << 64n, 3n), 55340232221128654848n);
    check("big inc", inc(9007199254740993n), 9007199254740994n);
    check("big lt", lt(1n, 2), true);
    check("big br", brLt(5n, 3), "n");
    check("big seq", seq(1n, 1), false);
    check("big eq", eq(1n, 1), true);
    check("big band", band(6n, 3n), 2n);
    var threw = false;
    try { add(1n, 1); } catch (e) { threw = e instanceof TypeError; }
    check("big mix throws", threw, true);
    // Comparisons of mixed types.
    check("eq str num", eq("1", 1), true);
    check("ne str num", ne("1", 1), false);
    check("seq str num", seq("1", 1), false);
    check("sne str num", sne("1", 1), true);
    check("eq null undef", eq(null, undefined), true);
    check("seq null undef", seq(null, undefined), false);
    check("eq ints", eq(5, 5), true);
    check("ne ints", ne(5, 6), true);
    check("seq ints", seq(MAX48, MAX48), true);
    check("seq int double", seq(3, 3.0), true);
    check("seq obj", seq(obj, obj), true);
    check("lt null", lt(null, 1), true);
    check("lt undef", lt(undefined, 1), false);
    check("le bool", le(true, 1), true);
    check("br eq mixed", brEq("2", 2), "y");
    check("br seq obj", brSeq(obj, obj), "y");
    check("br sne str", brSne("a", "a"), "n");
    check("ge int", ge(MIN48, MIN48), true);
    check("gt int", gt(MIN48, MAX48), false);
    check("br gt int", brGt(MAX48, MIN48), "y");
    // Truthiness and nullish tests.
    check("truthy 0", truthy(0), "f");
    check("truthy 1", truthy(1), "t");
    check("truthy -1", truthy(-1), "t");
    check("truthy min48", truthy(MIN48), "t");
    check("truthy -0", truthy(-0), "f");
    check("truthy nan", truthy(NaN), "f");
    check("truthy 0.5", truthy(0.5), "t");
    check("truthy empty", truthy(""), "f");
    check("truthy str", truthy("0"), "t");
    check("truthy obj", truthy(obj), "t");
    check("truthy null", truthy(null), "f");
    check("truthy undef", truthy(undefined), "f");
    check("truthy true", truthy(true), "t");
    check("truthy false", truthy(false), "f");
    check("truthy 0n", truthy(0n), "f");
    check("truthy sym", truthy(Symbol()), "t");
    check("falsy 0", falsy(0), "f");
    check("falsy obj", falsy(obj), "t");
    check("null null", isNull(null), "null");
    check("null undef", isNull(undefined), "null");
    check("null 0", isNull(0), "value");
    check("null obj", isNull(obj), "value");
    check("null str", isNull(""), "value");
    // Loads and moves.
    var cs = consts();
    check("const double", cs[0], 1.5);
    check("const int", cs[1], -7);
    check("const bool", cs[2], true);
    check("const null", cs[3], null);
    check("const undef", cs[4], undefined);
    check("ldintx", bigInt(), 2147422772);
    check("ldintx 48", hugeInt(), 140733498807928);
    check("move str", move("s"), "s");
    check("move obj", move(obj), obj);
    check("move int", move(3), 3);
}

// Loop counters crossing the 48-bit boundary, which turns them into doubles
// mid-loop.
function countUp(from, n) {
    var x = from;
    for (var i = 0; i < n; i++) x++;
    return x;
}
function countDown(from, n) {
    var x = from;
    for (var i = n; i > 0; i--) x = x - 1;
    return x;
}
function stepBy(from, n, step) {
    var x = from;
    var k = 0;
    while (k < n) { x += step; k += 1; }
    return x;
}
check("count up", countUp(MAX48 - 5, 10), MAX48 + 5);
check("count down", countDown(MIN48 + 5, 10), MIN48 - 5);
check("step up", stepBy(MAX48 - 20, 10, 7), MAX48 + 50);
check("step double", stepBy(0, 10, 0.1), 0.9999999999999999);
check("count up i32", countUp(I32 - 5, 10), I32 + 5);

// A long backward-branch loop crosses the GC budget many times, with an
// allocation per iteration so collections run while native code loops.
function longLoop(n) {
    var sum = 0;
    var keep = null;
    for (var i = 0; i < n; i++) {
        sum = (sum + i * 3) % 1000003;
        if ((i & 1023) === 0) keep = { i: i, prev: keep };
    }
    var depth = 0;
    while (keep !== null) { depth++; keep = keep.prev; }
    return sum * 10000 + depth;
}
check("long loop", longLoop(3000000), 1352930);

function nested(n) {
    var total = 0;
    for (var i = 0; i < n; i++) {
        var j = 0;
        do { total += j; j += 1; } while (j < 100);
        if (!(i < n)) break;
    }
    return total;
}
check("nested loop", nested(20000), 99000000);

print("pass: " + pass + " fail: " + fail);
