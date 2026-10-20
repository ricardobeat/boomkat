// Date operations benchmark
// Tests Date constructor, parsing, getters, formatting, and static methods

var bench = function(name, fn, iterations) {
    var start = Date.now();
    for (var i = 0; i < iterations; i++) { fn(); }
    var elapsed = Date.now() - start;
    print(name + ": " + elapsed + " ms (" + iterations + " iterations)");
};

var N = 2000;

// ── new Date() construction (current time) ──────────────────────────────────
bench("new Date()", function () {
    var d = new Date();
}, N);

// ── new Date(milliseconds) ─────────────────────────────────────────────────
bench("new Date(ms)", function () {
    var d = new Date(1718553600000);
}, N);

// ── new Date(year, month, day, hour, min, sec, ms) ─────────────────────────
bench("new Date(y,m,d,...)", function () {
    var d = new Date(2025, 5, 15, 10, 30, 0, 0);
}, N);

// ── new Date(dateString) ───────────────────────────────────────────────────
bench("new Date(string)", function () {
    var d = new Date("2025-06-15T10:30:00Z");
}, N);

// ── Date.parse() ───────────────────────────────────────────────────────────
bench("Date.parse", function () {
    var t = Date.parse("2025-06-15T10:30:00Z");
}, N);

// ── date.getTime() ─────────────────────────────────────────────────────────
var d0 = new Date(2025, 5, 15, 10, 30, 0, 0);
bench("getTime", function () {
    var t = d0.getTime();
}, N);

// ── date.getFullYear() ─────────────────────────────────────────────────────
bench("getFullYear", function () {
    var y = d0.getFullYear();
}, N);

// ── date.getMonth() ────────────────────────────────────────────────────────
bench("getMonth", function () {
    var m = d0.getMonth();
}, N);

// ── date.getDate() ─────────────────────────────────────────────────────────
bench("getDate", function () {
    var d = d0.getDate();
}, N);

// ── date.getDay() ──────────────────────────────────────────────────────────
bench("getDay", function () {
    var d = d0.getDay();
}, N);

// ── date.getHours() / getMinutes() / getSeconds() ──────────────────────────
bench("getHours+getMinutes+getSeconds", function () {
    var h = d0.getHours();
    var m = d0.getMinutes();
    var s = d0.getSeconds();
}, N);

// ── date.toISOString() ─────────────────────────────────────────────────────
bench("toISOString", function () {
    var s = d0.toISOString();
}, N);

// ── date.toUTCString() ─────────────────────────────────────────────────────
bench("toUTCString", function () {
    var s = d0.toUTCString();
}, N);

// ── date.toString() ────────────────────────────────────────────────────────
bench("toString", function () {
    var s = d0.toString();
}, N);

// ── date.toDateString() ────────────────────────────────────────────────────
bench("toDateString", function () {
    var s = d0.toDateString();
}, N);

// ── date.toTimeString() ────────────────────────────────────────────────────
bench("toTimeString", function () {
    var s = d0.toTimeString();
}, N);

// ── date.toLocaleString() ──────────────────────────────────────────────────
bench("toLocaleString", function () {
    var s = d0.toLocaleString();
}, N);

// ── Date.now() ─────────────────────────────────────────────────────────────
bench("Date.now", function () {
    var n = Date.now();
}, N);

// ── Date.UTC() ─────────────────────────────────────────────────────────────
bench("Date.UTC", function () {
    var u = Date.UTC(2025, 5, 15, 10, 30, 0, 0);
}, N);

// ── Mixed: construct then format ───────────────────────────────────────────
bench("construct+toISOString", function () {
    var d = new Date(2025, 5, 15, 10, 30, 0, 0);
    var s = d.toISOString();
}, N);

// ── Set full year ──────────────────────────────────────────────────────────
bench("setFullYear", function () {
    d0.setFullYear(2030);
}, N);

// ── Set month ──────────────────────────────────────────────────────────────
bench("setMonth", function () {
    d0.setMonth(11);
}, N);

// ── Set date ───────────────────────────────────────────────────────────────
bench("setDate", function () {
    d0.setDate(25);
}, N);

// Restore d0 for consistency
d0 = new Date(2025, 5, 15, 10, 30, 0, 0);

print("done");
