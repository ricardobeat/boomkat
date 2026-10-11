function check(value, expected) {
    if (value !== expected) throw new Error("FAIL persistent async: " + value + " !== " + expected);
}
async function run(label, rounds) {
    var text = label;
    var receiver = this;
    for (var i = 0; i < rounds; i++) {
        text = await Promise.resolve(text + i);
        check(this, receiver);
        try { await Promise.reject("r".repeat(350) + i); }
        catch (e) { check(e, "r".repeat(350) + i); }
        await { then: function (resolve) { resolve(1); } };
    }
    return text;
}
async function growing() {
    var a = "a".repeat(350);
    await 0;
    var b = "b".repeat(350);
    await 0;
    return a + b;
}
async function recursive(n) {
    if (n === 0) return 0;
    await 0;
    var below = await recursive(n - 1);
    await 0;
    return below + 1;
}
async function finallyValue() {
    try { await 0; throw "reason"; }
    finally { await 0; await 0; }
}
async function verify() {
    var values = await Promise.all([run.call({ x: 1 }, "left", 6), run.call({ x: 2 }, "right", 6)]);
    check(values[0], "left012345");
    check(values[1], "right012345");
    check(await growing(), "a".repeat(350) + "b".repeat(350));
    check(await recursive(8), 8);
    var reason;
    try { await finallyValue(); } catch (e) { reason = e; }
    check(reason, "reason");
    var resolve;
    var pending = new Promise(function (r) { resolve = r; });
    async function wait() { var value = await pending; await 0; return value; }
    var waiter = wait();
    resolve("pending".repeat(60));
    check(await waiter, "pending".repeat(60));
    print("PASS persistent async frames");
}
verify();
