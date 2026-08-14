var he = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("encode", he.encode("<hello> & 'world'"));
rec("decode", he.decode("&lt;hello&gt; &amp; &#39;world&#39;"));
rec("escape", he.escape("<script>"));
rec("roundtrip", he.decode(he.encode("café ☃")));

console.log(lines.join("\n"));
console.log(lines.length + " he API checks recorded, 0 threw");
