// Verbatim from https://rosettacode.org/wiki/Ackermann_function (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function ack(m, n) {
 return m === 0 ? n + 1 : ack(m - 1, n === 0  ? 1 : ack(m, n - 1));
}
