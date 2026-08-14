var protobuf = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

var root = new protobuf.Root();
var Message = new protobuf.Type("Msg").add(new protobuf.Field("name", 1, "string"));
root.add(Message);
var Msg = root.lookupType("Msg");

var payload = Msg.create({ name: "hello" });
var buf = Msg.encode(payload).finish();
var decoded = Msg.decode(buf);

rec("roundtrip_name", decoded.name);
rec("buffer_nonempty", buf.length > 0);

console.log(lines.join("\n"));
console.log(lines.length + " protobufjs API checks recorded, 0 threw");
