function check(value, expected) {
    if (value !== expected) throw new Error("FAIL async iterator stack growth: " + value + " !== " + expected);
}
function grow(depth) {
    var value = depth + 1;
    if (depth === 0) return value;
    return grow(depth - 1) + value;
}
function growStack() { check(grow(100), 5151); }
function next() { return { value: 1, done: false }; }

async function closeIterator(kind, proxy) {
    var gets = 0;
    var calls = 0;
    var iterator = {
        next: next,
        get return() {
            growStack();
            gets++;
            if (kind === "throw") throw "getter error";
            if (kind === "null") return null;
            if (kind === "undefined") return undefined;
            return function () {
                growStack();
                calls++;
                check(this, iterator);
                return { done: true };
            };
        }
    };
    if (proxy) {
        iterator = new Proxy(iterator, {
            get: function (target, key, receiver) {
                if (key === "return") growStack();
                return Reflect.get(target, key, receiver);
            }
        });
    }
    var iterable = {};
    iterable[Symbol.asyncIterator] = function () { return iterator; };
    await 0;
    var iterations = 0;
    var error;
    try {
        for await (var item of iterable) {
            check(item, 1);
            iterations++;
            break;
        }
    } catch (e) { error = e; }
    check(iterations, 1);
    check(gets, 1);
    check(calls, kind === "call" ? 1 : 0);
    check(error, kind === "throw" ? "getter error" : undefined);
}

async function getIterator(sync) {
    var iterable = {};
    var reads = 0;
    Object.defineProperty(iterable, sync ? Symbol.iterator : Symbol.asyncIterator, {
        get: function () {
            growStack();
            reads++;
            return function () {
                growStack();
                var count = 0;
                return {
                    get next() {
                        growStack();
                        return function () { return { value: 7, done: count++ > 0 }; };
                    }
                };
            };
        }
    });
    await 0;
    var sum = 0;
    for await (var item of iterable) sum += item;
    check(sum, 7);
    check(reads, 1);
}
async function verify() {
    await closeIterator("null", false);
    await closeIterator("undefined", false);
    await closeIterator("call", false);
    await closeIterator("throw", false);
    await closeIterator("null", true);
    await closeIterator("call", true);
    await getIterator(false);
    await getIterator(true);
    print("PASS async iterator stack growth");
}
verify().catch(function (e) { print("FAIL " + e); });
