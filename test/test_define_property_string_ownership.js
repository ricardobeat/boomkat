// Existing data slots own replacement strings independently of descriptors.
function check(actual, expected) {
    if (actual !== expected) throw new Error("expected " + expected + ", got " + actual);
}
function replace(target, index) {
    const replacement = "replacement-" + index;
    Object.defineProperty(target, "value", { value: replacement, configurable: true });
}
const kept = { value: "original" };
replace(kept, 123);
let sink;
for (let i = 0; i < 40000; i++) sink = { value: "churn" + i };
check(kept.value, "replacement-123");
Object.defineProperty(kept, "value", { value: kept.value });
check(kept.value, "replacement-123");
function mapped(value) {
    Object.defineProperty(arguments, "0", { value: "mapped", writable: true });
    check(value, "mapped");
    Object.defineProperty(arguments, "0", { value: "unmapped", writable: false });
    check(arguments[0], "unmapped");
    check(value, "unmapped");
    return arguments;
}
const saved = mapped("original");
for (let i = 0; i < 40000; i++) sink = { value: "churn" + i };
check(saved[0], "unmapped");
print("defineProperty string ownership: passed");
