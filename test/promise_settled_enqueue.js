var order = [];
Promise.resolve(1).then(function (v) { order.push("first:" + v); });
Promise.reject("reason").then().catch(function (v) { order.push("reject:" + v); });
Promise.resolve().then(function () { order.push("second"); });
order.push("sync");
async function verify() {
    for (var i = 0; i < 10; i++) await 0;
    if (order.join(",") !== "sync,first:1,second,reject:reason") {
        throw new Error("FAIL ordering: " + order);
    }
    class Sub extends Promise {}
    var derived = Sub.resolve(2).then(function (v) { order.push("sub:" + v); return v + 1; });
    if (!(derived instanceof Sub)) throw new Error("FAIL species result");
    if (await derived !== 3) throw new Error("FAIL chained value");
    print("PASS settled enqueue");
}
verify();
