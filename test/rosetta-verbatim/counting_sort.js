// Verbatim from https://rosettacode.org/wiki/Sorting_algorithms/Counting_sort (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
var countSort = function(arr, min, max) {
    var i, z = 0, count = [];
    
    for (i = min; i <= max; i++) {
        count[i] = 0;
    }
    
    for (i=0; i < arr.length; i++) {
        count[arr[i]]++;
    }
    
    for (i = min; i <= max; i++) {
        while (count[i]-- > 0) {
            arr[z++] = i;
        }
    }
    
}
