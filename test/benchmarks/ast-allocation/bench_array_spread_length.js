const source = [];
for (let i = 0; i < 16; i++) source.push(i);
function run(n) {
    let sum = 0;
    for (let i = 0; i < n; i++) { const copy = [...source, i]; sum += copy.length; }
    return sum;
}
print(run(500000));
