const map = new Map();
for (let i = 0; i < 1000; i++) map.set(i, i + 1);
function sumEntries(map, rounds) {
    let sum = 0;
    for (let round = 0; round < rounds; round++) {
        for (const [key, value] of map) sum += key + value;
    }
    return sum;
}
if (sumEntries(map, 300) !== 300000000) throw new Error('entry sum');
