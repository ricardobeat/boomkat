var JSZip = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

var zip = new JSZip();
zip.file("hello.txt", "Hello, world!");
zip.folder("sub").file("nested.txt", "nested content");

rec("file_count", Object.keys(zip.files).length);
rec("file_name_present", "hello.txt" in zip.files);
rec("nested_present", "sub/nested.txt" in zip.files);
rec("file_data_present", zip.file("hello.txt")._data !== undefined && zip.file("hello.txt")._data !== null);

console.log(lines.join("\n"));
console.log(lines.length + " jszip API checks recorded, 0 threw");
