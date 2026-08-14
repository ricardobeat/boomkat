// Two Date coercion bugs found loading moment.js against qjs as oracle.
//
// 1. ES2024 §21.4.2.1 step 3.a.iii: `new Date(unparseableString)` must set
//    [[DateValue]] to NaN, producing an Invalid Date. The constructor's
//    string branch instead fell back to the *current time* once ISO, locale
//    and numeric-string parses had all failed, so every unrecognised string
//    became a valid Date pinned to "now". moment.utc("not-a-date").isValid()
//    returned true because moment's last-resort path is `new Date(input)` and
//    it grades validity off that object's time value.
//
// 2. ES2024 §7.1.4 ToNumber step 8 converts an object via ToPrimitive(hint
//    *number*), and §21.4.4.45 Date.prototype[@@toPrimitive] only promotes
//    hint "default" (not "number") to a toString-first lookup. vm_to_number
//    passed the default hint, so a Date reached OrdinaryToPrimitive's
//    string-first branch and `+date` / `date - date` parsed the date *string*
//    as a number: NaN. Date arithmetic was broken engine-wide, while
//    Number(date) and date.getTime() were correct -- they never go through
//    the ToNumber object path.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " -- expected " + expected + " got " + actual);
        failures++;
    }
}

// --- 1. an unparseable string yields an Invalid Date, not "now" ---
var bad = new Date("not-a-date");
check("badGetTimeIsNaN", isNaN(bad.getTime()), true);
check("badValueOfIsNaN", isNaN(bad.valueOf()), true);
check("badToString", bad.toString(), "Invalid Date");
check("badParse", isNaN(Date.parse("not-a-date")), true);
check("badGarbage", isNaN(new Date("garbage").getTime()), true);
check("badEmptyIsNaN", isNaN(new Date("").getTime()), true);
// A string argument is parsed as a *date* string only, never as a count of
// milliseconds -- so a bare millisecond literal is not a date (matches qjs
// and node). The same fallback used to shadow the year-only ISO form below.
check("msLiteralString", isNaN(new Date("1579080600000").getTime()), true);
check("msLiteralParse", isNaN(Date.parse("1579080600000")), true);
check("expNotationString", isNaN(Date.parse("1e3")), true);
// A number argument is still a time value.
check("numberArg", new Date(1579080600000).getTime(), 1579080600000);
// Date-only ISO forms parse as UTC (ES2024 §21.4.3.2).
check("isoYearOnly", Date.parse("2020"), 1577836800000);
check("isoYearMonth", Date.parse("2020-01"), 1577836800000);
check("isoStillParses", new Date("2020-01-15T10:30:00Z").getTime(), 1579084200000);

// --- 2. ToNumber(date) uses hint "number" -> valueOf, not toString ---
var v = new Date(Date.UTC(2020, 0, 15, 10, 30, 0));
var w = new Date(Date.UTC(2021, 0, 15, 10, 30, 0));
check("unaryPlus", +v, 1579084200000);
check("multiply", v * 1, 1579084200000);
check("subtractZero", v - 0, 1579084200000);
check("dateDiff", w - v, 31622400000);
check("numberStillWorks", Number(v), 1579084200000);
check("invalidDateArithmetic", isNaN(bad - 0), true);

// --- hint "default" is still string for Date: `date + x` concatenates ---
check("addIsConcat", typeof (v + 1), "string");
check("looseEqNotTimeValue", v == v.getTime(), false);
check("toPrimitiveNumber", v[Symbol.toPrimitive]("number"), 1579084200000);
check("toPrimitiveDefaultIsString", typeof v[Symbol.toPrimitive]("default"), "string");

// --- the moment.js shape: grading validity off a fallback `new Date()` ---
function momentIsValid(input) {
    return !isNaN(new Date(input).valueOf());
}
check("momentShapeInvalid", momentIsValid("not-a-date"), false);
check("momentShapeValid", momentIsValid("2020-01-15T10:30:00Z"), true);

if (failures === 0) {
    print("PASS: invalid Date strings and ToNumber(date) hint");
} else {
    print("FAILED: " + failures + " check(s)");
}
