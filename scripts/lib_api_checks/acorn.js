var acorn = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

var ast = acorn.parse("var x = 1 + 2;", { ecmaVersion: 2020 });
rec("parse_type", ast.type);
rec("parse_body_len", ast.body.length);
rec("decl_kind", ast.body[0].kind);

var toks = [];
for (var t of acorn.tokenizer("foo(1, 2)", { ecmaVersion: 2020 })) {
    toks.push(t.type.label || t.value);
}
rec("tokens", toks);

console.log(lines.join("\n"));
console.log(lines.length + " acorn API checks recorded, 0 threw");
