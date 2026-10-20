var d = new Date(1600000000000), sum = 0;
for (var i = 0; i < 5000; i++) {
    sum += d.setMilliseconds(7) % 1000;
    sum += d.setUTCSeconds(12,8) % 1000;
    sum += d.setMinutes(20,13,9) % 1000;
    sum += d.setUTCHours(12,21,14,10) % 1000;
}
print(sum);
