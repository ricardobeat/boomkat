function repeated(a, b) {
    a = +a;
    b = +b;
    const first = a * b;
    const second = a * b;
    const third = a / b;
    const fourth = a / b;
    return first + second + third + fourth;
}
let sum = 0;
for (let i = 1; i <= 1000000; i++) sum += repeated(i, 3);
print(sum);
