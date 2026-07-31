// Anagram detection
// Group words that are anagrams of each other.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function anagramKey(word) {
    return word.toLowerCase().split("").sort().join("");
}

function anagramGroups(words) {
    var groups = {};
    for (var i = 0; i < words.length; i++) {
        var w = words[i];
        var k = anagramKey(w);
        if (groups[k] === undefined) groups[k] = [];
        groups[k].push(w);
    }
    return groups;
}

function isAnagram(a, b) {
    return anagramKey(a) === anagramKey(b);
}

assert(isAnagram("listen", "silent"), "listen/silent");
assert(isAnagram("anagram", "nagaram"), "anagram/nagaram");
assert(!isAnagram("hello", "world"), "hello/world");
assert(!isAnagram("a", "aa"), "a/aa");

// Group anagrams
var words = ["listen", "silent", "enlist", "inlets", "google", "gooegl", "banana"];
var groups = anagramGroups(words);
assert(groups[anagramKey("listen")].length === 4, "4 listen-anagrams");
assert(groups[anagramKey("google")].length === 2, "2 google-anagrams");
assert(groups[anagramKey("banana")].length === 1, "1 banana");

// Verify the listen group
var listenGroup = groups[anagramKey("listen")];
var expected = ["listen", "silent", "enlist", "inlets"];
for (var i = 0; i < expected.length; i++) {
    assert(listenGroup.indexOf(expected[i]) !== -1, "listen group has " + expected[i]);
}

// Anagrams of long words (without spaces for this test)
assert(isAnagram("conversation", "voicesranton"), "long anagram");
assert(isAnagram("astronomer", "moonstarer"), "astronomer/moonstarer");

print("engine/anagrams: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");