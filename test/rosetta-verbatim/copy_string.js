// Verbatim from https://rosettacode.org/wiki/Copy_a_string (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
var container = {myString: "Hello"};
var containerCopy = container; // Now both identifiers refer to the same object

containerCopy.myString = "Goodbye"; // container.myString will also return "Goodbye"
