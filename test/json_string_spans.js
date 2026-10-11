function equal(actual, expected) {
    if (actual !== expected) throw new Error('JSON string mismatch');
}
var hex = '0123456789abcdef';
for (var code = 0; code < 128; code++) {
    var character = String.fromCharCode(code);
    var escaped = character;
    if (code === 34 || code === 92) escaped = '\\' + character;
    else if (code === 8) escaped = '\\b';
    else if (code === 9) escaped = '\\t';
    else if (code === 10) escaped = '\\n';
    else if (code === 12) escaped = '\\f';
    else if (code === 13) escaped = '\\r';
    else if (code < 32) escaped = '\\u00' + hex[code >> 4] + hex[code & 15];
    // Exercise each byte on both sides of the word scan boundary.
    for (var prefix = 0; prefix < 17; prefix++) {
        var padding = 'a'.repeat(prefix);
        equal(JSON.stringify(padding + character + padding), '"' + padding + escaped + padding + '"');
    }
}
var samples = ['é', '漢字', '\ud800', '\udfff', '\ud800\udc00', '😀',
    '\ud800A\udfff', '\ud800\ud800\udc00', '\udc00\ud800', 'a😀é\n漢字'];
for (var i = 0; i < samples.length; i++) {
    var value = samples[i];
    equal(JSON.parse(JSON.stringify(value)), value);
    equal(JSON.parse(JSON.stringify({[value]: value}))[value], value);
}
equal(JSON.stringify('\ud800'), '"\\ud800"');
equal(JSON.stringify('\udfff'), '"\\udfff"');
equal(JSON.stringify('😀'), '"😀"');
equal(JSON.stringify('😀').length, 4);
var large = ('abcdefgh"\\\n😀é').repeat(1000);
equal(JSON.parse(JSON.stringify(large)), large);
var key = JSON.stringify({id: 7});
var object = {};
object[key] = 13;
equal(object[JSON.stringify({id: 7})], 13);
equal(JSON.stringify({id: 7}), key);
equal(JSON.stringify({text: '😀'}, null, '😀'), '{\n😀"text": "😀"\n}');
if (typeof JSON.rawJSON === 'function') {
    equal(JSON.stringify({value: JSON.rawJSON('"😀"')}), '{"value":"😀"}');
}
print('json_string_spans: PASS');
