// Serialize prebuilt payloads so the timings isolate JSON work.
var small = {id: 1, name: 'boomkat', tags: ['a', 'b', 'c'], nested: {ok: true, n: 42.5}};
var rows = [];
for (var i = 0; i < 100; i++) {
    rows.push({id: i, name: 'user-' + i, email: 'user-' + i + '@example.com',
        active: i % 2 === 0, roles: ['reader'], profile: {city: 'Amsterdam', visits: i * 3}});
}
var mixed = [small, {message: 'ok'}, {items: [1, 2, 3], next: null},
    {id: 4, enabled: false, status: 'queued'}, {metrics: {requests: 17, errors: 0}}];
var ascii = {id: 1, text: 'ordinary response text '.repeat(3000)};
var unicode = {text: 'é漢字😀'.repeat(1000)};
var escaped = {text: 'line\n"quoted"\\path\t'.repeat(100)};
var dictionary = {};
for (var i = 0; i < 100; i++) dictionary['field' + i] = i;
var getter = {id: 1, get value() { return 17; }, status: 'ok'};
function measure(name, payloads, count, replacer) {
    var checksum = 0;
    for (var warm = 0; warm < 20; warm++) JSON.stringify(payloads[warm % payloads.length], replacer);
    var start = Date.now();
    for (var i = 0; i < count; i++) checksum += JSON.stringify(payloads[i % payloads.length], replacer).length;
    var elapsed = Date.now() - start;
    print(name + '\t' + elapsed + '\t' + checksum);
}
measure('small', [small], 100000);
measure('rows', [rows], 2000);
measure('mixed', mixed, 100000);
measure('ascii', [ascii], 1000);
measure('unicode', [unicode], 1000);
measure('escaped', [escaped], 2000);
measure('replacer', [small], 30000, function (key, value) { return value; });
measure('dictionary', [dictionary], 10000);
measure('getter', [getter], 50000);
