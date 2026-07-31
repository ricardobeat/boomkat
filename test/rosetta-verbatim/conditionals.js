// Verbatim from https://rosettacode.org/wiki/Conditional_structures (JavaScript block 3)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function takeWhile(lst, fnTest) {
    'use strict';
    var varHead = lst.length ? lst[0] : null;

    return varHead ? (
        fnTest(varHead) ? [varHead].concat(
            takeWhile(lst.slice(1), fnTest)
        ) : []
    ) : [];
}
