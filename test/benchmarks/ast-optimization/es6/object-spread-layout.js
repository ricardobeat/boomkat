const source = {a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8};
function run(n) {
    let sum = 0;
    for (let i = 0; i < n; i++) {
        const object = {...source, i};
        sum += object.a;
    }
    return sum;
}
var result = run(200000);
if (result !== 200000) throw new Error("incorrect result: " + result);
print(result);
