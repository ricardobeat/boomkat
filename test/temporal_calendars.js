for (const c of ["chinese","dangi","hebrew","islamic-civil"]) {
  const d = new Temporal.PlainDate(2000,1,1,c);
  console.log(c, d.calendarId, d.year, d.month, d.monthCode, d.day, d.era, d.eraYear, d.daysInMonth, d.daysInYear, d.monthsInYear, d.inLeapYear, d.dayOfYear, d.toString());
}
console.log(new Temporal.PlainDate(2023,9,16,"hebrew").year, new Temporal.PlainDate(2020,5,23,"chinese").monthCode, new Temporal.PlainDate(1,1,1,"dangi").year);
console.log(new Temporal.PlainDate(2000,1,1).withCalendar("hebrew").calendarId, new Temporal.PlainDate(2000,1,1).toString());
function expect(a, b) { if (a !== b) throw new Error("expected " + b + " got " + a); }
const h = new Temporal.PlainDate(2023, 9, 16, "hebrew");
expect(h.year, 5784); expect(h.monthCode, "M01"); expect(h.day, 1);
expect(new Temporal.PlainDate(2020, 5, 23, "chinese").monthCode, "M04L");
expect(new Temporal.PlainDate(622, 7, 19, "islamic-civil").year, 1);
let threw = false;
try { h.add({ days: 1 }); } catch (e) { threw = e instanceof RangeError; }
expect(threw, true);
