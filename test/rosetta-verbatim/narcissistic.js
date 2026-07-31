// Verbatim from https://rosettacode.org/wiki/Narcissistic_decimal_number (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function isNarc(x) {
    var str = x.toString(),
        i,
        sum = 0,
        l = str.length;
    if (x < 0) {
        return false;
    } else {
        for (i = 0; i < l; i++) {
            sum += Math.pow(str.charAt(i), l);
        }
    }
    return sum == x;
}
function main(){
    var n = []; 
    for (var x = 0, count = 0; count < 25; x++){
        if (isNarc(x)){
            n.push(x);
            count++;
        }
    }
    return n.join(' '); 
}
