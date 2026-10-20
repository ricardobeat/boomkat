function run(n) {
    let sum = 0;
    for (let i = 0; i < n; i++) {
        const {x, y} = {x: i, y: i + 1};
        sum += x + y;
    }
    return sum;
}
var result = run(500000);
if (result !== 250000000000) throw new Error("incorrect result: " + result);
print(result);
