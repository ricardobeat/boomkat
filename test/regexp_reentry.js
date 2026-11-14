// A regexp run that reenters the matcher before it is done: a replacer function that runs other
// regexps, a lastIndex whose valueOf runs one, and a subject whose toString does. Each answer is
// checked against the one the same call gives with no reentry; the loops warm both JIT tiers.
var failures = 0;
function check(name, got, want) {
    if (got !== want) {
        failures++;
        print("FAIL " + name + ": " + got + " !== " + want);
    }
}

function inner(s) {
    var m = /(\w)(\w)?/.exec(s);
    return m ? m[1] + (m[2] || "-") + /\d+/g.test(s) + s.replace(/[aeiou]/g, "*") + s.split(/,/).length : "none";
}

function replacer(n) {
    return "a1b22c333".replace(/([a-z])(\d+)/g, function (all, letter, digits, at) {
        return "[" + inner(letter + digits) + letter.toUpperCase() + digits.length + at + "]";
    });
}

function viaLastIndex(n) {
    var re = /b(\d)/g;
    var seen = "";
    re.lastIndex = { valueOf: function () { seen = inner("x9,y") + /(\d)/.exec("q" + n % 3)[1]; return 2; } };
    var m = re.exec("ab1cb2b3");
    return m[0] + m[1] + m.index + re.lastIndex + seen;
}

function viaToString(n) {
    var subject = { toString: function () { return "z" + inner("k,e,y") + "b4"; } };
    var m = /b(\d)/.exec(subject);
    var t = /(\w)b/.test(subject);
    var r = "b5b6".replace(/b(\d)/g, function (all, d) { return String(/(\w)b(\d)/.exec(subject)[2]) + d; });
    return m[1] + m.index + t + r + "xby".search({ [Symbol.search]: undefined, toString: function () { return inner("q") + "b"; } });
}

function viaMatchAll(n) {
    var out = "";
    for (var m of "a1b2".matchAll(/([a-z])(\d)/g)) out += m[1] + inner(m[2] + "x,y") + m.index;
    return out;
}

var cases = [replacer, viaLastIndex, viaToString, viaMatchAll];
for (var c = 0; c < cases.length; c++) {
    var first = cases[c](0);
    for (var i = 1; i < 3000; i++) check(cases[c].name, cases[c](i % 3 === 0 ? 0 : 3), first);
    print(cases[c].name + " " + first);
}
print(failures === 0 ? "ok" : "failures " + failures);
