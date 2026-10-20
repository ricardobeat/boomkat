function count(...args) { return args.length; }
function run(n) {
    let sum = 0;
    for (let i = 0; i < n; i++) sum += count(1, 2, 3, 4, 5);
    return sum;
}
var result = run(400000);
if (result !== 2000000) throw new Error("incorrect result: " + result);
print(result);
