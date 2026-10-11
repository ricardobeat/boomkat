function check(value, expected) {
    if (value !== expected) throw new Error("FAIL: " + value + " !== " + expected);
}
var resolvePending;
var pending = new Promise(function (resolve) { resolvePending = resolve; });
var order = [];
var longValue = "v".repeat(400);
var count = 0;
for (var i = 0; i < 12; i++) {
    (function (index) {
        pending.then(function (value) {
            check(value, longValue);
            order.push(index);
            count++;
        });
    })(i);
}
resolvePending(longValue);
pending.then(function () {
    check(order.join(","), "0,1,2,3,4,5,6,7,8,9,10,11");
});
var resolveSpecies;
class Derived extends Promise {}
var custom = new Derived(function (resolve) { resolveSpecies = resolve; });
var chained = custom.then(function (value) { check(value, longValue); return value; });
check(chained instanceof Derived, true);
chained.then(function (value) { check(value, longValue); count++; });
resolveSpecies(longValue);
Promise.reject(longValue).then().catch(function (value) { check(value, longValue); count++; });
async function verify() {
    for (var i = 0; i < 20; i++) await 0;
    check(count, 14);
    print("PASS native promise reactions");
}
verify();
