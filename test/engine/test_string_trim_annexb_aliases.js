// Annex B §B.2.2.14-15: String.prototype.trimLeft and trimRight are the *same
// function objects* as trimStart and trimEnd, not separate implementations.
//
// The engine registered trimStart/trimEnd but omitted both legacy aliases
// entirely, so `"x ".trimRight()` threw "undefined is not a function". marked
// 4.3.0's list tokenizer calls .trimRight() on every list item's raw text and
// contents, which meant every Markdown document containing a list failed to
// parse -- while headings, paragraphs and links, which never trim, worked. The
// throw surfaced only as marked's own generic "Please report this" rethrow.
//
// Registering an alias must share the canonical function object rather than
// allocate a second one: the spec defines these as the very same %trimStart%
// and %trimEnd% intrinsics, so identity and `.name` are both observable.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " -- expected " + expected + " got " + actual);
        failures++;
    }
}

// --- the aliases exist and are callable ---
check("trimRightType", typeof "".trimRight, "function");
check("trimLeftType", typeof "".trimLeft, "function");

// --- they trim the correct end ---
check("trimRightTrims", "  ab  ".trimRight(), "  ab");
check("trimLeftTrims", "  ab  ".trimLeft(), "ab  ");
check("trimRightTabsNewlines", "ab \t\n\r ".trimRight(), "ab");
check("trimLeftTabsNewlines", " \t\n\r ab".trimLeft(), "ab");
check("trimRightNoop", "ab".trimRight(), "ab");
check("trimRightAllSpace", "   ".trimRight(), "");

// --- identity with the canonical intrinsics ---
check("trimRightIsTrimEnd", "".trimRight === "".trimEnd, true);
check("trimLeftIsTrimStart", "".trimLeft === "".trimStart, true);

// --- the alias keeps the canonical name, per the intrinsic's own definition ---
check("trimRightName", "".trimRight.name, "trimEnd");
check("trimLeftName", "".trimLeft.name, "trimStart");
check("trimRightLength", "".trimRight.length, 0);

// --- property attributes match a normal prototype method ---
var d = Object.getOwnPropertyDescriptor(String.prototype, "trimRight");
check("trimRightWritable", d.writable, true);
check("trimRightEnumerable", d.enumerable, false);
check("trimRightConfigurable", d.configurable, true);

// --- generic: works on a non-string this via ToString coercion ---
check("trimRightGeneric",
      String.prototype.trimRight.call({ toString: function () { return "hi  "; } }),
      "hi");

// --- the marked.js shape: trimming list-item text pulled off an array ---
var items = [{ raw: "- a\n", text: "a  " }, { raw: "- b\n\n", text: "b\t" }];
var joined = "";
for (var i = 0; i < items.length; i++) {
    joined += items[i].raw.trimRight() + "|" + items[i].text.trimRight() + ";";
}
check("markedListItemShape", joined, "- a|a;- b|b;");

if (failures === 0) {
    print("PASS: trimLeft/trimRight alias trimStart/trimEnd");
} else {
    print("FAILED: " + failures + " check(s)");
}
