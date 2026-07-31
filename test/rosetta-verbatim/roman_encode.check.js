// Drives roman_encode.js -- uses: roman

assert(typeof roman === "object" && roman !== null, "sample did not export roman");
assertEq(roman.int_to_roman(1), "I", "1");
assertEq(roman.int_to_roman(4), "IV", "4");
assertEq(roman.int_to_roman(1990), "MCMXC", "1990");
assertEq(roman.int_to_roman(1999), "MCMXCIX", "1999");
assertEq(roman.int_to_roman(2008), "MMVIII", "2008");
report("roman_encode");
