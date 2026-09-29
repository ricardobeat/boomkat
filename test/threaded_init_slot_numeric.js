function fail(message) { throw new Error(message); }

var proto = Object.prototype;
var oldDescriptor = Object.getOwnPropertyDescriptor(proto, "init_slot_numeric_probe");
var setterCalls = 0;
try {
    Object.defineProperty(proto, "init_slot_numeric_probe", {
        configurable: true,
        set: function () { setterCalls++; }
    });
    var ownData = { init_slot_numeric_probe: 17 };
    if (ownData.init_slot_numeric_probe !== 17 || setterCalls !== 0) {
        fail("object literal numeric slots define own data properties");
    }
} finally {
    if (oldDescriptor) Object.defineProperty(proto, "init_slot_numeric_probe", oldDescriptor);
    else delete proto.init_slot_numeric_probe;
}

var order = "";
function value(tag, result) { order += tag; return result; }
var ordered = {
    first: value("a", 23),
    child: value("b", { marker: 31 }),
    nan: value("c", NaN),
    negativeZero: value("d", -0),
    last: value("e", 47)
};
if (order !== "abcde" || ordered.first !== 23 || ordered.child.marker !== 31
    || ordered.nan === ordered.nan || 1 / ordered.negativeZero !== -Infinity
    || ordered.last !== 47) {
    fail("numeric stores preserve value and initializer order");
}

function make(index) {
    return {
        index: index,
        child: { value: index + 1 },
        next: index + 2,
        label: "item-" + index,
        done: true
    };
}

var retained = [];
for (var i = 0; i < 2000; i++) {
    var item = make(i);
    if (item.index !== i || item.child.value !== i + 1 || item.next !== i + 2
        || item.label !== "item-" + i || item.done !== true) {
        fail("fixed-shape initialization preserves mixed slot values");
    }
    if (i % 100 === 0) retained.push(item);
}
for (var j = 0; j < retained.length; j++) {
    if (retained[j].child.value !== j * 100 + 1) {
        fail("heap-valued slots stay rooted across later numeric initializers");
    }
}

print("threaded_init_slot_numeric: all checks passed");
