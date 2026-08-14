var ts = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

var result = ts.transpileModule("const x: number = 1 + 2;", {
    compilerOptions: { module: ts.ModuleKind.CommonJS }
});
rec("transpiled_no_types", result.outputText.indexOf(": number") === -1);
rec("transpiled_has_const_or_var", /\b(const|var)\s+x\s*=\s*1\s*\+\s*2/.test(result.outputText));

var sf = ts.createSourceFile("t.ts", "let y = 42;", ts.ScriptTarget.Latest);
rec("source_file_kind", sf.kind === ts.SyntaxKind.SourceFile);

console.log(lines.join("\n"));
console.log(lines.length + " typescript API checks recorded, 0 threw");
