// Array.prototype.join copies units straight into a string of the width they
// need. The result stays canonical: wide only when some unit is above 0xFF, so
// a wide separator that is never copied leaves the result narrow.
function check(actual, expected, label) {
  if (actual !== expected) throw new Error(label + ": got " + JSON.stringify(actual) + ", want " + JSON.stringify(expected));
}

check(["a", "é", "日本", "", "\uD800", "x"].join("-"), "a-é-日本--\uD800-x", "mixed widths");
check([].join(), "", "empty array");
check(["", ""].join(""), "", "empty pieces");
check([1, 2].join(), "1,2", "default separator");
check(["é", "ü"].join("é"), "ééü", "latin-1 separator");
check(["é", "ü"].join("日").charCodeAt(1), 0x65E5, "separator widens the result");
check(["abc"].join("😀"), "abc", "one piece ignores a wide separator");
check(["abc", "é"].join("😀").length, 6, "wide separator between narrow pieces");

var single = ["abc"].join("😀");
var keyed = { abc: 1 };
check(single in keyed, true, "single-piece join is a canonical key");
check(["é"].join("日") === "é", true, "single latin-1 piece");
