function equal(actual, expected) {
    if (actual !== expected) throw new Error('JSON plan: ' + actual + ' !== ' + expected);
}
function ordinary() { return {first: 1, second: 2, third: 3}; }
function warmed() {
    var value = ordinary();
    equal(JSON.stringify(value), '{"first":1,"second":2,"third":3}');
    return value;
}
for (var i = 0; i < 30; i++) {
    var value = warmed();
    value.second = i;
    equal(JSON.parse(JSON.stringify(value)).second, i);
}
var deleted = warmed();
equal(JSON.stringify(deleted, function (key, value) {
    if (key === 'first') { delete this.second; this.third = 30; this.added = 4; }
    return value;
}), '{"first":1,"third":30}');
var inherited = warmed();
Object.setPrototypeOf(inherited, {second: 42});
equal(JSON.stringify(inherited, function (key, value) {
    if (key === 'first') delete this.second;
    return value;
}), '{"first":1,"second":42,"third":3}');
var accessor = warmed(), gets = 0;
equal(JSON.stringify(accessor, function (key, value) {
    if (key === 'first') Object.defineProperty(this, 'second', {
        enumerable: true, configurable: true, get: function () { gets++; return 99; }
    });
    return value;
}), '{"first":1,"second":99,"third":3}');
equal(gets, 1);
var descriptors = warmed();
Object.defineProperty(descriptors, 'second', {enumerable: false});
equal(JSON.stringify(descriptors), '{"first":1,"third":3}');
Object.defineProperty(descriptors, 'second', {enumerable: true});
equal(JSON.stringify(descriptors), '{"first":1,"second":2,"third":3}');
Object.freeze(descriptors);
equal(JSON.stringify(descriptors), '{"first":1,"second":2,"third":3}');
var holder = {child: {toJSON: function () { delete holder.tail; holder.newKey = 4; return 7; }}, tail: 2};
equal(JSON.stringify(holder), '{"child":7}');
var reentrant = warmed(), nested;
equal(JSON.stringify(reentrant, function (key, value) {
    if (key === 'first') { delete this.second; nested = JSON.stringify(this); }
    return value;
}), '{"first":1,"third":3}');
equal(nested, '{"first":1,"third":3}');
var keys = {'10': 10, '2': 2, '\n"\\': '😀', '😀': 4, tail: undefined};
keys[Symbol('ignored')] = 9;
equal(JSON.stringify(keys), '{"2":2,"10":10,"\\n\\"\\\\":"😀","😀":4}');
equal(JSON.stringify(keys, null, 2), '{\n  "2": 2,\n  "10": 10,\n  "\\n\\"\\\\": "😀",\n  "😀": 4\n}');
equal(JSON.stringify(warmed(), ['third', 'first']), '{"third":3,"first":1}');
var calls = 0;
var proxy = new Proxy(ordinary(), {get: function (target, key) { calls++; return target[key]; }});
equal(JSON.stringify(proxy), '{"first":1,"second":2,"third":3}');
equal(calls, 4);
equal(JSON.stringify(new Uint8Array([4, 5])), '{"0":4,"1":5}');
equal(JSON.stringify(new String('ab')), '"ab"');
var caught = false;
try { JSON.stringify(warmed(), function (key, value) { if (key === 'first') throw new Error('stop'); return value; }); }
catch (error) { caught = error.message === 'stop'; }
equal(caught, true);
equal(JSON.stringify(warmed()), '{"first":1,"second":2,"third":3}');
var cyclic = warmed(); cyclic.third = cyclic;
caught = false;
try { JSON.stringify(cyclic); } catch (error) { caught = error instanceof TypeError; }
equal(caught, true);

// Dynamic shared shapes can disappear during callbacks. Their plans retain
// both their key strings and the original enumeration through nested calls.
function dynamic() {
    var value = {};
    value['head' + 'Key'] = 1;
    value['long'.repeat(100)] = 2;
    return value;
}
var peer = dynamic(), active = dynamic();
JSON.stringify(peer); peer = null;
equal(JSON.stringify(active, function (key, value) {
    if (key === 'headKey') {
        delete this['long'.repeat(100)];
        for (var i = 0; i < 100; i++) { var garbage = {}; garbage['churn' + i] = i; }
        JSON.stringify(this);
    }
    return value;
}), '{"headKey":1}');
print('json_shape_plan: PASS');
