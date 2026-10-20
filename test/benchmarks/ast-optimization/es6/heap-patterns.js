// Flat patterns consuming references, without allocating the input each time.
function lexical(pair, n) {
    let sum = 0;
    for (let i = 0; i < n; i++) {
        const [text, object] = pair;
        sum += text.length + object.value;
    }
    return sum;
}
function parameter([text, object]) { return text.length + object.value; }
function calls(pair, n) {
    let sum = 0;
    for (let i = 0; i < n; i++) sum += parameter(pair);
    return sum;
}
const pair = ['abc', {value: 7}];
if (lexical(pair, 300000) !== 3000000 || calls(pair, 300000) !== 3000000)
    throw new Error('heap pattern result');
