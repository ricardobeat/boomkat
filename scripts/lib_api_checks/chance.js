var Chance = module.exports;
var chance = new Chance(12345);
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("integer_in_range", (function () {
    var n = chance.integer({ min: 1, max: 10 });
    return n >= 1 && n <= 10;
})());
rec("string_type", typeof chance.string());
rec("bool_type", typeof chance.bool());
rec("email_has_at", chance.email().indexOf("@") > -1);
rec("guid_format", /^[0-9a-f-]{36}$/.test(chance.guid()));

console.log(lines.join("\n"));
console.log(lines.length + " chance API checks recorded, 0 threw");
