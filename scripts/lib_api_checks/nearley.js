var nearley = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

// A minimal hand-built grammar: S -> "a" "b" "c" (nearley's compiled-grammar
// shape, avoiding a dependency on the nearley compiler CLI).
var rule = new nearley.Rule("S", [{ literal: "a" }, { literal: "b" }, { literal: "c" }], function () { return "matched"; });
var grammar = new nearley.Grammar([rule]);
grammar.start = "S";

var parser = new nearley.Parser(grammar);
parser.feed("abc");
rec("results_count", parser.results.length);
rec("result_value", parser.results[0]);

console.log(lines.join("\n"));
console.log(lines.length + " nearley API checks recorded, 0 threw");
