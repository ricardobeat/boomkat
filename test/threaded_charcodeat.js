function assert(value, message) { if (!value) throw new Error(message); }
function read(s, index) { return s.charCodeAt(index); }
for (var i = 0; i < 10000; i++) assert(read('abc', i % 3) === 97 + i % 3, 'ASCII');
assert(read('abc', 1.9) === 98, 'fractional index');
assert(read('abc', undefined) === 97, 'undefined index');
assert(read('abc', '2') === 99, 'string index');
assert(Number.isNaN(read('abc', -1)), 'negative index');
assert(Number.isNaN(read('abc', 3)), 'past end');
assert(Number.isNaN(read('', 0)), 'empty string');
assert(read('\u00e9\ud83d\ude00', 0) === 233, 'non-ASCII');
assert(read('\u00e9\ud83d\ude00', 1) === 0xd83d, 'high surrogate');
assert(read('\u00e9\ud83d\ude00', 2) === 0xde00, 'low surrogate');
assert(read(new String('abc'), 1) === 98, 'boxed receiver');
var conversions = 0;
assert(read('abc', {valueOf:function(){conversions++;return 1;}}) === 98, 'index coercion');
assert(conversions === 1, 'coercion ran once');
var threw = false;
try { read('abc', Symbol('index')); } catch (e) { threw = e instanceof TypeError; }
assert(threw, 'symbol index throws');
var original = String.prototype.charCodeAt;
try {
    String.prototype.charCodeAt = function () { return 73; };
    assert(read('abc', 0) === 73, 'replaced builtin');
    var gets = 0;
    Object.defineProperty(String.prototype, 'charCodeAt', {configurable:true,get:function(){gets++;return original;}});
    assert(read('abc', 1) === 98, 'getter supplies builtin');
    assert(gets === 1, 'method lookup ran');
} finally {
    Object.defineProperty(String.prototype, 'charCodeAt', {value:original,writable:true,configurable:true});
}
assert(read('abc', 2) === 99, 'restored builtin');
print('threaded_charcodeat: all checks passed');
