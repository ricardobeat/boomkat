// Babel's browser global exposes its API surface entirely through lazy
// getters (get transform(){return vL}, etc.) rather than plain data
// properties, so this driver does not use the `module`/`exports` shim -- it
// reads off the `Babel` global the bundle's own UMD wrapper installs.
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("version_type", typeof Babel.version);
rec("transform_type", typeof Babel.transform);
var out = Babel.transform("const x = 1 + 2;", { presets: [] });
rec("transform_code_has_var_or_const", /\b(const|var)\s+x\s*=\s*1\s*\+\s*2/.test(out.code));

console.log(lines.join("\n"));
console.log(lines.length + " babel API checks recorded, 0 threw");
