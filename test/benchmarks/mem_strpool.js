// Many unique strings only
var strings = [];
// Generate ~5000 unique strings
for (var i = 0; i < 5000; i++) {
    strings.push("unique_string_key_value_" + i + "_suffix");
}
// Access to prevent optimization
var sum = 0;
for (var i = 0; i < strings.length; i++) { sum += strings[i].length; }
if (sum < 0) print("never");
