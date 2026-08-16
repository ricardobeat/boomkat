import diff from "./microdiff.ts";

const show = (d: any[]) => JSON.stringify(d);
console.log(show(diff({ a: 1, b: 2 }, { a: 1, b: 3 })));
console.log(show(diff([1, 2, 3], [1, 2, 3, 4])));
console.log(show(diff({ x: 1 }, {})));
console.log(show(diff({}, { y: { z: 5 } })));
console.log(show(diff({ d: new Date(0) }, { d: new Date(1000) })));
console.log(show(diff({ r: /a/g }, { r: /b/i })));
const shared: any = { k: 1 };
console.log(show(diff({ s: shared, t: shared }, { s: { k: 2 }, t: { k: 1 } })));
console.log(show(diff({ n: NaN, s: "str", nil: null }, { n: NaN, s: "str", nil: null })));
