// Repeated fresh arrays with heap-valued appends, matching retained scene data.
var ARRAYS = 3000;
var ITEMS_PER_ARRAY = 400;
var item = { value: 17 };
var checksum = 0;
var start = Date.now();
for (var a = 0; a < ARRAYS; a++) {
    var values = [];
    for (var i = 0; i < ITEMS_PER_ARRAY; i++) values.push(item);
    if (values.length !== ITEMS_PER_ARRAY || values[0] !== item
        || values[ITEMS_PER_ARRAY - 1] !== item) {
        throw new Error("object push probe contents");
    }
    checksum += values.length;
}
print("object_push_probe: arrays=" + ARRAYS + " each=" + ITEMS_PER_ARRAY
      + " total=" + (Date.now() - start) + "ms checksum=" + checksum);
