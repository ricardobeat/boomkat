var Handlebars = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

var tpl1 = Handlebars.compile("Hello {{name}}!");
rec("basic", tpl1({ name: "World" }));

var tpl2 = Handlebars.compile("{{#each items}}{{this}},{{/each}}");
rec("each", tpl2({ items: [1, 2, 3] }));

var tpl3 = Handlebars.compile("{{#if flag}}yes{{else}}no{{/if}}");
rec("if_true", tpl3({ flag: true }));
rec("if_false", tpl3({ flag: false }));

Handlebars.registerHelper("shout", function (s) { return s.toUpperCase() + "!"; });
var tpl4 = Handlebars.compile("{{shout word}}");
rec("helper", tpl4({ word: "hi" }));

console.log(lines.join("\n"));
console.log(lines.length + " handlebars API checks recorded, 0 threw");
