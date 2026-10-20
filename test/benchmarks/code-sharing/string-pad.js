var sum = 0;
for (var i = 0; i < 300000; i++) {
    sum += 'abc'.padStart(24,'xy').length;
    sum += 'abc'.padEnd(24,'xy').length;
}
print(sum);
