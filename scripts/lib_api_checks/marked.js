var marked = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("bold", marked.parse("**bold**").trim());
rec("heading", marked.parse("# Title").trim());
rec("list", marked.parse("- a\n- b").trim());
rec("link", marked.parse("[x](https://example.com)").trim());
rec("lexer_tokens", marked.lexer("# Title\n\ntext").map(function (t) { return t.type; }));

console.log(lines.join("\n"));
console.log(lines.length + " marked API checks recorded, 0 threw");
