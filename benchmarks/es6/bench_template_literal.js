// Template literals, measured against the equivalent `+` chain.
//
// Read the two together. The `+` arm is not a control that should be ignored:
// when this file first ran it was SLOWER than the template arm (6927ms against
// 3759ms), which said immediately that the cost was in building strings rather
// than in the template lowering. It turned out to be the string table being
// swept in full on every GC cycle -- 41M slot visits for 400k allocations --
// and the fix moved both arms together.
//
// So a large number here is not evidence about template syntax until the `+`
// arm is compared against it.
var N = 400000;

function templates(n) {
    let len = 0;
    for (let i = 0; i < n; i++) {
        const s = `item ${i} of ${n}`;
        len += s.length;
    }
    return len;
}

// The `+` equivalent, as the floor.
function concat(n) {
    let len = 0;
    for (let i = 0; i < n; i++) {
        const s = "item " + i + " of " + n;
        len += s.length;
    }
    return len;
}

// Nested substitutions and a multi-line template.
function nested(n) {
    let len = 0;
    for (let i = 0; i < n; i++) {
        const s = `outer ${`inner ${i}`} end`;
        len += s.length;
    }
    return len;
}

var r = 0;
r += templates(N);
r += concat(N);
r += nested(N / 2);
if (r === 0) throw new Error("optimized away");
