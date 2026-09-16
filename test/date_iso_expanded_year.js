// toISOString uses the expanded year form outside 0..9999.
//
// The DateTimeString format (§21.4.1.33) writes a bare four-digit year only
// for years 0 through 9999. Every other year, negative ones included, takes
// the six-digit form with an explicit sign, so year -1 is "-000001" and not
// "-0001". toJSON hands off to toISOString and prints the same text.
//
// toString and toUTCString use ToDateString instead, which is a different
// grammar and keeps the short "-0001" spelling.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) { ok(a === b, m + ' (got ' + a + ', want ' + b + ')'); }

function at(y, mo, d, h, mi, s, ms) {
    var dt = new Date(0);
    dt.setUTCFullYear(y, mo, d);
    dt.setUTCHours(h || 0, mi || 0, s || 0, ms || 0);
    return dt;
}

eq(at(-1, 11, 31, 23, 59, 59, 999).toISOString(), '-000001-12-31T23:59:59.999Z',
   'year -1 is six digits');
eq(at(-9999, 0, 1).toISOString(), '-009999-01-01T00:00:00.000Z',
   'year -9999 is six digits');
eq(at(-10000, 11, 31).toISOString(), '-010000-12-31T00:00:00.000Z',
   'year -10000 is six digits');
eq(at(-100000, 0, 1, 1, 2, 3, 4).toISOString(), '-100000-01-01T01:02:03.004Z',
   'a six-digit negative year fills every digit');

// The four-digit form covers exactly 0..9999.
eq(at(0, 0, 1).toISOString(), '0000-01-01T00:00:00.000Z', 'year 0 is four digits');
eq(at(1, 0, 1, 0, 0, 0, 1).toISOString(), '0001-01-01T00:00:00.001Z',
   'year 1 is four digits');
eq(at(9999, 11, 31, 23, 59, 59, 999).toISOString(), '9999-12-31T23:59:59.999Z',
   'year 9999 is four digits');
eq(at(10000, 0, 1).toISOString(), '+010000-01-01T00:00:00.000Z',
   'year 10000 crosses into six digits');

// The representable extremes.
eq(at(275760, 8, 13).toISOString(), '+275760-09-13T00:00:00.000Z', 'the maximum date');
eq(at(-271821, 3, 20).toISOString(), '-271821-04-20T00:00:00.000Z', 'the minimum date');

// Every form is exactly as long as its grammar says, and parses back to the
// same instant.
[-271821, -100000, -10000, -9999, -1, 0, 1, 9999, 10000, 275760].forEach(function (y) {
    var d = y === 275760 ? at(y, 8, 13) : (y === -271821 ? at(y, 3, 20) : at(y, 0, 1));
    var s = d.toISOString();
    eq(s.length, (y >= 0 && y <= 9999) ? 24 : 27, 'length for year ' + y);
    eq(Date.parse(s), d.getTime(), 'year ' + y + ' round-trips through Date.parse');
});

// toJSON prints the same text.
var neg = at(-1, 11, 31);
eq(neg.toJSON(), neg.toISOString(), 'toJSON matches toISOString');
eq(JSON.stringify({ d: neg }), '{"d":"' + neg.toISOString() + '"}',
   'JSON.stringify uses it too');

// toString keeps the ToDateString spelling, which is a different grammar.
ok(at(-1, 11, 31).toUTCString().indexOf('-0001') !== -1,
   'toUTCString keeps the four-digit negative year');

// An invalid date still throws rather than formatting anything.
var threw = false;
try { new Date(NaN).toISOString(); } catch (e) { threw = e instanceof RangeError; }
ok(threw, 'an invalid date throws a RangeError');

if (fail === 0) {
    print('PASS: toISOString expanded year (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
