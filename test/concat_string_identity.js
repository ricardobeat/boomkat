function check(ok, message) {
    if (!ok) throw new Error(message);
}
function join(a, b) { return a + b; }
var key = join('dynamic', 'Key');
var same = join('dyna', 'micKey');
check(key === same && Object.is(key, same), 'content equality');
check([key].indexOf(same) === 0 && [key].includes(same), 'array equality');
var map = new Map(), set = new Set(), retained = [];
for (var i = 0; i < 1000; i++) {
    var value = join('key:', i);
    retained.push(value);
    map.set(value, i);
    set.add(value);
}
for (var i = 0; i < 1000; i++) {
    var value = join('key', ':' + i);
    check(map.get(value) === i && set.has(value), 'collection identity ' + i);
    check(retained[i] === value, 'retained string ' + i);
}
var object = {};
object[key] = 17;
check(object[same] === 17 && same in object, 'property lookup');
Object.defineProperty(object, join('access', 'or'), {get: function () {return 23;}, configurable: true});
check(Reflect.get(object, join('acc', 'essor')) === 23, 'descriptor key');
check(Reflect.deleteProperty(object, join('accesso', 'r')), 'delete key');
check(!('accessor' in object), 'deleted property');
check(JSON.parse(JSON.stringify(object))[same] === 17, 'JSON key');
var proxy = new Proxy(object, {get: function (target, name) {return target[name];}});
check(proxy[join('dynamicK', 'ey')] === 17, 'proxy key');
var unicode = join('\ud83d', '\ude00');
check(unicode === '\ud83d\ude00' && unicode.length === 2, 'surrogate pair');
check(join('\ud800', 'x') === '\ud800x', 'lone surrogate');
check(join('é', '水') === 'é水', 'non-ASCII content');
check(join('', '') === '' && join('a\0', 'b') === 'a\0b', 'empty and NUL');
var accumulator = join('seed', ':');
var alias = accumulator;
for (var i = 0; i < 1000; i++) accumulator += 'x';
check(alias === 'seed:' && accumulator.length === 1005, 'accumulator alias');
var duplicateRejected = false;
try {
    Reflect.ownKeys(new Proxy({}, {ownKeys: function () {return [key, same];}}));
} catch (e) { duplicateRejected = e instanceof TypeError; }
check(duplicateRejected, 'duplicate dynamic proxy keys');
var fixed = {};
Object.defineProperty(fixed, key, {value: 31, configurable: false});
var fixedProxy = new Proxy(fixed, {ownKeys: function () {return [same];}});
check(Reflect.ownKeys(fixedProxy)[0] === key, 'non-configurable dynamic proxy key');
print('PASS concatenation string identity');
