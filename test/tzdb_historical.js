function eq(actual, expected) {
    if (actual !== expected) throw new Error('Expected ' + expected + ', got ' + actual);
}
var earlyNewYork = Temporal.Instant.from('1800-01-01T00:00Z').toZonedDateTimeISO('America/New_York');
eq(earlyNewYork.offset, '-04:56:02');
eq(earlyNewYork.getTimeZoneTransition('next').epochNanoseconds, -2717650800000000000n);
var earlyLondon = Temporal.Instant.from('1848-01-01T00:00Z').toZonedDateTimeISO('Europe/London');
eq(earlyLondon.getTimeZoneTransition('previous').epochNanoseconds, -3852662325000000000n);
var london = new Temporal.ZonedDateTime(0n, 'Europe/London');
eq(london.offset, '+01:00');
eq(london.getTimeZoneTransition('previous').epochNanoseconds, -59004000000000000n);
var singapore = Temporal.ZonedDateTime.from('1933-01-01T12:00[Asia/Singapore]');
if (Math.abs(singapore.hoursInDay - 23 - 2 / 3) > Number.EPSILON * 16) throw new Error('Singapore 20-minute gap');
var niue = Temporal.ZonedDateTime.from('1952-01-01T00:00[Pacific/Niue]');
eq(niue.offset, '-11:19:40');
