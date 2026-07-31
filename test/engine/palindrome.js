// Palindrome detection

function isPalindrome(s) {
    var len = s.length;
    for (var i = 0; i < Math.floor(len / 2); i++) {
        if (s.charAt(i) !== s.charAt(len - 1 - i)) return false;
    }
    return true;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

assert(isPalindrome("") === true, "empty is palindrome");
assert(isPalindrome("a") === true, "single char");
assert(isPalindrome("racecar") === true, "racecar");
assert(isPalindrome("hello") === false, "hello");
assert(isPalindrome("abba") === true, "abba");
assert(isPalindrome("ab") === false, "ab");

print("engine/palindrome: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
