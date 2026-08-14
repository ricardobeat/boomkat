var moment = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("format", moment.utc([2020, 0, 1]).format("YYYY-MM-DD"));
rec("add", moment.utc([2020, 0, 1]).add(1, "month").format("YYYY-MM-DD"));
rec("diff_days", moment.utc([2020, 0, 10]).diff(moment.utc([2020, 0, 1]), "days"));
rec("duration_hours", moment.duration(90, "minutes").asHours());
rec("isValid", moment.utc("not-a-date").isValid());
rec("isValid_ok", moment.utc([2020, 0, 1]).isValid());

console.log(lines.join("\n"));
console.log(lines.length + " moment API checks recorded, 0 threw");
