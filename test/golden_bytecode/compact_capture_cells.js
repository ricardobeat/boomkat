function make(value) {
    var captured = value;
    return {
        read: function () { return captured; },
        write: function (next) { captured = next; }
    };
}

var pair = make(3);
pair.write(9);
print(pair.read());
