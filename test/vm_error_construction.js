(function () {
    function check(condition, message) {
        if (!condition) throw new Error(message);
    }
    function expectTypeError(fn, message) {
        var error;
        try { fn(); } catch (caught) { error = caught; }
        check(error instanceof TypeError, "TypeError identity: " + message);
        check(error.message === message, "message: " + message);
        var descriptor = Object.getOwnPropertyDescriptor(error, "message");
        check(descriptor && descriptor.writable && descriptor.enumerable && descriptor.configurable,
              "VM error message descriptor");
    }
    for (var i = 0; i < 20; i++) {
        expectTypeError(function () { return +Symbol(); }, "Cannot convert a Symbol value to a number");
        expectTypeError(function () { return +1n; }, "Cannot convert a BigInt value to a number");
        expectTypeError(function () { return +Object.create(null); }, "Cannot convert object to primitive value");
        expectTypeError(function () { with (null) {} }, "Cannot use 'with' on null");
        expectTypeError(function () { with (undefined) {} }, "Cannot use 'with' on undefined");
        check(+{ valueOf: function () { return 42; } } === 42, "coercion after a caught error");
    }
    print("VM error construction passed");
})();
