// Markdown parser — converts a markdown subset to HTML
// Exercises: RegExp, string methods, arrays, closures, template literals

function parseInline(text) {
    text = text.replace(/&/g, "&amp;");
    text = text.replace(/</g, "&lt;");
    text = text.replace(/>/g, "&gt;");
    text = text.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
    text = text.replace(/\*(.+?)\*/g, "<em>$1</em>");
    text = text.replace(/`(.+?)`/g, "<code>$1</code>");
    text = text.replace(/\[(.+?)\]\((.+?)\)/g, '<a href="$2">$1</a>');
    return text;
}

var lines = "# TinyDuck Markdown\n\nA **lightweight** and *fast* JS engine.\n\n## Features\n\n- Classes and closures\n- Template literals\n- **RegExp** support\n\n## Roadmap\n\n1. Remove dead code\n2. Optimize hot paths\n3. Ship it\n\n## Example\n\n```\nvar x = 1 + 2;\n```\n\nVisit [the repo](https://example.com/tinyduck) for more.\n\n---\n\nThat's all, *folks*!".split("\n");

var result = [];
var inCode = false;
for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line.indexOf("```") === 0) {
        if (inCode) { result.push("</code></pre>"); inCode = false; }
        else { result.push("<pre><code>"); inCode = true; }
        continue;
    }
    if (inCode) { result.push(line); continue; }
    if (line.length === 0) continue;
    if (line.charCodeAt(0) === 35) {
        var hi = 0;
        while (hi < line.length && line.charCodeAt(hi) === 35 && hi < 6) hi++;
        if (hi < line.length && line.charCodeAt(hi) === 32) {
            result.push("<h" + hi + ">" + parseInline(line.slice(hi + 1)) + "</h" + hi + ">");
            continue;
        }
    }
    if (line === "---") { result.push("<hr>"); continue; }
    if (line.length > 2 && line.charCodeAt(0) === 45 && line.charCodeAt(1) === 32) {
        result.push("<li>" + parseInline(line.slice(2)) + "</li>"); continue;
    }
    if (line.length > 3 && line.charCodeAt(1) === 46 && line.charCodeAt(2) === 32) {
        if (line.charCodeAt(0) >= 48 && line.charCodeAt(0) <= 57) {
            result.push("<li>" + parseInline(line.slice(3)) + "</li>"); continue;
        }
    }
    result.push("<p>" + parseInline(line) + "</p>");
}
var html = result.join("\n");
console.log(html);

var ok = true;
if (html.indexOf("<h1>TinyDuck Markdown</h1>") < 0) { ok = false; console.log("MISSING: h1"); }
if (html.indexOf("<strong>lightweight</strong>") < 0) { ok = false; console.log("MISSING: strong"); }
if (html.indexOf("<em>fast</em>") < 0) { ok = false; console.log("MISSING: em"); }
if (html.indexOf("<code>") < 0) { ok = false; console.log("MISSING: code"); }
if (html.indexOf("<ul>") < 0) { ok = false; console.log("MISSING: ul"); }
if (html.indexOf("<ol>") < 0) { ok = false; console.log("MISSING: ol"); }
if (html.indexOf("<pre><code>") < 0) { ok = false; console.log("MISSING: pre"); }
if (html.indexOf("https://example.com/tinyduck") < 0) { ok = false; console.log("MISSING: link"); }
if (html.indexOf("<hr>") < 0) { ok = false; console.log("MISSING: hr"); }
console.log(ok ? "PASS" : "FAIL");
