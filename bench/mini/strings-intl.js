// Non-ASCII string workloads: unit indexing, slicing and searching, regexp, and JSON.
// Prints "<name>: <ms> ms (checksum)" per section so a wrong answer is visible.

if (typeof print == "undefined" && typeof console != "undefined") print = console.log;

var SEED = 12345;
function rnd(n) {
  SEED = (SEED * 1103515245 + 12345) & 0x7fffffff;
  return SEED % n;
}

function build(alphabet, n) {
  var out = [];
  for (var i = 0; i < n; i++) out.push(alphabet[rnd(alphabet.length)]);
  return out.join("");
}

var CJK = "日本語の文字列処理速度測定漢字仮名交じり文章";
var CYRILLIC = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя ";
var LATIN1 = "àáâãäåçèéêëìíîïñòóôõöùúûüýÿ abc ";
var EMOJI = ["\u{1F600}", "\u{1F680}", "a", "b", " ", "é"];

var N = 20000;
var texts = {
  cjk: build(CJK, N),
  cyrillic: build(CYRILLIC, N),
  latin1: build(LATIN1, N),
  emoji: build(EMOJI, N / 2),
};
var names = Object.keys(texts);

function time(name, fn) {
  var t = Date.now();
  var sum = fn();
  print(name + ": " + (Date.now() - t) + " ms (" + sum + ")");
}

time("charCodeAt-random", function () {
  var sum = 0;
  for (var k = 0; k < names.length; k++) {
    var s = texts[names[k]];
    for (var i = 0; i < 60000; i++) sum += s.charCodeAt(rnd(s.length));
  }
  return sum;
});

time("index-random", function () {
  var sum = 0;
  for (var k = 0; k < names.length; k++) {
    var s = texts[names[k]];
    for (var i = 0; i < 60000; i++) sum += s[rnd(s.length)].length;
  }
  return sum;
});

time("slice-random", function () {
  var sum = 0;
  for (var k = 0; k < names.length; k++) {
    var s = texts[names[k]];
    for (var i = 0; i < 6000; i++) {
      var a = rnd(s.length - 40);
      sum += s.slice(a, a + 1 + rnd(40)).length;
    }
  }
  return sum;
});

time("indexOf-offsets", function () {
  var sum = 0;
  for (var k = 0; k < names.length; k++) {
    var s = texts[names[k]];
    for (var i = 0; i < 3000; i++) {
      var from = rnd(s.length - 16);
      var needle = s.slice(from + 8, from + 12);
      sum += s.indexOf(needle, from);
    }
  }
  return sum;
});

time("split-join", function () {
  var sum = 0;
  for (var k = 0; k < names.length; k++) {
    var s = texts[names[k]];
    var sep = s.charAt(5);
    for (var i = 0; i < 20; i++) sum += s.split(sep).join(sep).length;
  }
  return sum;
});

time("regexp-exec", function () {
  var sum = 0;
  var res = [/[а-я]+/g, /[ぁ-ん]+|[一-龥]{2,}/g, /[à-ÿ]+/g, /\u{1F600}./gu];
  for (var k = 0; k < names.length; k++) {
    var s = texts[names[k]];
    for (var r = 0; r < res.length; r++) {
      var re = res[r];
      re.lastIndex = 0;
      var m;
      while ((m = re.exec(s)) !== null) sum += m.index + m[0].length;
    }
  }
  return sum;
});

time("regexp-replace", function () {
  var sum = 0;
  for (var k = 0; k < names.length; k++) {
    var s = texts[names[k]];
    for (var i = 0; i < 3; i++) {
      sum += s.replace(/[aeiouаеёиоуыэюяあいうえお]/g, "_").length;
      sum += s.replace(/\s+/g, function (m) { return m + m; }).length;
    }
  }
  return sum;
});

var payload = [];
for (var i = 0; i < 3000; i++) {
  payload.push({
    id: i,
    name: build(LATIN1, 12),
    title: build(CJK, 8),
    note: "café \u{1F600} " + build(CYRILLIC, 10),
    tags: ["résumé", "naïve", "日本"],
  });
}

time("JSON.stringify", function () {
  var sum = 0;
  for (var i = 0; i < 8; i++) sum += JSON.stringify(payload).length;
  return sum;
});

var json = JSON.stringify(payload);
time("JSON.parse", function () {
  var sum = 0;
  for (var i = 0; i < 8; i++) sum += JSON.parse(json).length;
  return sum;
});
