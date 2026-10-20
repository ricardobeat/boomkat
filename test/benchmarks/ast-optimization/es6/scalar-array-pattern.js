function sum(n) {
    let result = 0;
    for (let i = 0; i < n; i++) {
        const [a, b, c] = [i, i + 1, i + 2];
        result += a + b + c;
    }
    return result;
}
if (sum(300000) !== 135000450000) throw new Error('array pattern result');
