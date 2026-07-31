// Set consolidation
// Group sets that share any element.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function consolidate(sets) {
    var groups = [];
    for (var i = 0; i < sets.length; i++) {
        var s = sets[i];
        var merged = false;
        for (var g = 0; g < groups.length; g++) {
            for (var k = 0; k < s.length; k++) {
                if (groups[g].indexOf(s[k]) !== -1) {
                    for (var j = 0; j < s.length; j++) {
                        if (groups[g].indexOf(s[j]) === -1) groups[g].push(s[j]);
                    }
                    merged = true;
                    break;
                }
            }
            if (merged) break;
        }
        if (!merged) groups.push(s.slice());
    }
    // Second pass: merge groups that now share elements
    var changed = true;
    while (changed) {
        changed = false;
        for (var i = 0; i < groups.length; i++) {
            for (var j = i + 1; j < groups.length; j++) {
                for (var k = 0; k < groups[i].length; k++) {
                    if (groups[j].indexOf(groups[i][k]) !== -1) {
                        for (var m2 = 0; m2 < groups[j].length; m2++) {
                            if (groups[i].indexOf(groups[j][m2]) === -1) groups[i].push(groups[j][m2]);
                        }
                        groups.splice(j, 1);
                        changed = true;
                        break;
                    }
                }
                if (changed) break;
            }
            if (changed) break;
        }
    }
    return groups;
}

// Basic
var g1 = consolidate([["A"], ["B"], ["C"]]);
assert(g1.length === 3, "three disjoint sets stay separate");

var g2 = consolidate([["A", "B"], ["C", "D"], ["E"]]);
assert(g2.length === 3, "two pairs + singleton -> 3 groups");

// A merges with C, B merges with E
var g3 = consolidate([["A", "B"], ["C"], ["A", "D"]]);
// {A,B} stays as-is, {C} stays as-is, {A,D} merges into {A,B}
// So we end up with {A,B,D} and {C}
assert(g3.length === 2, "three sets, two share A -> 2 groups");
var big = g3[0].length === 3 ? g3[0] : g3[1];
assert(big.indexOf("A") !== -1 && big.indexOf("B") !== -1, "A,B in big group");
assert(big.indexOf("D") !== -1, "D in big group");
var small = g3[0].length === 1 ? g3[0] : g3[1];
assert(small[0] === "C", "C in singleton group");

// Chain: {A,B},{C,D},{E,F} -> one group (because of overlapping elements)
var g4 = consolidate([["A", "B"], ["C", "D"], ["E", "F"], ["B", "C"], ["D", "E"]]);
assert(g4.length === 1, "chain -> 1 group");

print("engine/set_consolidation: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");