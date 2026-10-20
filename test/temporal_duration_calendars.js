function equal(actual, expected) {
    if (actual !== expected) throw new Error("expected " + expected + ", got " + actual);
}

const year = Temporal.Duration.from({ years: 1 });
const months = Temporal.Duration.from({ months: 13 });
const dates = [
    new Temporal.PlainDate(2023, 9, 16, "hebrew"),
    "2023-09-16[u-ca=hebrew]",
    { calendar: "hebrew", year: 5784, monthCode: "M01", day: 1 },
    "2023-09-16T00:00[UTC][u-ca=hebrew]",
    { calendar: "hebrew", year: 5784, monthCode: "M01", day: 1, timeZone: "UTC" },
];
for (const relativeTo of dates) {
    equal(year.total({ unit: "months", relativeTo }), 13);
    equal(months.total({ unit: "years", relativeTo }), 1);
    equal(Temporal.Duration.compare(year, months, { relativeTo }), 0);
    const rounded = months.round({ largestUnit: "years", relativeTo });
    equal(rounded.years, 1);
    equal(rounded.months, 0);
    equal(rounded.days, 0);
}
let rejected = false;
try {
    new Temporal.Duration().round({
        smallestUnit: "minutes",
        relativeTo: { year: 275760, month: 9, day: 13, hour: 1, timeZone: "UTC" },
    });
} catch (error) {
    rejected = error instanceof RangeError;
}
equal(rejected, true);
print("OK");
