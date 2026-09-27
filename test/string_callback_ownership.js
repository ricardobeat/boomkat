// Receiver strings stay owned while argument coercion re-enters JavaScript.
var receiver = {
    toString: function () { return "x".repeat(4096); }
};
var start = {
    valueOf: function () { return 1; }
};
var sliced = String.prototype.slice.call(receiver, start);
if (sliced.length !== 4095 || sliced.charAt(4094) !== "x") {
    throw new Error("receiver lost during argument coercion");
}

var search = {
    toString: function () { return "y".repeat(2048); }
};
if (String.prototype.indexOf.call(receiver, search) !== -1) {
    throw new Error("receiver lost during search coercion");
}

// Native callback results are copied into the caller's owned result slot.
var replacement = String.prototype.repeat.bind("z", 2048);
for (var i = 0; i < 100; i++) {
    var result = "a".replace(/a/, replacement);
    if (result.length !== 2048 || result.charAt(2047) !== "z") {
        throw new Error("native callback result lost");
    }
}
print("string callback ownership: PASS");

// The source text and parse records remain owned across reviver callbacks.
var parsed = JSON.parse({
    toString: function () {
        return '{"first":0,"second":"' + "q".repeat(2048) + '"}';
    }
}, function (key, value, context) {
    if (key === "first") this.second = "changed";
    if (key === "second" && value !== "changed") {
        throw new Error("reviver mutation lost");
    }
    return value;
});
if (parsed.second !== "changed") throw new Error("reviver result lost");
print("JSON callback ownership: PASS");
