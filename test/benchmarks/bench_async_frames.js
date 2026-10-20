// Await timing includes completion of every queued continuation.
var rounds = 100000;
async function narrow() {
    var total = 0;
    for (var i = 0; i < rounds; i++) total = await (total + 1);
    return total;
}
async function wide() {
    var v0 = "field0".repeat(20);
    var v1 = "field1".repeat(20);
    var v2 = "field2".repeat(20);
    var v3 = "field3".repeat(20);
    var v4 = "field4".repeat(20);
    var v5 = "field5".repeat(20);
    var v6 = "field6".repeat(20);
    var v7 = "field7".repeat(20);
    var v8 = "field8".repeat(20);
    var v9 = "field9".repeat(20);
    var v10 = "field10".repeat(20);
    var v11 = "field11".repeat(20);
    var v12 = "field12".repeat(20);
    var v13 = "field13".repeat(20);
    var v14 = "field14".repeat(20);
    var v15 = "field15".repeat(20);
    var v16 = "field16".repeat(20);
    var v17 = "field17".repeat(20);
    var v18 = "field18".repeat(20);
    var v19 = "field19".repeat(20);
    var v20 = "field20".repeat(20);
    var v21 = "field21".repeat(20);
    var v22 = "field22".repeat(20);
    var v23 = "field23".repeat(20);
    var total = 0;
    for (var i = 0; i < rounds; i++) total = await (total + 1);
    return total + v0.length + v1.length + v2.length + v3.length + v4.length + v5.length + v6.length + v7.length + v8.length + v9.length + v10.length + v11.length + v12.length + v13.length + v14.length + v15.length + v16.length + v17.length + v18.length + v19.length + v20.length + v21.length + v22.length + v23.length;
}
var start = Date.now();
narrow().then(function (result) {
    print(JSON.stringify({ name: 'narrow', ms: Date.now() - start, result: result }));
    start = Date.now();
    return wide();
}).then(function (result) {
    print(JSON.stringify({ name: 'wide', ms: Date.now() - start, result: result }));
});
