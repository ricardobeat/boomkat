(function () {
    function check(condition, message) {
        if (!condition) throw new Error(message);
    }

    var methods = [
        [Array.prototype, "push", 1],
        [String.prototype, "charAt", 1],
        [String.prototype, "padStart", 1],
        [Date.prototype, "getTimezoneOffset", 0],
        [Map.prototype, "get", 1],
        [Map.prototype, "getOrInsert", 2],
        [Set.prototype, "union", 1],
        [WeakMap.prototype, "getOrInsertComputed", 2],
        [DataView.prototype, "getInt8", 1],
        [Uint8Array.prototype, "map", 1],
        [Math, "hypot", 2],
        [Math, "f16round", 1],
        [Temporal.PlainDate, "from", 1],
        [Temporal.Duration.prototype, "add", 1]
    ];
    methods.forEach(function (entry) {
        var object = entry[0], name = entry[1], length = entry[2];
        var property = Object.getOwnPropertyDescriptor(object, name);
        // TypedArray methods belong to the shared intrinsic prototype.
        if (!property) property = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(object), name);
        check(property && property.writable && !property.enumerable && property.configurable, name + " descriptor");
        var method = property.value;
        check(method.name === name && method.length === length, name + " metadata");
        ["length", "name"].forEach(function (key) {
            var descriptor = Object.getOwnPropertyDescriptor(method, key);
            check(!descriptor.writable && !descriptor.enumerable && descriptor.configurable, name + "." + key);
        });
        check(!Object.prototype.hasOwnProperty.call(method, "prototype"), name + " prototype");
        var rejected = false;
        try { Reflect.construct(function () {}, [], method); }
        catch (error) { rejected = error instanceof TypeError; }
        check(rejected, name + " must reject construction");
    });

    check(Array.prototype[Symbol.iterator] === Array.prototype.values, "Array iterator identity");
    check(Map.prototype[Symbol.iterator] === Map.prototype.entries, "Map iterator identity");
    check(Set.prototype[Symbol.iterator] === Set.prototype.values, "Set iterator identity");
    check(Set.prototype.keys === Set.prototype.values, "Set keys identity");
    check(String.prototype.trimLeft === String.prototype.trimStart, "trimLeft identity");
    check(String.prototype.trimRight === String.prototype.trimEnd, "trimRight identity");
    check(Date.prototype.toGMTString === Date.prototype.toUTCString, "toGMTString identity");

    var keys = Object.getOwnPropertyNames(Map.prototype);
    check(keys.indexOf("set") < keys.indexOf("get") && keys.indexOf("get") < keys.indexOf("has"), "Map method order");
    check(keys.indexOf("entries") < keys.indexOf("forEach") && keys.indexOf("forEach") < keys.indexOf("size"), "Map accessor order");
    var getter = Object.getOwnPropertyDescriptor(Temporal.Duration.prototype, "years");
    check(typeof getter.get === "function" && getter.set === undefined && !getter.enumerable && getter.configurable, "Temporal getter descriptor");
    var durationKeys = Object.getOwnPropertyNames(Temporal.Duration.prototype);
    check(durationKeys.indexOf("years") < durationKeys.indexOf("months") && durationKeys.indexOf("months") < durationKeys.indexOf("days"), "Temporal getter order");
    print("builtin registration passed");
})();
