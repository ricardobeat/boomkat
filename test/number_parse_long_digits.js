// parseInt and Number(string) round long digit runs correctly: decimal runs
// match Number(), and 0x / 0b / 0o literals do not wrap past 64 bits.
var pass = 0, fail = 0;
function t(name, got, want) {
  if (got === want) { pass++; } else { fail++; print("FAIL: " + name + ": got " + got + ", want " + want); }
}
var two80 = Math.pow(2, 80);

t("parseInt 1e30", parseInt("1" + "0".repeat(30)), 1e30);
t("parseInt matches Number", parseInt("123456789012345678901234567890"), Number("123456789012345678901234567890"));
t("parseInt leading zeros", parseInt("0".repeat(50) + "123"), 123);
t("parseInt 2^53+1", parseInt("9007199254740993"), 9007199254740992);
t("parseInt 1e308", parseInt("1" + "0".repeat(308)), 1e308);
t("parseInt overflow", parseInt("1" + "0".repeat(309)), Infinity);
t("parseInt huge", parseInt("1" + "0".repeat(1000)), Infinity);
t("parseInt negative", parseInt("-" + "7".repeat(25)), -Number("7".repeat(25)));
t("parseInt stops at non-digit", parseInt("12345678901234567890xyz"), 12345678901234567000);
t("parseInt -0", 1 / parseInt("-0"), -Infinity);

t("parseInt hex", parseInt("f".repeat(20), 16), two80);
t("parseInt 0x prefix", parseInt("0x" + "f".repeat(20)), two80);
t("parseInt binary", parseInt("1".repeat(80), 2), two80);
t("parseInt octal", parseInt("7".repeat(30), 8), Number("0o" + "7".repeat(30)));
t("parseInt base 32", parseInt("v".repeat(16), 32), Math.pow(2, 80));
t("parseInt hex tie", parseInt("20000000000003", 16), 9007199254740996);
t("parseInt hex sticky", parseInt("1" + "0".repeat(20) + "1", 16), 1.9342813113834067e+25);
t("parseInt hex overflow", parseInt("f".repeat(300), 16), Infinity);
t("parseInt radix 3", parseInt("21", 3), 7);
t("parseInt radix 36", parseInt("zz", 36), 1295);

t("Number 0x", Number("0x" + "f".repeat(20)), two80);
t("Number 0b", Number("0b" + "1".repeat(80)), two80);
t("Number 0o", Number("0o" + "7".repeat(30)), 1.2379400392853803e+27);
t("Number 0x tie", Number("0x20000000000003"), 9007199254740996);
t("Number 0x sticky", Number("0x1" + "0".repeat(20) + "1"), 1.9342813113834067e+25);
t("Number 0x zeros", Number("0x" + "0".repeat(30) + "ff"), 255);
t("Number 0x overflow", Number("0x" + "f".repeat(300)), Infinity);
t("Number 0X upper", Number("0XFF"), 255);
t("Number 0x trailing space", Number("0xff \n"), 255);
t("Number 0x junk", isNaN(Number("0xfg")), true);
t("Number 0x empty", isNaN(Number("0x")), true);
t("Number 0b junk", isNaN(Number("0b12")), true);
t("Number 0o junk", isNaN(Number("0o8")), true);
t("Number signed hex", isNaN(Number("-0x10")), true);

print(pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("number_parse_long_digits failed");
