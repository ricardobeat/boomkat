function eq(a, b, m) { if (a !== b) throw new Error(m + ": " + JSON.stringify(a) + " !== " + JSON.stringify(b)); }
function throws(E, f, m) { try { f(); } catch (e) { eq(e instanceof E, true, m); return; } throw new Error("no throw: " + m); }

var d = { years: 1, months: 2, weeks: 3, days: 3, hours: 4, minutes: 5, seconds: 6, milliseconds: 7, microseconds: 8, nanoseconds: 9 };
eq(new Intl.DurationFormat("en", { style: "long" }).format(d),
   "1 year, 2 months, 3 weeks, 3 days, 4 hours, 5 minutes, 6 seconds, 7 milliseconds, 8 microseconds, 9 nanoseconds", "long");
eq(new Intl.DurationFormat("en", { style: "narrow" }).format(d), "1y 2m 3w 3d 4h 5m 6s 7ms 8μs 9ns", "narrow");
eq(new Intl.DurationFormat("en").format(d), "1 yr, 2 mths, 3 wks, 3 days, 4 hr, 5 min, 6 sec, 7 ms, 8 μs, 9 ns", "short");
eq(new Intl.DurationFormat("en", { style: "digital" }).format({ hours: 1, minutes: 2, seconds: 3 }), "1:02:03", "digital");
eq(new Intl.DurationFormat("en", { style: "digital", hoursDisplay: "auto" }).format({ days: 1, minutes: 1, seconds: 2 }), "1 day, 01:02", "digital days");
eq(new Intl.DurationFormat("en", { style: "digital", fractionalDigits: 3 }).format({ hours: 1, minutes: 22, seconds: 33, milliseconds: 111, microseconds: 222 }), "1:22:33.111", "fractional digits truncate");
eq(new Intl.DurationFormat("en", { style: "digital" }).format({ hours: 12, minutes: 34, seconds: 56, milliseconds: 1234567 }), "12:34:1290.567", "folded sub-seconds");
eq(new Intl.DurationFormat("en", { style: "digital" }).format({ days: 1234567, hours: 3, minutes: 20, seconds: 45 }), "1,234,567 days, 3:20:45", "grouping only outside the clock");
eq(new Intl.DurationFormat("en").format({ hours: -1, minutes: -30 }), "-1 hr, 30 min", "sign on the first unit only");
eq(new Intl.DurationFormat("en", { secondsDisplay: "always" }).format({ seconds: 0 }), "0 sec", "always shows zero");
eq(new Intl.DurationFormat("en").format({ hours: 0 }), "", "auto hides zero");
eq(new Intl.DurationFormat("en").format("PT1H30M"), "1 hr, 30 min", "ISO string");
eq(new Intl.DurationFormat("en").format(new Temporal.Duration(0, 0, 0, 2)), "2 days", "Temporal.Duration");

var parts = new Intl.DurationFormat("en", { style: "digital" }).formatToParts({ hours: 1, minutes: 2, seconds: 3 });
eq(parts.map(function (p) { return p.type + ":" + p.value + ":" + p.unit; }).join("|"),
   "integer:1:hour|literal:::undefined|integer:02:minute|literal:::undefined|integer:03:second", "parts keep unit and separator");

var o = new Intl.DurationFormat("en", { hours: "numeric", fractionalDigits: 2 }).resolvedOptions();
eq(o.minutes + "," + o.seconds + "," + o.milliseconds + "," + o.fractionalDigits, "2-digit,2-digit,numeric,2", "defaults after a numeric unit");
eq(Object.keys(new Intl.DurationFormat().resolvedOptions()).length, 23, "no fractionalDigits when undefined");

throws(RangeError, function () { new Intl.DurationFormat("en", { hours: "numeric", minutes: "long" }); }, "style after numeric");
throws(RangeError, function () { new Intl.DurationFormat("en", { millisecondsDisplay: "always", milliseconds: "numeric" }); }, "fractional always");
throws(RangeError, function () { new Intl.DurationFormat("en", { fractionalDigits: 10 }); }, "fractionalDigits range");
throws(RangeError, function () { new Intl.DurationFormat().format({ hours: 1, minutes: -1 }); }, "mixed signs");
throws(RangeError, function () { new Intl.DurationFormat().format({ years: 4294967296 }); }, "years limit");
throws(TypeError, function () { new Intl.DurationFormat().format({}); }, "no fields");
throws(TypeError, function () { Intl.DurationFormat(); }, "requires new");

eq(new Intl.DurationFormat("en", { numberingSystem: "arab", style: "digital" }).format({ hours: 1, minutes: 2, seconds: 3 }), "١:٠٢:٠٣", "numbering system");
