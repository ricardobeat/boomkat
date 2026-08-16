// Regression coverage for looks_like_module's depth tracking.
//
// looks_like_module() in cli/duktape_c3.c3 is the gate that routes a file
// through the ESM pipeline (imports/exports at top level) or the script
// pipeline (everything else). It used to treat any post-newline position as a
// statement start, which made a plain script containing a multi-line object
// literal with `export: 1,` or `import: 2,` keys at line starts look like a
// module (typescript 5.4.5's bundle was the real-world trip wire). The fix
// tracks brace/paren/bracket nesting depth and only matches the keywords at
// depth 0; `import` followed by `(` is also excluded, so a dynamic
// import() expression in a plain script is not misclassified as a module.
//
// WHAT MAKES THIS FRAGILE (read before simplifying anything below):
//
// Each script case below must read its `export:` / `import:` keys from the
// OUTER object literal's values, not from a module-shaped namespace: a
// mis-route would fail to parse, or worse, succeed with a different shape
// (the module path treats top-level `export x = ...` as a real export).
// The "real module still detected" case must reach the ESM pipeline when
// run WITHOUT --module on the plain runner; that means a `--module` invocation
// has nothing to assert against and is omitted here. The unit of behaviour
// the gate owns is "plain script containing import/export-keyed object
// literals runs as a script".
//
// `print` is the engine's print; node would need `console.log` shim. This
// file runs in the plain runner (NOT --module), so a regression here shows
// up as either a SyntaxError (because the script path rejects import/export)
// or a script that produces different output.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual) + ")");
}

// --- The reported false positive: a multi-line object literal at line starts
// with `export:` and `import:` keys. The `export:` key sits after a newline
// inside an object body (depth 1), so it must NOT make the file a module.
//
// The script-vs-module distinction is observable through top-level `this`:
// at the top level of a script, `this` is the global object (truthy); at
// the top level of a module, `this` is undefined. The bug routes this file
// through the module pipeline, so `typeof this` would report `undefined`.
// With the fix the script pipeline runs and `typeof this` is `object`.
// Putting the object literal at the top level (no enclosing function) is
// load-bearing: a `function f(){ var obj = { export: ... } }` would be at
// depth > 0 even under the original detector (no top-level import/export).
var obj = {
  export: 95,
  import: 96,
  default: 97,
};
print("" + obj.export + "," + obj.import + "," + obj.default + ":" + typeof this);
eq(typeof this, "object",
   "multi-line object with export/import/default keys at line starts runs as a script (this is the global object)");

// Same shape on a single line would have worked pre-fix because no newline
// separates the keys from `var obj = {`, but the regression test pins the
// shape the typescript bundle tripped on: keys interleaved with newlines.
function scriptWithKeysAfterNewlines() {
  var obj = {
    a: 1,
    export: 2,
    b: 3,
    import: 4,
  };
  return obj.a + ":" + obj.export + ":" + obj.b + ":" + obj.import;
}
eq(scriptWithKeysAfterNewlines(), "1:2:3:4",
   "object keys interleaved with export/import keys across newlines");

// --- `import` followed by `(` is a dynamic import expression, legal in
// plain scripts, and must not trigger module detection.
function scriptWithDynamicImport() {
  var p = import("./_nonexistent.js").then(function () { return 1; }, function () { return 2; });
  return "before-then";
}
eq(scriptWithDynamicImport(), "before-then",
   "import() at depth 0 in a plain script does not make the file a module");

// Nested: an object literal whose VALUE is a dynamic import() call.
function scriptWithNestedDynamicImport() {
  var obj = {
    loader: import("./_nonexistent.js").then(function () { return 1; }, function () { return 2; }),
    other: 42,
  };
  return obj.other;
}
eq(scriptWithNestedDynamicImport(), 42,
   "import() inside an object literal does not make the file a module");

// --- Inside a function body (depth > 0 after the function's `{`), the word
// `import` after a newline must not be treated as a module-level statement.
function scriptWithImportInFunction() {
  function f() {
    return import("./_nonexistent.js").then(
      function () { return 1; },
      function () { return 2; });
  }
  // The promise itself can stay unresolved for this assertion; we only
  // care that the script parsed and ran far enough to define f and get
  // back here.
  return typeof f;
}
eq(scriptWithImportInFunction(), "function",
   "import() inside a function body does not make the file a module");

// --- Same shape but with `export` as a property access inside a function:
// the bareword `export` is reserved and would SyntaxError, but a property
// access `obj.export` or `obj["export"]` is fine, and the parse must reach
// it without the gate flagging the function body as module-shaped.
function scriptWithExportMemberInFunction() {
  function f() {
    var o = { export: "x" };
    return o["export"];
  }
  return f();
}
eq(scriptWithExportMemberInFunction(), "x",
   "obj['export'] inside a function body does not make the file a module");

// --- Nested braces: the export keyword after a newline inside TWO levels
// of nesting still must not be detected.
function scriptWithDeepExport() {
  var x = {
    outer: {
      export: "deep",
      inner: 1,
    },
  };
  return x.outer.export + ":" + x.outer.inner;
}
eq(scriptWithDeepExport(), "deep:1",
   "export: deep-nested object key, not a module");

// --- Parens and brackets count for nesting depth too, not just braces.
function scriptWithImportInArray() {
  var arr = [
    import("./_nonexistent.js").then(function () { return 1; }, function () { return 2; }),
    "ok",
  ];
  return arr[1];
}
eq(scriptWithImportInArray(), "ok",
   "import() inside an array literal does not make the file a module");

function scriptWithExportInParens() {
  var v = (function () { return { export: 5 }; })();
  return v.export;
}
eq(scriptWithExportInParens(), 5,
   "export as an object key inside parens does not make the file a module");

// --- import.meta is module-only syntax, so its presence anywhere routes the
// file to ESM. But it must be the real token sequence: quoted text and
// x.import.meta property chains are ordinary script content. The conformance
// corpus's importMetaNarrowing.ts (import.meta inside an if-paren, no
// depth-0 import/export anywhere) is the positive case and is covered by
// `just ts-conformance`. Routing for this whole file is asserted by the
// canary at the end: a mis-route to the module pipeline detaches every
// top-level declaration from globalThis, so typeof globalThis.eq would be
// "undefined".
function scriptWithImportMetaInString() {
  var s = "see import.meta docs";
  return s.indexOf("import.meta");
}
eq(scriptWithImportMetaInString(), 4,
   "text 'import.meta' inside a string literal parses as script content");

function scriptWithImportMetaInTemplate() {
  var t = `template mentioning import.meta here`;
  return t.indexOf("import.meta") >= 0;
}
eq(scriptWithImportMetaInTemplate(), true,
   "text 'import.meta' inside a template literal parses as script content");

function scriptWithImportPropertyChain() {
  var a = { import: { meta: "chain" } };
  return a.import.meta;
}
eq(scriptWithImportPropertyChain(), "chain",
   "an x.import.meta property chain parses as script content");

// A multi-line string whose second line begins with the word `export` must
// not trip the depth-0 declaration match either.
function scriptWithExportAtStringLineStart() {
  var s = "line one\nexport function fake() {}";
  return s.charAt(9);
}
eq(scriptWithExportAtStringLineStart(), "e",
   "'export' at a line start inside a string parses as script content");

// Canary: all the quoted-text shapes above must leave this file on the
// script pipeline, where top-level declarations attach to the global.
eq(typeof globalThis.eq, "function",
   "quoted 'import.meta'/'export' text and property chains keep the file a script");
eq(typeof this, "object",
   "top-level this is the global object (the file did not route as a module)");

print('cli_looks_like_module_depth: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }