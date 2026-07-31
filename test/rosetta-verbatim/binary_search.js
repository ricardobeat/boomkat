// Verbatim from https://rosettacode.org/wiki/Binary_search (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function binary_search_recursive(a, value, lo, hi) {
  if (hi < lo) { return null; }

  var mid = Math.floor((lo + hi) / 2);

  if (a[mid] > value) {
    return binary_search_recursive(a, value, lo, mid - 1);
  }
  if (a[mid] < value) {
    return binary_search_recursive(a, value, mid + 1, hi);
  }
  return mid;
}
