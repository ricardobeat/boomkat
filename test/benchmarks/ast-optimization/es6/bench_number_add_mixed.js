function mixedAdd(n) {
    let result = 0;
    for (let i = 0; i < n; i++) {
        const value = i & 1 ? 1 : 0.25;
        result = value + value;
    }
    return result;
}
const result = mixedAdd(5000000);
if (result !== 2) throw new Error('wrong result');
print(result);
