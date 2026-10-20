// Ineligible source for map entry fusion: each value is already an array.
const pairs = [];
for (let i = 0; i < 1000; i++) pairs.push([i, i + 1]);
function sumEntries(pairs, rounds) {
    let sum = 0;
    for (let round = 0; round < rounds; round++) {
        for (const [key, value] of pairs) sum += key + value;
    }
    return sum;
}
if (sumEntries(pairs, 300) !== 300000000) throw new Error('entry sum');
