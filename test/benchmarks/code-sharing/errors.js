var count = 0;
var symbol = Symbol();
var invalid = Object.create(null);
for (var i = 0; i < 50000; i++) {
    try { +symbol; } catch (e) { if (e instanceof TypeError) count++; }
    try { +invalid; } catch (e) { if (e instanceof TypeError) count++; }
    try { with (null) {} } catch (e) { if (e instanceof TypeError) count++; }
}
print(count);
