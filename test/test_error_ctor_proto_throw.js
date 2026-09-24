function checkConstructor(constructor, args, label) {
    var messageReads = 0;
    var message = {
        toString: function () { messageReads++; return "message"; }
    };
    var revocable = Proxy.revocable(function () {}, {
        get: function (target, key, receiver) {
            if (key === "prototype") {
                revocable.revoke();
                return null;
            }
            return Reflect.get(target, key, receiver);
        }
    });
    try {
        Reflect.construct(constructor, args(message), revocable.proxy);
        print("FAIL: " + label + " accepted revoked newTarget");
    } catch (error) {
        if (!(error instanceof TypeError)) print("FAIL: " + label + " wrong error");
    }
    if (messageReads !== 0) print("FAIL: " + label + " coerced message after throw");
}

checkConstructor(Error, function (message) { return [message]; }, "Error");
checkConstructor(AggregateError, function (message) { return [[], message]; }, "AggregateError");
