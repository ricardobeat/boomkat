// Native scratch values must survive repeated collections, including while a
// callback temporarily exposes them in VM registers. Run under GC_STRESS + ASan.
function check(condition, message) {
    if (!condition) throw new Error(message);
}

function churn() {
    return [{ a: 1 }, { b: 2 }, { c: 3 }];
}

// A pinned result has outgoing edges that no activation necessarily reaches.
var mapped = [1, 2, 3, 4].map(function (value) {
    churn();
    return { value: value, nested: [value + 10] };
});
for (var i = 0; i < mapped.length; ++i) {
    check(mapped[i].value === i + 1, 'map result child');
    check(mapped[i].nested[0] === i + 11, 'map result grandchild');
}

function* permutations(items) {
    if (items.length === 0) {
        yield [];
    } else {
        for (var i = 0; i < items.length; ++i) {
            var tail = items.slice();
            var head = tail.splice(i, 1);
            for (var rest of permutations(tail)) yield head.concat(rest);
        }
    }
}
var count = 0;
for (var permutation of permutations([3, 1, 2])) {
    permutation.sort(function (a, b) { churn(); return a - b; });
    check(permutation.join() === '1,2,3', 'generator saved registers');
    ++count;
}
check(count === 6, 'permutation count');

function checkSort(C, length, method, custom) {
    var input = new C(length);
    var offset = C === BigInt64Array ? length >> 2 : 0;
    for (var i = 0; i < length; ++i)
        input[i] = BigInt(((length - 1 - i) >> 1) - offset);
    var calls = 0;
    var result = input[method](custom ? function (a, b) {
        var order = a < b ? -1 : a > b ? 1 : 0;
        if ((calls++ & 31) !== 0) return order;
        churn();
        return { valueOf: function () { churn(); return order; } };
    } : undefined);
    for (var i = 0; i < length; ++i) {
        check(result[i] === BigInt((i >> 1) - offset), method + ' sorted value');
        if (method === 'toSorted')
            check(input[i] === BigInt(((length - 1 - i) >> 1) - offset), 'source unchanged');
    }
}
for (var C of [BigInt64Array, BigUint64Array]) {
    for (var size of [16, 512, 513]) {
        for (var method of ['sort', 'toSorted']) {
            checkSort(C, size, method, false);
            checkSort(C, size, method, true);
        }
    }
    var sentinel = {};
    var caught = false;
    try {
        new C([3n, 1n, 2n]).sort(function () { churn(); throw sentinel; });
    } catch (error) {
        caught = error === sentinel;
    }
    check(caught, 'sort propagates comparator exception');
    checkSort(C, 16, 'sort', true);
}
// Enumeration borrows an iterator that Array.from still holds across callbacks.
var iteration = 0;
var result = Array.from({
    [Symbol.iterator]: function () {
        return {
            next: function () {
                for (var key in this) {}
                return { value: ++iteration, done: iteration > 3 };
            }
        };
    }
}, function (value) {
    var churn = [{a: 1}, {b: 2}, {c: 3}];
    return value;
});
check(result.join() === '1,2,3', 'enumeration preserves native iterator pin');

print('temproot GC lifetime PASS');
