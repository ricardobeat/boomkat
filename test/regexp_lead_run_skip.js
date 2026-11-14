// A failed attempt that opened with a greedy run skips the starts that run covered; a
// back reference keeps every start. Also exec results read in an optimized loop.
var cases = [
  [/(\w+)=(\d+)/, ["abcdefghij key=12345 more", "ab=x cd=12", "a=1", "=1 x=", "aaa bbb ccc=9", "x==1y=2"]],
  [/\w+x/, ["aaaa bbbx", "x", "ab ax", "aaa"]],
  [/(a+)b/, ["aaac aab", "aaaa", "ab"]],
  [/\w*=/, ["abc def=", "==", "abc"]],
  [/(\w+)\1=/, ["abab= abcabc=", "xx= yy"]],
  [/[a-z]+\d/, ["abc def1", "abc", "a1b2"]],
  [/\d+(?=px)/, ["10em 20px", "1px"]],
  [/\s+\S/, ["a   b", "   "]],
  [/[^,]+,x/, ["aa,bb,x", "aa,bb"]],
  [/\w+(?<=a)b/, ["xxab cab", "ab"]],
];
var expected = ["(\\w+)=(\\d+) \"abcdefghij key=12345 more\" [[\"key=12345\",\"key\",\"12345\"],11]","(\\w+)=(\\d+) \"ab=x cd=12\" [[\"cd=12\",\"cd\",\"12\"],5]","(\\w+)=(\\d+) \"a=1\" [[\"a=1\",\"a\",\"1\"],0]","(\\w+)=(\\d+) \"=1 x=\" null","(\\w+)=(\\d+) \"aaa bbb ccc=9\" [[\"ccc=9\",\"ccc\",\"9\"],8]","(\\w+)=(\\d+) \"x==1y=2\" [[\"1y=2\",\"1y\",\"2\"],3]","\\w+x \"aaaa bbbx\" [[\"bbbx\"],5]","\\w+x \"x\" null","\\w+x \"ab ax\" [[\"ax\"],3]","\\w+x \"aaa\" null","(a+)b \"aaac aab\" [[\"aab\",\"aa\"],5]","(a+)b \"aaaa\" null","(a+)b \"ab\" [[\"ab\",\"a\"],0]","\\w*= \"abc def=\" [[\"def=\"],4]","\\w*= \"==\" [[\"=\"],0]","\\w*= \"abc\" null","(\\w+)\\1= \"abab= abcabc=\" [[\"abab=\",\"ab\"],0]","(\\w+)\\1= \"xx= yy\" [[\"xx=\",\"x\"],0]","[a-z]+\\d \"abc def1\" [[\"def1\"],4]","[a-z]+\\d \"abc\" null","[a-z]+\\d \"a1b2\" [[\"a1\"],0]","\\d+(?=px) \"10em 20px\" [[\"20\"],5]","\\d+(?=px) \"1px\" [[\"1\"],0]","\\s+\\S \"a   b\" [[\"   b\"],1]","\\s+\\S \"   \" null","[^,]+,x \"aa,bb,x\" [[\"bb,x\"],3]","[^,]+,x \"aa,bb\" null","\\w+(?<=a)b \"xxab cab\" [[\"xxab\"],0]","\\w+(?<=a)b \"ab\" [[\"ab\"],0]"];
function check() {
  var i = 0;
  cases.forEach(function (c) {
    c[1].forEach(function (s) {
      var m = c[0].exec(s);
      var got = c[0].source + " " + JSON.stringify(s) + " " + JSON.stringify(m && [Array.from(m), m.index]);
      if (got !== expected[i]) print("FAIL " + got + " expected " + expected[i]);
      i++;
    });
  });
}
for (var k = 0; k < 300; k++) check();
// The captures of a match, read and tested for truth in a loop the optimizing tier compiles.
function lengths(re, s) {
  var sum = 0;
  var a = re.exec(s);
  if (a) for (var i = 0; i < a.length; i++) { var x = a[i]; if (x) sum += x.length; else sum += 100; }
  return sum;
}
var total = 0;
for (var k = 0; k < 20000; k++) total += lengths(/(\w+)=(\d+)?(x)?/, k % 2 ? "ab= c=12" : "key=1x");
if (total !== 10000 * 205 + 10000 * 11) print("FAIL lengths " + total);
print("done");
