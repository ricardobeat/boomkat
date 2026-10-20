async function lengths(n) {
    let sum = 0;
    for (let i = 0; i < n; i++) {
        const text = `entry ${i} tail`;
        sum += (await text).length;
    }
    return sum;
}
lengths(100000).then(function (sum) { print(sum); });
