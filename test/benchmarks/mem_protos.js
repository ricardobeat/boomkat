// Prototype chains only
var proto = { base: 42, getBase: function() { return this.base; } };
var chain = [];
for (var i = 0; i < 2000; i++) {
    chain.push({ __proto__: proto, own: i });
}
var total = 0;
for (var i = 0; i < chain.length; i++) { total += chain[i].base; }
if (total < 0) print("never");
