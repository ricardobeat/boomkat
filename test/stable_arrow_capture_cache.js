var checks = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        throw new Error(name + ": expected " + expected + ", got " + actual);
    }
    checks++;
}

function makeMutable(seed) {
    var value = seed;
    return {
        read: () => value,
        bump: () => value += 1
    };
}

var instances = [];
for (var i = 0; i < 64; i++) instances.push(makeMutable(i * 10));
for (var j = 0; j < instances.length; j++) {
    check("instance read " + j, instances[j].read(), j * 10);
    check("instance bump " + j, instances[j].bump(), j * 10 + 1);
    check("instance reread " + j, instances[j].read(), j * 10 + 1);
}

var sibling = makeMutable(7);
check("sibling initial read", sibling.read(), 7);
check("sibling writer", sibling.bump(), 8);
check("sibling changed read", sibling.read(), 8);
check("sibling second writer", sibling.bump(), 9);
check("sibling second read", sibling.read(), 9);

function makeHeap(seed) {
    var state = { values: [seed, seed + 1] };
    return {
        read: () => state.values[0],
        write: () => state.values[0] = state.values[0] + 1,
        state: state
    };
}

var heap = makeHeap(31);
check("heap read", heap.read(), 31);
check("heap write", heap.write(), 32);
check("heap reread", heap.read(), 32);
check("heap identity", heap.state.values[0], 32);

function tdzCase() {
    var outer = 19;
    return () => { let outer = outer; return outer; };
}
var tdzArrow = tdzCase();
try {
    tdzArrow();
    throw new Error("TDZ read did not throw");
} catch (e) {
    if (!(e instanceof ReferenceError)) throw e;
    checks++;
}

function constCase() {
    return () => { const value = 1; value = 2; };
}
try {
    constCase()();
    throw new Error("const write did not throw");
} catch (e) {
    if (!(e instanceof TypeError)) throw e;
    checks++;
}

function evalShadowCase() {
    var x = 1;
    function readAfterEval() {
        var read = () => x;
        check("eval before shadow", read(), 1);
        eval("var x = 2");
        check("eval after shadow", read(), 2);
    }
    readAfterEval();
}
evalShadowCase();

function evalFunctionShadowCase() {
    var x = 1;
    function readAfterEval() {
        var read = () => x;
        check("eval function warm read", read(), 1);
        check("eval function warmed reread", read(), 1);
        eval("function x() { return 2; }");
        check("eval function shadow", typeof read(), "function");
        delete x;
        check("deleted eval function reveals outer", read(), 1);
    }
    readAfterEval();
}
evalFunctionShadowCase();

function withCase() {
    var outer = 4;
    var object = { outer: 8 };
    var result;
    with (object) {
        var read = () => outer;
        result = read();
        object.outer = 9;
        result = result * 10 + read();
    }
    return result;
}
check("with lookup", withCase(), 89);

print("stable_arrow_capture_cache: " + checks + " passed");
