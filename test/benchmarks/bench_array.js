// Array operations benchmark
var N = 50000;
var arr = [];
var i;

// Array push
for (i = 0; i < N; i++) {
    arr.push(i);
}

// Array index access
var sum = 0;
for (i = 0; i < N; i++) {
    sum += arr[i];
}

// Array pop
for (i = 0; i < N; i++) {
    arr.pop();
}

// Array set length
var arr2 = [];
for (i = 0; i < N; i++) {
    arr2[i] = i * 2;
}

print(sum);
