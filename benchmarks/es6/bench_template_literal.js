// Template literals. Each one is a concat of its cooked strings and the
// ToString of each substitution, so this measures that lowering against the
// equivalent `+` chain rather than string building in general.
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
