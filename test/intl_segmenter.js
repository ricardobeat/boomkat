function equal(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected))
        throw new Error(JSON.stringify(actual) + ' != ' + JSON.stringify(expected));
}
function split(input, granularity) {
    return Array.from(new Intl.Segmenter('en', {granularity}).segment(input), x => x.segment);
}
equal(split('a\u0301👨🏻‍🦰🇦🇺🇧🇷\r\n낶', 'grapheme'), ['á', '👨🏻‍🦰', '🇦🇺', '🇧🇷', '\r\n', '낶']);
equal(split('क्\u200dष', 'grapheme'), ['क्\u200dष']);
equal(split("can't 12,345.67 foo_bar", 'word'), ["can't", ' ', '12,345.67', ' ', 'foo_bar']);
equal(split('Hello!  Next? Done.', 'sentence'), ['Hello!  ', 'Next? ', 'Done.']);
equal(split('U.S. Navy. 3.14 is pi. fine!', 'sentence'), ['U.S. ', 'Navy. ', '3.14 is pi. fine!']);
const segments = new Intl.Segmenter('en', {granularity: 'word'}).segment('á 👨🏻‍🦰 12');
equal(segments.containing(1), {segment: 'á', index: 0, input: 'á 👨🏻‍🦰 12', isWordLike: true});
const a = segments[Symbol.iterator](), b = segments[Symbol.iterator]();
equal(a.next(), b.next());
a.next();
equal(b.next().value.segment, ' ');
if (segments.containing(-1) !== undefined || segments.containing(Infinity) !== undefined)
    throw new Error('out of bounds');
const plain = new Intl.Segmenter().segment('');
equal(Array.from(plain), []);
if (plain.containing(0) !== undefined) throw new Error('empty string');
// Only the iterator keeps its Segments payload and computed input reachable.
const retained = new Intl.Segmenter().segment(['á', '👨🏻‍🦰', 'z'].join(''))[Symbol.iterator]();
if (retained[Symbol.iterator]() !== retained ||
    Object.getPrototypeOf(Object.getPrototypeOf(retained)) !== Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]())))
    throw new Error('shared Iterator prototype');
for (let round = 0; round < 20; round++) {
    let junk = [];
    for (let i = 0; i < 100; i++) junk.push({value: [i, round], text: 'allocation' + i});
}
equal(Array.from(retained, x => x.segment), ['á', '👨🏻‍🦰', 'z']);
const reentrant = new Intl.Segmenter().segment(['á', 'b'].join(''));
equal(reentrant.containing({valueOf() {
    for (let i = 0; i < 500; i++) ({value: [i], text: 'coercion' + i});
    return 1;
}}).segment, 'á');
const thaiWords = new Intl.Segmenter('th', {granularity: 'word'});
if (thaiWords.segment('฿').containing(0).isWordLike || !thaiWords.segment('ก').containing(0).isWordLike)
    throw new Error('Thai word classification');
print('Intl.Segmenter passed');
