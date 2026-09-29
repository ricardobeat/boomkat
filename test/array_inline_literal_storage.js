// Six-element literals keep their dense slots with the header until migration.

function fail(message) { throw new Error(message); }

var first = { value: "first" };
var middle = { value: "middle" };
var last = { value: "last" };
var values = [first, "two", middle, undefined, "five", last];
if (values.length !== 6 || values[0] !== first || values[1] !== "two"
    || values[2] !== middle || values[3] !== undefined
    || values[4] !== "five" || values[5] !== last) {
    fail("inline literal slots retain values");
}
if (!values.hasOwnProperty("3") || Object.keys(values).join(",") !== "0,1,2,3,4,5") {
    fail("explicit undefined remains present in inline storage");
}

// A named property moves the dense slots; later growth moves them again.
values.note = "named";
if (values.note !== "named" || values[0] !== first || values[2] !== middle
    || values[5] !== last) {
    fail("named-property migration preserves inline elements");
}
values[9] = "grown";
if (values.length !== 10 || values[0] !== first || values[5] !== last
    || values[9] !== "grown" || values.hasOwnProperty("7")) {
    fail("dense growth preserves migrated inline elements and holes");
}

// Length truncation releases dense values, then later writes can regrow storage.
values.length = 2;
if (values.length !== 2 || values.hasOwnProperty("5") || values.hasOwnProperty("9")) {
    fail("length truncation removes migrated dense elements");
}
values[5] = last;
if (values.length !== 6 || values[0] !== first || values[5] !== last) {
    fail("dense storage remains usable after truncation");
}

// Migration can start with growth instead of a named property.
var grownFirst = { keep: 1 };
var grown = [grownFirst, 2, 3, 4, 5, 6];
grown[12] = 13;
grown.label = "after growth";
if (grown[0] !== grownFirst || grown[5] !== 6 || grown[12] !== 13
    || grown.label !== "after growth") {
    fail("growth-first migration preserves dense and named data");
}

print("array_inline_literal_storage: all checks passed");
