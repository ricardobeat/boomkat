function eq(actual, expected) {
    if (actual !== expected) throw new Error('Expected ' + expected + ', got ' + actual);
}
function throws(Type, fn) {
    try { fn(); } catch (error) { if (error instanceof Type) return; throw error; }
    throw new Error('Expected ' + Type.name);
}
var date = Date.UTC(2024, 0, 15, 13, 5, 9, 123);
var simple = new Intl.DateTimeFormat('en-US', {timeZone:'UTC'});
eq(simple.format(date), '1/15/2024');
eq(simple.format, simple.format);
eq(simple.format.call(null, date), '1/15/2024');
eq(Object.prototype.toString.call(simple), '[object Intl.DateTimeFormat]');
eq(simple.resolvedOptions().calendar, 'gregory');
eq(simple.resolvedOptions().numberingSystem, 'latn');
eq(simple.resolvedOptions().timeZone, 'UTC');
var full = new Intl.DateTimeFormat('en-US', {timeZone:'UTC', dateStyle:'full', timeStyle:'long'});
eq(full.format(date), 'Monday, January 15, 2024 at 1:05:09\u202fPM UTC');
eq(full.formatToParts(date).map(function(p){return p.value;}).join(''), full.format(date));
var fractions = new Intl.DateTimeFormat('en', {timeZone:'UTC', hourCycle:'h23', hour:'numeric', minute:'numeric', second:'numeric', fractionalSecondDigits:3});
eq(fractions.format(date), '13:05:09.123');
eq(fractions.formatToParts(date).find(function(p){return p.type==='fractionalSecond';}).value, '123');
eq(new Intl.DateTimeFormat('en', {timeZone:'UTC',hourCycle:'h11',hour:'numeric'}).format(0), '0\u202fAM');
eq(new Intl.DateTimeFormat('en', {timeZone:'UTC',hourCycle:'h24',hour:'numeric'}).format(0), '24');
eq(new Intl.DateTimeFormat('en', {timeZone:'+0530',hourCycle:'h23',hour:'numeric',minute:'numeric'}).format(0), '05:30');
eq(new Intl.DateTimeFormat('en', {timeZone:'Etc/GMT-3',hourCycle:'h23',hour:'numeric',minute:'numeric'}).format(0), '03:00');
eq(new Intl.DateTimeFormat('en', {timeZone:'us/eastern'}).resolvedOptions().timeZone, 'America/New_York');
eq(new Intl.DateTimeFormat('en', {timeZone:'America/Kentucky/Louisville'}).resolvedOptions().timeZone, 'America/Kentucky/Louisville');
eq(new Temporal.ZonedDateTime(0n,'Etc/GMT-3').hour, 3);
eq(new Temporal.ZonedDateTime(0n,'America/Kentucky/Louisville').hour, 19);
var eastern = new Intl.DateTimeFormat('en', {timeZone:'America/New_York',hour:'numeric',minute:'numeric',timeZoneName:'long'});
eq(eastern.format(Date.UTC(2024,0,15,12)), '7:00\u202fAM Eastern Standard Time');
eq(eastern.format(Date.UTC(2024,6,15,12)), '8:00\u202fAM Eastern Daylight Time');
eq(eastern.format(Date.UTC(2024,2,10,6,59)), '1:59\u202fAM Eastern Standard Time');
eq(eastern.format(Date.UTC(2024,2,10,7)), '3:00\u202fAM Eastern Daylight Time');
var range = new Intl.DateTimeFormat('en', {timeZone:'UTC',year:'numeric',month:'short',day:'numeric'});
eq(range.formatRange(Date.UTC(2024,0,3),Date.UTC(2024,0,5)), 'Jan 3\u2009\u2013\u20095, 2024');
eq(range.formatRangeToParts(Date.UTC(2024,0,3),Date.UTC(2024,0,5)).map(function(p){return p.source;}).join(','), 'shared,shared,startRange,shared,endRange,shared,shared');
eq(range.formatRange(date,date), range.format(date));
var legacy = new Date(date);
eq(legacy.toLocaleDateString('en', {timeZone:'UTC'}), simple.format(date));
eq(legacy.toLocaleTimeString('en', {timeZone:'UTC'}), '1:05:09\u202fPM');
eq(legacy.toLocaleString('en', {timeZone:'UTC'}), '1/15/2024, 1:05:09\u202fPM');
eq(new Date(NaN).toLocaleString('en', {get timeZone(){throw new Error('read');}}), 'Invalid Date');
throws(RangeError,function(){simple.format(NaN);});
throws(RangeError,function(){simple.format(8640000000000001);});
throws(RangeError,function(){new Intl.DateTimeFormat('en',{timeZone:'Nowhere/City'});});
throws(TypeError,function(){new Intl.DateTimeFormat('en',{dateStyle:'short',year:'numeric'});});
throws(TypeError,function(){simple.formatRange();});
throws(TypeError,function(){Intl.DateTimeFormat.prototype.formatToParts.call({});});
throws(TypeError,function(){new simple.format();});
var temporal = new Intl.DateTimeFormat('en', {timeZone:'Pacific/Apia'});
eq(temporal.format(new Temporal.PlainDate(2021,8,4)), '8/4/2021');
eq(temporal.format(new Temporal.PlainDateTime(2021,8,4,0,30,45)), '8/4/2021, 12:30:45\u202fAM');
eq(temporal.format(new Temporal.PlainTime(23,30,45)), '11:30:45\u202fPM');
eq(temporal.format(new Temporal.PlainYearMonth(2021,8,'gregory')), '8/2021');
eq(temporal.format(new Temporal.PlainMonthDay(8,4,'gregory')), '8/4');
throws(TypeError,function(){temporal.format(new Temporal.ZonedDateTime(0n,'UTC'));});
throws(TypeError,function(){temporal.formatRange(0,new Temporal.Instant(0n));});
for (var cycle of ['h11','h12','h23','h24']) {
    var explicit = new Intl.DateTimeFormat('en', {hour:'numeric', hourCycle:cycle});
    var extension = new Intl.DateTimeFormat('en-u-hc-' + cycle, {hour:'numeric'});
    eq(explicit.resolvedOptions().hourCycle, cycle);
    eq(extension.resolvedOptions().hourCycle, cycle);
}
eq(new Intl.DateTimeFormat('en',{timeZone:'UTC',timeZoneName:'longOffset'}).formatToParts(0).find(function(p){return p.type==='timeZoneName';}).value,'GMT');
var retained = new Intl.DateTimeFormat('en', {timeZone:'UTC'}).format;
for (var i = 0; i < 256; i++) {
    var transient = new Intl.DateTimeFormat('en', {timeZone:'UTC',timeStyle:'short'});
    eq(transient.formatToParts(date).map(function(p){return p.value;}).join(''), transient.format(date));
}
eq(retained(date), '1/15/2024');
console.log('English DateTimeFormat tests passed');
