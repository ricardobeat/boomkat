function lengths(n) {
    var total = 0;
    for (var i = 0; i < n; i++) {
        const text = `entry ${i} tail`;
        total += text.length;
    }
    return total;
}
print(lengths(400000));
