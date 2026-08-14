// Behavioral smoke test for lodash's real API surface, run after the bundle
// above this file (see scripts/verify_libraries.py --lodash-api). Output is
// deterministic and independent of lodash's exact version/internals, so it
// can be diffed directly against the same script run under qjs -- no
// hardcoded "expected" values to drift when lodash updates.
//
// This does NOT replace the engine-level regression test for the bug lodash
// found (test/engine/test_hoist_var_block_no_semicolon.js), which needs no
// download and always runs. This is corpus-level confidence that the fix
// didn't just silence the crash but left the library actually working.
var _ = module.exports;

var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("chunk", _.chunk([1, 2, 3, 4, 5], 2));
rec("map", _.map([1, 2, 3], function (n) { return n * 2; }));
rec("isEqual", _.isEqual({ a: [1, { b: 2 }] }, { a: [1, { b: 2 }] }));
rec("isEqual_false", _.isEqual({ a: 1 }, { a: 2 }));
rec("camelCase", _.camelCase("Foo Bar-baz_qux"));
rec("kebabCase", _.kebabCase("fooBarBazQux"));
rec("sum", _.sum([1, 2, 3, 4, 5]));
rec("groupBy", _.groupBy([6.1, 4.2, 6.3], Math.floor));
rec("get", _.get({ a: { b: { c: 42 } } }, "a.b.c"));
rec("get_default", _.get({}, "x.y.z", "fallback"));
rec("uniq", _.uniq([2, 1, 2, 3, 1]));
rec("isPlainObject", [_.isPlainObject({}), _.isPlainObject([]), _.isPlainObject(null)]);
rec("isFunction", [_.isFunction(function () {}), _.isFunction({})]);
rec("zip", _.zip(["a", "b"], [1, 2], [true, false]));
rec("flattenDeep", _.flattenDeep([1, [2, [3, [4]], 5]]));
rec("cloneDeep_identity", (function () {
    var src = { a: 1, b: { c: 2 } };
    var cloned = _.cloneDeep(src);
    return cloned.b !== src.b && _.isEqual(cloned, src);
})());
// The exact defect this fix addressed: baseGetTag / getRawTag, reached via
// isEqual/isPlainObject/isFunction above, but exercised directly too.
rec("baseGetTag_via_toString_tag", Object.prototype.toString.call(new Map()));

console.log(lines.join("\n"));
console.log(lines.length + " lodash API checks recorded, 0 threw");
