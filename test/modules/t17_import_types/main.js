// Import attribute types: `with { type: "json" | "text" | "bytes" }`.
//
// All three are CreateDefaultExportSyntheticModule -- one `default` export
// built from the file contents, no compilation, no dependencies. What is
// tested here beyond test262 is the module map: the same file under two
// different types is two different modules, and the engine's own loader
// conventions (extension probing, "empty read means keep looking") must not
// leak into a path that names its file exactly.

function assert(c, m) { if (!c) { throw new Error('FAIL: ' + m); } }

// --- text -----------------------------------------------------------------

import greeting from './greeting.txt' with { type: 'text' };
assert(typeof greeting === 'string', 'text module yields a string');
assert(greeting === 'hello, text', 'text module yields the file contents');

// An empty file is an empty text module, not a failed read. The default
// loader treats an empty read as "keep probing extensions", which must not
// reach a type-attributed import.
import blank from './empty.txt' with { type: 'text' };
assert(blank === '', 'empty file is an empty text module');

// A text module is never parsed as JavaScript, even when it is valid
// JavaScript. code_as_text.js throws if it is ever evaluated.
import source from './code_as_text.js' with { type: 'text' };
assert(typeof source === 'string', 'a .js file imported as text stays a string');
assert(source.indexOf('export var x = 1;') === 0, 'text module is the raw source');

// --- json -----------------------------------------------------------------

import data from './data.json' with { type: 'json' };
assert(typeof data === 'object' && data !== null, 'json module yields an object');
assert(data.n === 42, 'json module is the parsed value');

// --- bytes ----------------------------------------------------------------

import raw from './raw.bin' with { type: 'bytes' };
assert(raw instanceof Uint8Array, 'bytes module yields a Uint8Array');
assert(raw.length === 4, 'bytes module length');
assert(raw[0] === 0x00 && raw[1] === 0x01 && raw[2] === 0xfe && raw[3] === 0xff,
       'bytes module holds the raw file bytes');

// The buffer is immutable, so one importer cannot mutate the module's bytes
// under another's feet.
assert(raw.buffer instanceof ArrayBuffer, 'bytes module buffer is an ArrayBuffer');
assert(raw.buffer.immutable === true, 'bytes module buffer is immutable');
raw[0] = 99;
assert(raw[0] === 0x00, 'a write through the view is rejected');

var threw = false;
try { raw.buffer.transfer(); } catch (e) { threw = e instanceof TypeError; }
assert(threw, 'an immutable bytes buffer cannot be transferred');

import empty_bytes from './empty.txt' with { type: 'bytes' };
assert(empty_bytes instanceof Uint8Array, 'empty file is an empty bytes module');
assert(empty_bytes.length === 0, 'empty bytes module has length 0');

// --- the module map is keyed on the attributes, not the specifier alone ----

// empty.txt is imported above as text AND as bytes: two records, two values.
assert(typeof blank === 'string' && empty_bytes instanceof Uint8Array,
       'one file under two types is two distinct modules');

// --- dynamic import takes the same attributes -----------------------------

Promise.all([
    import('./greeting.txt', { with: { type: 'text' } }),
    import('./data.json',    { with: { type: 'json' } }),
    import('./raw.bin',      { with: { type: 'bytes' } }),
    // The same specifier with no attributes is the JavaScript module, which is
    // what code_as_text.js is: importing it for real must evaluate it, and it
    // throws. That the static text import above did NOT throw is the proof the
    // two never shared a record.
    import('./greeting.txt', { with: { type: 'text' } }),
]).then(function (mods) {
    assert(mods[0].default === 'hello, text', 'dynamic text import');
    assert(mods[1].default.n === 42, 'dynamic json import');
    assert(mods[2].default instanceof Uint8Array, 'dynamic bytes import');
    assert(mods[2].default.buffer.immutable === true, 'dynamic bytes buffer is immutable');
    assert(mods[3].default === mods[0].default, 'a repeated dynamic import is cached');
    print('PASS: import attribute types');
}, function (e) {
    print('FAIL: dynamic import rejected: ' + e);
    throw e;
});
