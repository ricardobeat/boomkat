function parameters([a], tag, [b, c, d]) {
    return a + tag + b + c + d;
}
function lexical(values) {
    const [a, b, c] = values;
    return a + b + c;
}
var one = [1], three = [3, 4, 5], result = 0;
for (var i = 0; i < 200000; i++) {
    result += parameters(one, 2, three) + lexical(three);
}
if (result !== 5400000) throw new Error("incorrect result: " + result);
print(result);
