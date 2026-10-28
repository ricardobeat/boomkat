function check(value, message) { if (!value) throw new Error(message); }
var ascii = 'plain';
var latin = 'café';
var wide = 'x€y';
var astral = '😀';
var lone = '\ud800';
var keyed = { 'é': 1, '€': 2, plain: 3 };
check(ascii.length === 5, 'ascii length');
check(latin.length === 4 && latin.charCodeAt(3) === 0xE9, 'latin-1 constant');
check(wide.length === 3 && wide.charCodeAt(1) === 0x20AC, 'wide constant');
check(astral.length === 2 && astral.codePointAt(0) === 0x1F600, 'surrogate pair constant');
check(lone.length === 1 && lone.charCodeAt(0) === 0xD800, 'lone surrogate constant');
check(keyed['é'] === 1 && keyed['€'] === 2 && keyed.plain === 3, 'literal shape keys');
check(Object.keys(keyed).join() === 'é,€,plain', 'key order');
check(('caf' + 'é') === latin, 'canonical width after concat');
check(wide.slice(0, 1) + wide.slice(2) === 'xy', 'narrow slice of a wide constant');
print('string widths passed');
