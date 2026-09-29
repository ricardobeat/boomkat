// Small fixed-length dense literals reserve only their logical dense length.

function fail(message) { throw new Error(message); }

var order = "";
var tuple = [
    (order += "a", 11),
    ,
    (order += "b", undefined),
    (order += "c", 33)
];
if (order !== "abc") fail("array element evaluation order");
if (tuple.length !== 4) fail("array literal length");
if (!tuple.hasOwnProperty("0") || tuple.hasOwnProperty("1")
    || !tuple.hasOwnProperty("2") || !tuple.hasOwnProperty("3")) {
    fail("holes and explicit undefined retain distinct ownership");
}
if (Object.keys(tuple).join(",") !== "0,2,3") {
    fail("dense array used count tracks initialized slots");
}

var holes = [,,,];
if (holes.length !== 3 || holes.hasOwnProperty("0")
    || holes.hasOwnProperty("1") || holes.hasOwnProperty("2")) {
    fail("all-hole arrays remain sparse");
}

var spread = [1, ...[2, 3], 4];
if (spread.length !== 4 || spread[0] !== 1 || spread[1] !== 2
    || spread[2] !== 3 || spread[3] !== 4) {
    fail("spread array literals retain dynamic indexing");
}

var marker = {};
var genericValues = [marker, "text", null, true];
if (genericValues[0] !== marker || genericValues[1] !== "text"
    || genericValues[2] !== null || genericValues[3] !== true) {
    fail("heap and non-number values retain the generic initialization path");
}

var arrayProto = Array.prototype;
var oldIndexSetter = Object.getOwnPropertyDescriptor(arrayProto, "5");
var setterCalls = 0;
try {
    Object.defineProperty(arrayProto, "5", {
        configurable: true,
        set: function () { setterCalls++; }
    });
    var setterArray = [11, 22, 33, 44, 55, 66];
    if (setterCalls !== 0 || !setterArray.hasOwnProperty("5")
        || setterArray[5] !== 66) {
        fail("array literal initialization bypasses inherited setters");
    }
} finally {
    if (oldIndexSetter) Object.defineProperty(arrayProto, "5", oldIndexSetter);
    else delete arrayProto[5];
}

tuple[4] = 55;
if (tuple.length !== 5 || tuple[4] !== 55
    || Object.keys(tuple).join(",") !== "0,2,3,4") {
    fail("dense part grows after literal creation");
}

print("array_literal_capacity_hint: all checks passed");
