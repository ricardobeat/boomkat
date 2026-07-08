let o: { a?: { b?: number } } = { a: { b: 42 } };
let v = o?.a?.b as number;
print(v);
let o2: { a?: { b?: number } } = {};
print(o2?.a?.b === undefined ? "yes" : "no");
