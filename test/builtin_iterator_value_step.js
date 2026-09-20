var failures = 0;

function check(condition, label) {
    if (!condition) {
        failures++;
        print("FAIL: " + label);
    }
}

function sameList(actual, expected, label) {
    check(actual.length === expected.length, label + " length");
    for (var i = 0; i < expected.length && i < actual.length; i++) {
        check(actual[i] === expected[i], label + "[" + i + "]");
    }
}

// Ordinary for-of keeps custom iterator protocol behavior observable.
var customCalls = 0;
var custom = {};
custom[Symbol.iterator] = function () {
    return {
        next: function () {
            customCalls++;
            return customCalls < 3
                ? { value: customCalls * 10, done: false }
                : { value: undefined, done: true };
        }
    };
};
var customValues = [];
for (var customValue of custom) customValues.push(customValue);
sameList(customValues, [10, 20], "custom iterator");
check(customCalls === 3, "custom next calls");

var iteratorGetterCalls = 0;
var nextGetterCalls = 0;
var getterIterable = {};
Object.defineProperty(getterIterable, Symbol.iterator, {
    get: function () {
        iteratorGetterCalls++;
        return function () {
            var step = 0;
            var iterator = {};
            Object.defineProperty(iterator, "next", {
                get: function () {
                    nextGetterCalls++;
                    return function () {
                        step++;
                        return { value: step, done: step > 1 };
                    };
                }
            });
            return iterator;
        };
    }
});
var getterValues = [];
for (var getterValue of getterIterable) getterValues.push(getterValue);
sameList(getterValues, [1], "iterator getters");
check(iteratorGetterCalls === 1, "@@iterator getter call");
check(nextGetterCalls === 1, "next getter call");

var mapIteratorPrototype = Object.getPrototypeOf(new Map().values());
var originalMapNext = mapIteratorPrototype.next;
var patchedCalls = 0;
mapIteratorPrototype.next = function () {
    patchedCalls++;
    return originalMapNext.call(this);
};
var patchedValues = [];
for (var patchedValue of new Map([[1, "a"], [2, "b"]])) {
    patchedValues.push(patchedValue[1]);
}
sameList(patchedValues, ["a", "b"], "patched Map next");
check(patchedCalls === 3, "patched Map next calls");
mapIteratorPrototype.next = originalMapNext;

// A partially consumed intrinsic iterator resumes at its current position.
var partial = new Set([1, 2, 3]).values();
check(partial.next().value === 1, "partial first step");
var partialValues = [];
for (var partialValue of partial) partialValues.push(partialValue);
sameList(partialValues, [2, 3], "partial remainder");

// Deleted slots are skipped and growth before exhaustion remains visible.
var changingMap = new Map([["a", 1], ["b", 2]]);
var changingMapValues = [];
for (var mapEntry of changingMap) {
    changingMapValues.push(mapEntry[0] + mapEntry[1]);
    if (mapEntry[0] === "a") {
        changingMap.delete("b");
        changingMap.set("c", 3);
    }
}
sameList(changingMapValues, ["a1", "c3"], "Map delete and add");

var changingSet = new Set([1, 2]);
var changingSetValues = [];
for (var setValue of changingSet) {
    changingSetValues.push(setValue);
    if (setValue === 1) {
        changingSet.delete(2);
        changingSet.add(3);
    }
}
sameList(changingSetValues, [1, 3], "Set delete and add");

var clearedMapValues = [];
var clearedMap = new Map([[1, 1], [2, 2]]);
for (var clearedMapEntry of clearedMap) {
    clearedMapValues.push(clearedMapEntry[0]);
    clearedMap.clear();
}
sameList(clearedMapValues, [1], "Map clear");

var clearedSetValues = [];
var clearedSet = new Set([1, 2]);
for (var clearedSetValue of clearedSet) {
    clearedSetValues.push(clearedSetValue);
    clearedSet.clear();
}
sameList(clearedSetValues, [1], "Set clear");

// Exhaustion is permanent even if the source collection later grows.
var exhaustedMap = new Map([[1, 1]]);
var exhaustedMapIterator = exhaustedMap.values();
check(exhaustedMapIterator.next().value === 1, "Map exhausted value");
check(exhaustedMapIterator.next().done === true, "Map first done");
exhaustedMap.set(2, 2);
check(exhaustedMapIterator.next().done === true, "Map stays done after add");

var exhaustedSet = new Set([1]);
var exhaustedSetIterator = exhaustedSet.values();
check(exhaustedSetIterator.next().value === 1, "Set exhausted value");
check(exhaustedSetIterator.next().done === true, "Set first done");
exhaustedSet.add(2);
check(exhaustedSetIterator.next().done === true, "Set stays done after add");

// Strings advance by UTF-16 code point boundaries, including lone surrogates.
var stringValues = [];
for (var stringValue of "A\uD83D\uDE00\uD800B\uDC00") stringValues.push(stringValue);
sameList(stringValues, ["A", "\uD83D\uDE00", "\uD800", "B", "\uDC00"], "String code points");

// Heap values and entry pairs survive the direct value path.
var keyObject = { key: true };
var valueObject = { value: true };
var mapPairs = [];
for (var pair of new Map([[keyObject, valueObject]])) mapPairs.push(pair);
check(mapPairs.length === 1, "Map entry pair count");
check(mapPairs[0][0] === keyObject, "Map entry key identity");
check(mapPairs[0][1] === valueObject, "Map entry value identity");

var setObject = { set: true };
var setPairs = [];
for (var setPair of new Set([setObject]).entries()) setPairs.push(setPair);
check(setPairs.length === 1, "Set entry pair count");
check(setPairs[0][0] === setObject && setPairs[0][1] === setObject,
      "Set entry pair identity");

// Public next exposes the value and completion fields.
var publicResult = new Map([[1, 2]]).values().next();
check(publicResult.value === 2 && publicResult.done === false, "Map IteratorResult fields");

// Abrupt loop completion still performs IteratorClose through the generic path.
var closeCalls = 0;
var closable = {};
closable[Symbol.iterator] = function () {
    return {
        next: function () { return { value: 1, done: false }; },
        return: function () {
            closeCalls++;
            return {};
        }
    };
};
try {
    for (var closeValue of closable) throw new Error("body");
} catch (closeError) {
    check(closeError.message === "body", "abrupt body error");
}
check(closeCalls === 1, "IteratorClose call");

if (failures !== 0) throw new Error(failures + " iterator value-step failures");
