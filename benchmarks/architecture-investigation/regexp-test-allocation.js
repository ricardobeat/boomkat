var re = /([a-z]+)@(\w+\.\w+)/;
var input = 'user@example.com';
var matches = 0;
for (var i = 0; i < 20000; i++) {
    if (re.test(input)) matches++;
}
print('CHECK ' + matches);
