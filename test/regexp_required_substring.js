// Required interior literals may reject impossible matches, but may not move
// the match start or make optional/alternative text mandatory.
function check(pattern, flags, input, last, expected, index, next) {
    var re = new RegExp(pattern, flags);
    re.lastIndex = last;
    var result = re.exec(input);
    if ((result ? result[0] : null) !== expected ||
        (result && result.index !== index) || re.lastIndex !== next)
        throw Error(pattern + '/' + flags + ' on ' + input + ': ' + result + ' at ' + (result && result.index) + ', lastIndex=' + re.lastIndex);
}
check('(a|b)longliteral', '', 'xxblongliteralyy', 0, 'blongliteral', 2, 0);
check('(a|b)longliteral', '', 'xxblonglateralyy', 0, null, 0, 0);
check('(a|b)longliteral', 'g', 'a_longliteral blongliteral', 0, 'blongliteral', 14, 26);
check('(a|b)longliteral', 'y', 'a_longliteral blongliteral', 14, 'blongliteral', 14, 26);
check('(a|b)longliteral', 'y', 'a_longliteral blongliteral', 0, null, 0, 0);
check('(a|b)longliteral', 'i', 'BLONGLITERAL', 0, 'BLONGLITERAL', 0, 0);
check('(a|b)longliteral|fallback', '', 'fallback', 0, 'fallback', 0, 0);
check('(a|b)longliteral?', '', 'alonglitera', 0, 'alonglitera', 0, 0);
check('(a|b)longliteral*', '', 'alonglitera', 0, 'alonglitera', 0, 0);
check('(a|b)longliteral{0,2}', '', 'alonglitera', 0, 'alonglitera', 0, 0);
check('(?<=a)longliteral', '', 'alongliteral', 0, 'longliteral', 1, 0);
check('(a|b)\\.long\\/literal', '', 'b.long/literal', 0, 'b.long/literal', 0, 0);
check('(a|b)\\x6congliteral', '', 'alongliteral', 0, 'alongliteral', 0, 0);
check('(a|b)\\wlongliteral', '', 'aXlongliteral', 0, 'aXlongliteral', 0, 0);
check('(a|b)longliteral', 'u', '\ud83d\ude00blongliteral', 0, 'blongliteral', 2, 0);
check('(a|b)longliteral', 'gu', '\ud83d\ude00blongliteral', 2, 'blongliteral', 2, 14);
check('[a|b]longliteral', '', '|longliteral', 0, '|longliteral', 0, 0);
check('(a|b)abcdefghijklmnopq?', '', 'aabcdefghijklmnop', 0, 'aabcdefghijklmnop', 0, 0);
print('regexp required substring ok');
