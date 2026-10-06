function strings(n) {
    var last;
    var total = 0;
    for (var i = 0; i < n; i++) {
        const text = `entry ${i} tail`;
        total += text.length;
        last = text;
    }
    return last + ':' + total;
}
print(strings(400000));
