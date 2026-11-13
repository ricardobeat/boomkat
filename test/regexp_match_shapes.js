// Match arrays of different capture counts and unmatched groups, built in
// alternation so their cached shapes share slots (regexp_build_match_result):
// each must carry its own index keys, index, input, groups and length.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

function describe(m) {
    var parts = [m.length, m.index, m.input.length, m.groups === undefined ? "u" : JSON.stringify(m.groups)];
    for (var i = 0; i < m.length; i++) parts.push((i in m) + ":" + m[i]);
    return parts.join(",");
}

var patterns = [
    [/(a)(b)?(c)?(d)?(e)?(f)?(g)?(h)?(i)?(j)?(k)?/, "a", "12,0,1,u,true:a,true:a,true:undefined,true:undefined,true:undefined,true:undefined,true:undefined,true:undefined,true:undefined,true:undefined,true:undefined,true:undefined"],
    [/(a)(b)(c)(d)(e)?(f)?(g)?(h)?(i)?(j)?(k)?/, "abcd", "12,0,4,u,true:abcd,true:a,true:b,true:c,true:d,true:undefined,true:undefined,true:undefined,true:undefined,true:undefined,true:undefined,true:undefined"],
    [/x(\d+)/, "ax42", "2,1,4,u,true:x42,true:42"],
    [/(?<w>\w)(?<n>\d)?/, "q", "3,0,1,{\"w\":\"q\"},true:q,true:q,true:undefined"],
    [/(y)|(z)/, "z", "3,0,1,u,true:z,true:undefined,true:z"],
];
for (var round = 0; round < 400; round++) {
    for (var p = 0; p < patterns.length; p++) {
        var m = patterns[p][0].exec(patterns[p][1]);
        check("pattern " + p + " round " + round, describe(m), patterns[p][2]);
    }
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
