var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Method this
var obj = {
    value: 10,
    getValue: function() { return this.value; }
};
print("before obj.getValue()");
assert(obj.getValue() === 10, "method this");
print("after method this");
