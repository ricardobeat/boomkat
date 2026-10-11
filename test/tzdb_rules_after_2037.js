// The tz database ships explicit transitions only up to each zone's POSIX
// footer rule; later years are computed from the rule.
function eq(a, b) { if (a !== b) throw new Error("expected " + b + ", got " + a); }
function offset(iso, zone) { return Temporal.ZonedDateTime.from(iso + "[" + zone + "]").offset; }
eq(offset("2024-07-01T12:00", "America/New_York"), "-04:00");
eq(offset("2024-01-01T12:00", "America/New_York"), "-05:00");
eq(offset("2050-07-01T12:00", "America/New_York"), "-04:00");
eq(offset("2050-01-01T12:00", "America/New_York"), "-05:00");
eq(offset("2099-07-01T12:00", "Europe/Paris"), "+02:00");
eq(offset("2099-01-01T12:00", "Europe/Paris"), "+01:00");
eq(offset("2060-01-01T12:00", "Australia/Sydney"), "+11:00");
eq(offset("2060-07-01T12:00", "Australia/Sydney"), "+10:00");
eq(offset("2060-07-01T12:00", "Asia/Kolkata"), "+05:30");

var z = Temporal.ZonedDateTime.from("2060-07-01T12:00[America/New_York]");
eq(z.getTimeZoneTransition("next").toString(), "2060-11-07T01:00:00-05:00[America/New_York]");
eq(z.getTimeZoneTransition("previous").toString(), "2060-03-14T03:00:00-04:00[America/New_York]");
eq(Temporal.ZonedDateTime.from("2024-07-01T12:00[Asia/Kolkata]").getTimeZoneTransition("next"), null);

// A wall time inside a post-2037 spring-forward gap moves past it.
eq(Temporal.ZonedDateTime.from("2060-03-14T02:30[America/New_York]").toString(),
   "2060-03-14T03:30:00-04:00[America/New_York]");
eq(new Intl.DateTimeFormat("en", {timeZone: "America/New_York", timeZoneName: "short"})
   .format(Date.UTC(2060, 6, 1)).slice(-3), "EDT");

// String parsing interprets an offset-less wall time in the zone, by the
// disambiguation option, on both sides of UTC.
function parse(str, d) {
    try { return Temporal.ZonedDateTime.from(str, {disambiguation: d}).toString(); } catch (e) { return e.name; }
}
var NY_GAP = "2024-03-10T02:30[America/New_York]", NY_FALL = "2024-11-03T01:30[America/New_York]";
var PA_GAP = "2024-03-31T02:30[Europe/Paris]", PA_FALL = "2024-10-27T02:30[Europe/Paris]";
eq(parse(NY_GAP, "compatible"), "2024-03-10T03:30:00-04:00[America/New_York]");
eq(parse(NY_GAP, "earlier"), "2024-03-10T01:30:00-05:00[America/New_York]");
eq(parse(NY_GAP, "reject"), "RangeError");
eq(parse(NY_FALL, "compatible"), "2024-11-03T01:30:00-04:00[America/New_York]");
eq(parse(NY_FALL, "later"), "2024-11-03T01:30:00-05:00[America/New_York]");
eq(parse(PA_GAP, "compatible"), "2024-03-31T03:30:00+02:00[Europe/Paris]");
eq(parse(PA_GAP, "earlier"), "2024-03-31T01:30:00+01:00[Europe/Paris]");
eq(parse(PA_FALL, "compatible"), "2024-10-27T02:30:00+02:00[Europe/Paris]");
eq(parse(PA_FALL, "later"), "2024-10-27T02:30:00+01:00[Europe/Paris]");
eq(parse(PA_FALL, "reject"), "RangeError");
eq(Temporal.PlainDateTime.from("2024-03-31T02:30").toZonedDateTime("Europe/Paris").toString(),
   "2024-03-31T03:30:00+02:00[Europe/Paris]");
console.log("ok");
