var prototypeReads = 0;
var newTarget = new Proxy(function () {}, {
    get: function (target, key, receiver) {
        if (key === "prototype") prototypeReads++;
        return Reflect.get(target, key, receiver);
    }
});

try {
    Reflect.construct(Promise, [null], newTarget);
    print("FAIL: non-callable executor was accepted");
} catch (error) {
    if (!(error instanceof TypeError)) print("FAIL: wrong executor error");
}
if (prototypeReads !== 0) print("FAIL: prototype read before executor check");

Reflect.construct(Promise, [function (resolve) { resolve(1); }], newTarget);
if (prototypeReads !== 1) print("FAIL: callable executor prototype read count");
