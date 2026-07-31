// Drives date_format.js -- uses: date, concise, pretty
//
// The sample pins timeZone to UTC, so these expectations hold in any host
// timezone. They match node's en-US output byte for byte.

assertEq(concise, "2007-11-23", "toISOString gives the concise ISO date");
assertEq(pretty, "Friday, November 23, 2007",
    "toLocaleString honours weekday/year/month/day against timeZone UTC");

// The sample's own instant, so a wrong parse cannot pass the two checks above
// by coincidence.
assertEq(date.getTime(), Date.UTC(2007, 10, 23), "the sample parsed the ISO input");
assertEq(date.toISOString(), "2007-11-23T00:00:00.000Z", "the instant round-trips");

report("date_format");
