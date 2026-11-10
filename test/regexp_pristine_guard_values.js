// The pristine-prototype guard remembers the intrinsic it last verified in
// each guarded slot of RegExp.prototype. Replacing a method or a flag getter
// keeps the prototype's shape, so every replacement below must still turn the
// fast paths off, and restoring the intrinsic must turn them back on.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }

function warm() {
    for (var i = 0; i < 50; i++) {
        'a.b.c'.replace(/\./g, '-');
        /b/.exec('abc');
        'a,b'.split(/,/);
    }
}

warm();
ok('a.b.c'.replace(/\./g, '-') === 'a-b-c', 'intrinsic replace');

// A replaced exec is called by @@replace.
var origExec = RegExp.prototype.exec;
var calls = 0;
RegExp.prototype.exec = function (s) { calls++; return origExec.call(this, s); };
ok('a.b'.replace(/\./g, '-') === 'a-b', 'replace through patched exec');
ok(calls === 2, 'patched exec ran for each match and the final miss: ' + calls);
RegExp.prototype.exec = origExec;
warm();
calls = 0;
ok('a.b'.replace(/\./g, '-') === 'a-b' && calls === 0, 'intrinsic exec restored');

// A getter replaced in place (same accessor slot) is seen as well.
var flagsDesc = Object.getOwnPropertyDescriptor(RegExp.prototype, 'global');
var globalReads = 0;
Object.defineProperty(RegExp.prototype, 'global', {
    get: function () { globalReads++; return flagsDesc.get.call(this); },
    configurable: true
});
'a.b'.replace(/\./g, '-');
ok(globalReads > 0, 'patched global getter was read');
Object.defineProperty(RegExp.prototype, 'global', flagsDesc);
warm();
globalReads = 0;
'a.b'.replace(/\./g, '-');
ok(globalReads === 0, 'intrinsic global getter restored');

// A value that is not a function in a guarded slot.
RegExp.prototype.exec = undefined;
var threw = false;
try { 'a.b'.replace(/\./g, '-'); } catch (e) { threw = true; }
ok(!threw, 'undefined exec falls back to the builtin exec per spec');
RegExp.prototype.exec = origExec;

// @@replace replaced with a primitive replacement value.
var origReplace = RegExp.prototype[Symbol.replace];
RegExp.prototype[Symbol.replace] = function () { return 'patched'; };
ok('a.b'.replace(/\./g, 1) === 'patched', 'patched @@replace with a number replacement');
RegExp.prototype[Symbol.replace] = origReplace;
ok('a.b'.replace(/\./g, 1) === 'a1b', 'intrinsic @@replace restored');

print(fail === 0 ? 'PASS ' + pass : 'FAIL ' + fail);
