// A native array callback parks its outer activation while nested calls grow
// the value stack. Its receiver and registers remain roots across GC slices.
function check(value, message) {
    if (!value) throw new Error(message);
}

function grow(depth) {
    var local = { depth: depth, next: [depth] };
    if (depth === 0) {
        var churn = [];
        for (var i = 0; i < 1200; i++) churn.push({ index: i });
        return churn.length;
    }
    return grow(depth - 1) + (local.next[0] === depth ? 0 : -1);
}

for (var round = 0; round < 4; round++) {
    var result = [1, 2, 3].map(function (item) {
        var held = { value: item * 10 };
        check(grow(90) === 1200, 'nested growth result');
        return this.token + held.value;
    }, { token: 7 });
    check(result.join(',') === '17,27,37', 'saved activation roots');
}

print('gc incremental roots PASS');
