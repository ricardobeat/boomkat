function numbers() {
    return [0, -0, 1, -2, 1.5, 0 / 0, 1 / 0];
}
var first = numbers();
first[0] = 99;
print(numbers()[0]);
