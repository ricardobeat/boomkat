function assertEq(actual, expected, label) {
    if (actual !== expected) {
        throw new Error(label + ": expected " + expected + ", got " + actual);
    }
}

function propertyNameIsNotCapture(value) {
    var local = value + 1;
    function readProperties(object) {
        return object.value + object.local;
    }
    value = value + 10;
    local = local + 20;
    return value + local + readProperties({ value: 3, local: 4 });
}

function actualCapture(value) {
    var local = value + 1;
    function readBindings() {
        return value + local;
    }
    value = value + 10;
    local = local + 20;
    return readBindings;
}

for (var i = 0; i < 100; i++) {
    assertEq(propertyNameIsNotCapture(i), i * 2 + 38, "property names " + i);
    assertEq(actualCapture(i)(), i * 2 + 31, "captured bindings " + i);
}
