function run(n) {
    let s = 0;
    for (let i = 0; i < n; i++) s += ({x: i, y: i + 1}).x;
    return s;
}
print(run(1000000));
