// Global slot caches must survive unrelated shape churn and invalidate on descriptor/layout changes.
globalThis.layoutValue = 7;
function readLayout(n) { var sum = 0; for (var i = 0; i < n; i++) sum += layoutValue; return sum; }
function check(actual, expected) { if (actual !== expected) throw new Error(actual + " != " + expected); }
for (var warm = 0; warm < 80; warm++) check(readLayout(100), 700);
for (var churn = 0; churn < 1500; churn++) { var obj = {}; obj["shape" + churn] = churn; }
layoutValue = 11;
check(readLayout(100), 1100);
Object.defineProperty(globalThis, "layoutValue", { get: function () { return 13; }, configurable: true });
check(readLayout(100), 1300);
Object.defineProperty(globalThis, "layoutValue", { value: 17, writable: true, configurable: true });
check(readLayout(100), 1700);
var indirectEval = eval;
indirectEval("layoutValue = 19; var extraLayoutBinding = 3;");
check(readLayout(100), 1900);
print("global layout OK");
