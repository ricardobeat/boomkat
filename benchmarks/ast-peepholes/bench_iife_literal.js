function run(n) {
    let s = 0;
    for (let i = 0; i < n; i++) s += ((p) => p.x + p.y)({x: i, y: 1});
    return s;
}
print(run(1000000));
