// Drives json.js -- uses: data sample json_string
assertEq(data.foo, 1, "parsed number member");
assertEq(data.bar.length, 2, "parsed array length");
assertEq(data.bar[0], 10, "parsed array number");
assertEq(data.bar[1], "apples", "parsed array string");
assertEq(json_string, '{"blue":[1,2],"ocean":"water"}', "stringify output");
assertEq(JSON.parse(json_string).ocean, sample.ocean, "round trip");
report("json");
