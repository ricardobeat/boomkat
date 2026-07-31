// Switch statement
// Tests switch/case, fall-through, default, string/number cases.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Basic switch
function dayName(n) {
    switch (n) {
        case 1: return "Monday";
        case 2: return "Tuesday";
        case 3: return "Wednesday";
        case 4: return "Thursday";
        case 5: return "Friday";
        case 6: return "Saturday";
        case 0: return "Sunday";
        default: return "unknown";
    }
}
assert(dayName(1) === "Monday", "case 1");
assert(dayName(5) === "Friday", "case 5");
assert(dayName(0) === "Sunday", "case 0");
assert(dayName(99) === "unknown", "default case");

// String switch
function httpStatus(code) {
    switch (code) {
        case "200": return "OK";
        case "301": return "Moved";
        case "404": return "Not Found";
        case "500": return "Server Error";
        default: return "Unknown";
    }
}
assert(httpStatus("200") === "OK", "string case 200");
assert(httpStatus("404") === "Not Found", "string case 404");
assert(httpStatus("418") === "Unknown", "string default");

// Fall-through
function romanDigit(n) {
    var result = "";
    switch (n) {
        case 1: result += "I"; break;
        case 2: result += "II"; break;
        case 3: result += "III"; break;
        case 4: result += "IV"; break;
        case 5: result += "V"; break;
        default: result += "?";
    }
    return result;
}
assert(romanDigit(1) === "I", "roman 1");
assert(romanDigit(4) === "IV", "roman 4");

// Intentional fall-through
function isWeekend(day) {
    switch (day) {
        case "Saturday":
        case "Sunday":
            return true;
        default:
            return false;
    }
}
assert(isWeekend("Saturday") === true, "fall-through Saturday");
assert(isWeekend("Sunday") === true, "fall-through Sunday");
assert(isWeekend("Monday") === false, "not weekend");

// Switch with expressions in cases
function classify(n) {
    switch (true) {
        case (n < 0): return "negative";
        case (n === 0): return "zero";
        case (n > 0 && n < 10): return "small positive";
        default: return "large positive";
    }
}
assert(classify(-5) === "negative", "switch true negative");
assert(classify(0) === "zero", "switch true zero");
assert(classify(5) === "small positive", "switch true small");
assert(classify(100) === "large positive", "switch true large");

// Switch in loop
function findFirst(arr, target) {
    for (var i = 0; i < arr.length; i++) {
        switch (arr[i]) {
            case target: return i;
        }
    }
    return -1;
}
assert(findFirst([10, 20, 30, 40], 30) === 2, "find index 2");
assert(findFirst([10, 20, 30], 99) === -1, "not found");

print("engine/switch_case: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
