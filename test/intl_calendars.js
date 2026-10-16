function eq(actual, expected) {
    if (actual !== expected) throw new Error('Expected ' + expected + ', got ' + actual);
}
function throws(Type, fn) {
    try { fn(); } catch (error) { if (error instanceof Type) return; throw error; }
    throw new Error('Expected ' + Type.name);
}
function part(formatter, date, type) {
    var found = formatter.formatToParts(date).find(function (p) { return p.type === type; });
    return found === undefined ? undefined : found.value;
}
var utc = { timeZone: 'UTC' };
var numeric = { year: 'numeric', month: 'numeric', day: 'numeric', timeZone: 'UTC' };

// Chinese and Dangi: 2000-01-01 is the 25th of the 11th month of related year 1999.
var chinese = new Intl.DateTimeFormat('en-u-ca-chinese', numeric);
eq(chinese.format(Date.UTC(2000, 0, 1)), '11/25/1999(ji-mao)');
eq(part(chinese, Date.UTC(2000, 0, 1), 'relatedYear'), '1999');
eq(new Intl.DateTimeFormat('en-u-ca-dangi', numeric).format(Date.UTC(2000, 0, 1)), '11/25/1999(ji-mao)');
// May 2020 has a leap fourth month; the leap month prints as "4bis".
eq(chinese.format(Date.UTC(2020, 4, 23)), '4bis/1/2020(geng-zi)');

// Hebrew: 1 Tishri 5784 is 16 September 2023; 15 March 2024 is in Adar II of leap year 5784.
var hebrew = new Intl.DateTimeFormat('en-u-ca-hebrew', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });
eq(hebrew.format(Date.UTC(2023, 8, 16)), 'Tishri 1, 5784');
eq(hebrew.format(Date.UTC(2023, 8, 15)), 'Elul 29, 5783');
eq(hebrew.format(Date.UTC(2024, 2, 15)), 'Adar II 5, 5784');
eq(hebrew.format(Date.UTC(2023, 2, 15)), 'Adar 22, 5783');

// Islamic civil: 16 July 622 is 1 Muharram 1 AH, and 1 January 2000 is 24 Ramadan 1420.
var islamic = new Intl.DateTimeFormat('en', { calendar: 'islamicc', year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });
eq(islamic.format(Date.UTC(622, 6, 19)), 'Muharram 1, 1');
eq(islamic.format(Date.UTC(2000, 0, 1)), 'Ramadan 24, 1420');

// The calendar option is ASCII case-insensitive; the extension keeps a multi-subtag type whole.
eq(new Intl.DateTimeFormat('en', { calendar: 'ISO8601' }).resolvedOptions().calendar, 'iso8601');
eq(new Intl.DateTimeFormat('en-u-ca-islamicc').resolvedOptions().calendar, 'islamic-civil');
eq(new Intl.DateTimeFormat('en-u-ca-chinese').resolvedOptions().calendar, 'chinese');
eq(new Intl.DateTimeFormat('en-u-ca-buddhist').resolvedOptions().calendar, 'gregory');
throws(RangeError, function () { new Intl.DateTimeFormat('en', { calendar: 'İSO8601' }); });

eq(Intl.supportedValuesOf('calendar').join(','), 'chinese,dangi,gregory,hebrew,islamic-civil,iso8601');
