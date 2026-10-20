// Large ranges, a deep graph, and allocation without intervening JS calls.
var slots = [];
var chain = null;
for (var i = 0; i < 100000; i++) {
    var entry = { value: i, parent: chain };
    slots.push(entry);
    chain = entry;
}
for (var round = 0; round < 10; round++) {
    for (var j = 0; j < slots.length; j++) {
        slots[j] = { value: j + round, previous: slots[j] };
    }
}
var count = 0;
for (var cursor = chain; cursor !== null; cursor = cursor.parent) count++;
if (count !== 100000 || slots[99999].value !== 100008) {
    throw new Error("large GC graph corrupted");
}
slots = null;
chain = null;
entry = null;
var survivor = null;
for (var k = 0; k < 500000; k++) survivor = { value: k };
if (survivor.value !== 499999) throw new Error("allocation churn corrupted");
print("large container and deep graph passed");
