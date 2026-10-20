function run(n) {
    let sum = 0;
    for (let i = 0; i < n; i++) sum += ({x: i, y: i + 1}).x;
    return sum;
}
print(run(1000000));
