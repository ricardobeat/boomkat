// Loop overhead benchmark
var N = 5000000;
var sum = 0;
var i = 0;

// for loop
for (i = 0; i < N; i++) {
    sum += 1;
}

// while loop
i = 0;
while (i < N) {
    sum += 1;
    i++;
}

print(sum);
