function fail(message) { throw new Error(message); }

function collect(...args) { return args; }

var object = { marker: 17 };
var values = collect(undefined, object, 23, 29, 31, 37, 41, 43);
if (values.length !== 8 || values[0] !== undefined || values[1] !== object
    || values[7] !== 43 || !values.hasOwnProperty("0")
    || Object.keys(values).join(",") !== "0,1,2,3,4,5,6,7") {
    fail("rest array preserves explicit undefined, dense values, and own keys");
}

var originalZero = Object.getOwnPropertyDescriptor(Array.prototype, "0");
var getterCalls = 0;
var setterCalls = 0;
try {
    Object.defineProperty(Array.prototype, "0", {
        configurable: true,
        get: function () { getterCalls++; return 99; },
        set: function () { setterCalls++; }
    });
    var inherited = collect(undefined, 5);
    if (!inherited.hasOwnProperty("0") || inherited[0] !== undefined
        || inherited[1] !== 5 || getterCalls !== 0 || setterCalls !== 0) {
        fail("rest initialization defines own elements without indexed accessors");
    }
} finally {
    if (originalZero) Object.defineProperty(Array.prototype, "0", originalZero);
    else delete Array.prototype["0"];
}

var undefinedOnly = collect(undefined);
if (!undefinedOnly.hasOwnProperty("0") || !delete undefinedOnly[0]
    || undefinedOnly.hasOwnProperty("0") || undefinedOnly.length !== 1) {
    fail("explicit undefined remains a deletable own property");
}

var emptyA = collect();
var emptyB = collect();
if (emptyA.length !== 0 || emptyA === emptyB) {
    fail("each call creates a fresh empty rest array");
}

var indirect = collect;
if (indirect(47, 53)[1] !== 53) fail("indirect call copies rest values");

function withDefault(first = 59, ...rest) {
    return first + rest.length + arguments.length;
}
if (withDefault(undefined, 61, 67) !== 64) {
    fail("default parameters retain the original arguments object");
}

function* generated(...args) { return args; }
var generatedValues = generated(undefined, object, 71).next().value;
if (!generatedValues.hasOwnProperty("0") || generatedValues[1] !== object
    || generatedValues[2] !== 71) {
    fail("generator creation preserves rest argument ownership");
}

function Constructed(...args) { this.values = args; }
var constructed = new Constructed(undefined, object, 73);
if (!constructed.values.hasOwnProperty("0") || constructed.values[1] !== object
    || constructed.values[2] !== 73) {
    fail("constructor entry preserves rest argument ownership");
}

class Base {
    constructor(...args) { this.values = args; }
}
class Derived extends Base {
    constructor(...args) { super(...args); }
}
var derived = new Derived(undefined, object, 79);
if (!derived.values.hasOwnProperty("0") || derived.values[1] !== object
    || derived.values[2] !== 79) {
    fail("super constructor entry preserves rest argument ownership");
}

print("rest_parameter_array_fastpath: all checks passed");
