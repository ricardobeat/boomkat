// `lastIndex` keeps its attributes across every write.
//
// RegExpInitialize creates it {writable: true, enumerable: false,
// configurable: false}, and every later write is a Set, which passes only
// [[Value]] to DefineOwnProperty (ES2020 §10.1.9.2). The attributes are
// visible through getOwnPropertyDescriptor, Object.keys and JSON.stringify,
// so a write that restored the {enumerable, configurable} defaults would be
// observable from script.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }

function checkAttrs(re, when) {
    var d = Object.getOwnPropertyDescriptor(re, 'lastIndex');
    ok(d !== undefined, when + ': lastIndex is an own property');
    ok(d.writable === true, when + ': writable');
    ok(d.enumerable === false, when + ': non-enumerable');
    ok(d.configurable === false, when + ': non-configurable');
    ok(Object.keys(re).indexOf('lastIndex') === -1, when + ': not in Object.keys');
    ok(JSON.stringify(re) === '{}', when + ': not in JSON.stringify');
}

var re = /a/g;
checkAttrs(re, 'fresh');

// exec writes lastIndex on a match and on a reset-to-0 miss.
re.exec('aaa');
ok(re.lastIndex === 1, 'exec advanced lastIndex');
checkAttrs(re, 'after exec match');

re.lastIndex = 10;
re.exec('aaa');
ok(re.lastIndex === 0, 'a failed exec resets lastIndex');
checkAttrs(re, 'after exec miss');

// A plain assignment goes through the VM rather than the builtin.
re.lastIndex = 2;
checkAttrs(re, 'after assignment');

// The @@match, @@replace, @@split and @@matchAll paths write it too.
'aaa'.match(/a/g);
checkAttrs(/a/g, 'after match');

var re2 = /a/g;
'aaa'.replace(re2, 'b');
checkAttrs(re2, 'after replace');

var re3 = /a/g;
'aaa'.split(re3);
checkAttrs(re3, 'after split');

var re4 = /a/g;
Array.from('aaa'.matchAll(re4));
checkAttrs(re4, 'after matchAll');

// A sticky regexp takes the same write paths.
var re5 = /a/y;
re5.exec('aaa');
checkAttrs(re5, 'after sticky exec');

// RegExpInitialize is a Set too: re-initializing through the constructor on an
// existing object must not redefine the property either.
var re6 = /a/g;
re6.exec('aaa');
RegExp.call(re6);
checkAttrs(re6, 'after re-initialize');

// A non-writable lastIndex makes Set throw rather than silently redefining.
var re7 = /a/g;
Object.defineProperty(re7, 'lastIndex', { writable: false });
var threw = false;
try { re7.exec('aaa'); } catch (e) { threw = e instanceof TypeError; }
ok(threw, 'exec on a non-writable lastIndex throws a TypeError');
var d7 = Object.getOwnPropertyDescriptor(re7, 'lastIndex');
ok(d7.writable === false, 'a throwing Set leaves lastIndex non-writable');

if (fail === 0) {
    print('PASS: RegExp lastIndex attributes (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
