// Hash map / dictionary
// Demonstrates dynamic key/value storage with object literals and Maps.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// Object as map (string keys)
var dict = {};
dict["apple"] = 1;
dict["banana"] = 2;
dict["cherry"] = 3;

assert(dict["apple"] === 1, "dict apple");
assert(dict["banana"] === 2, "dict banana");
assert(Object.keys(dict).length === 3, "dict 3 keys");

// hasOwnProperty guard
assert(dict.hasOwnProperty("apple"), "has apple");
assert(!dict.hasOwnProperty("date"), "no date");

// Delete
delete dict["banana"];
assert(!dict.hasOwnProperty("banana"), "delete banana");
assert(Object.keys(dict).length === 2, "size after delete");

// Iteration
var sum = 0;
var keys = Object.keys(dict).sort();
assert(keys.join(",") === "apple,cherry", "sorted keys");
for (var i = 0; i < keys.length; i++) sum += dict[keys[i]];
assert(sum === 4, "iter sum");

// Counter pattern
function wordCount(text) {
    var counts = {};
    var words = text.split(/\s+/);
    for (var i = 0; i < words.length; i++) {
        var w = words[i];
        if (w.length === 0) continue;
        counts[w] = (counts[w] || 0) + 1;
    }
    return counts;
}

var wc = wordCount("the quick brown fox jumps over the lazy dog the");
assert(wc["the"] === 3, "wc the=3");
assert(wc["fox"] === 1, "wc fox=1");

// Two-sum: find pair summing to target
function twoSum(nums, target) {
    var seen = {};
    for (var i = 0; i < nums.length; i++) {
        var need = target - nums[i];
        if (seen.hasOwnProperty(need)) {
            return [seen[need], i];
        }
        seen[nums[i]] = i;
    }
    return null;
}

assert(JSON.stringify(twoSum([2, 7, 11, 15], 9)) === "[0,1]", "twoSum 9");
assert(JSON.stringify(twoSum([3, 2, 4], 6)) === "[1,2]", "twoSum 6");

print("engine/hash_map: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");