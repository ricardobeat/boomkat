function dynamicReceiver(a, b, n) {
    var sum = 0;
    for (var i = 0; i < n; i++) {
        var object;
        if (i & 1) object = a;
        else object = b;
        sum += object.x + object.x;
    }
    return sum;
}
for (var pass = 0; pass < 40; pass++) {
    var n = 9 + (pass & 3);
    var actual = dynamicReceiver({x: 5}, {x: 19}, n);
    var expected = 10*(n>>1) + 38*((n+1)>>1);
    if (actual !== expected) throw Error("dynamic receiver " + pass + ": " + actual + " != " + expected);
}
print("dynamic receiver ok");
