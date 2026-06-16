function test(w, h) {
    var arr = [];
    for (var i = 0; i < w * h; i++) arr[i] = 0;
    console.log("w=" + w + " h=" + h + " len=" + arr.length + " arr[0]=" + arr[0] + " arr[1]=" + arr[1]);
}
test(2, 3);
test(4, 5);
test(3, 3);
