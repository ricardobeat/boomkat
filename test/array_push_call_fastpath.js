// The one-argument intrinsic push call shortcut preserves generic cases.

function fail(message) { throw new Error(message); }

var originalPush = Array.prototype.push;
var item = { value: 17 };
var values = [];
for (var i = 0; i < 64; i++) {
    if (values.push(item) !== i + 1 || values[i] !== item) {
        fail("one-argument push returns length and stores object values");
    }
}

// Undefined cannot live in dense storage because holes and explicit undefined
// need different own-property results.
var withUndefined = [];
if (withUndefined.push(undefined) !== 1 || !withUndefined.hasOwnProperty("0")) {
    fail("undefined argument takes the generic own-property path");
}

// A patched method is an ordinary call and must keep its own behavior.
try {
    Array.prototype.push = function (value) {
        this.patchedValue = value;
        return 91;
    };
    var patched = [];
    if (patched.push(item) !== 91 || patched.patchedValue !== item || patched.length !== 0) {
        fail("patched push keeps user code and result");
    }
} finally {
    Array.prototype.push = originalPush;
}

// A getter may return the exact intrinsic; its observable call still runs once.
var pushDescriptor = Object.getOwnPropertyDescriptor(Array.prototype, "push");
var getterCalls = 0;
try {
    Object.defineProperty(Array.prototype, "push", {
        configurable: true,
        get: function () { getterCalls++; return originalPush; }
    });
    var fromGetter = [];
    if (fromGetter.push(item) !== 1 || fromGetter[0] !== item || getterCalls !== 1) {
        fail("push getter runs before the intrinsic append");
    }
} finally {
    Object.defineProperty(Array.prototype, "push", pushDescriptor);
}

// A custom prototype's indexed setter must intercept the append.
var customProto = Object.create(Array.prototype);
var setterCalls = 0;
Object.defineProperty(customProto, "1", {
    configurable: true,
    set: function () { setterCalls++; }
});
var custom = [0];
Object.setPrototypeOf(custom, customProto);
if (custom.push(2) !== 2 || setterCalls !== 1 || custom.hasOwnProperty("1")) {
    fail("custom prototype setter intercepts push");
}

// Spare capacity does not make an append legal on a non-extensible array.
var blocked = [0];
blocked[15] = 15;
blocked.length = 1;
Object.preventExtensions(blocked);
var blockedByExtensibility = false;
try { blocked.push(2); }
catch (e) { blockedByExtensibility = e instanceof TypeError; }
if (!blockedByExtensibility || blocked.length !== 1 || blocked.hasOwnProperty("1")) {
    fail("non-extensible array rejects append even with spare capacity");
}

print("array_push_call_fastpath: all checks passed");
