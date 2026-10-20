function render(items) {
    let html = "";
    for (let i = 0; i < items.length; i++) {
        const item = items[i];
        html += `<li data-id="${item.id}">${item.name}</li>`;
    }
    return html;
}
function expected(items) {
    const out = [];
    for (let i = 0; i < items.length; i++) {
        const item = items[i];
        out.push('<li data-id="' + String(item.id) + '">' + String(item.name) + '</li>');
    }
    return out.join("");
}
function check(items) {
    const actual = render(items);
    const want = expected(items);
    if (actual !== want) throw new Error("template mismatch: " + actual.length + " != " + want.length);
}
const rows = [];
for (let i = 0; i < 128; i++) rows.push({id: i - 64, name: "value " + i});
for (let i = 0; i < 40; i++) check(rows);
const integers = [0, 1, -1, 9, 10, 99, 100, 999, 1000, -10, -100, -1000,
                  140737488355327, -140737488355328];
for (let power = 10; power <= 100000000000000; power *= 10) {
    integers.push(power - 1, power, power + 1, -power + 1, -power, -power - 1);
}
for (let i = 0; i < integers.length; i++) {
    rows[i % rows.length].id = integers[i];
    check(rows);
}
for (let length = 0; length < 160; length++) {
    rows[0].name = "x".repeat(length);
    check(rows);
}
for (const name of ["café", "😀", "\uD800", "\uDC00", "\uD800\uDC00", "a\0b", "<&>\"'"]) {
    rows[0].name = name;
    check(rows);
}
// Type, descriptor, shape, and hole changes must return to ordinary execution.
rows[0].id = "different type";
check(rows);
rows[0].id = 123;
check(rows);
let reads = 0;
Object.defineProperty(rows[0], "name", {get() {reads++; return "getter";}, configurable: true});
if (render(rows) !== expected(rows) || reads !== 2) throw new Error("getter count");
Object.defineProperty(rows[0], "name", {value: "restored", writable: true, configurable: true, enumerable: true});
check(rows);
for (let i = 0; i < 40; i++) rows[1]["extra" + i] = i;
check(rows);
rows[0].name = {toString() { rows[1].id = 9876; return "converted"; }};
const converted = render(rows);
if (converted !== expected(rows)) throw new Error("conversion order");
rows[0].name = Symbol("must throw");
let threw = false;
try { render(rows); } catch (error) { threw = error instanceof TypeError; }
if (!threw) throw new Error("symbol conversion");
rows[0].name = "restored";
delete rows[2];
threw = false;
try { render(rows); } catch (error) { threw = error instanceof TypeError; }
if (!threw) throw new Error("hole lookup");
check([]);
const large = [];
for (let i = 0; i < 4097; i++) large.push({id: i, name: "record"});
check(large);
console.log("SLJIT template: PASS");
