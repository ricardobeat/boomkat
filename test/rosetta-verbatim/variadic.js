// Verbatim from https://rosettacode.org/wiki/Variadic_function (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function printAll() {
  for (var i=0; i<arguments.length; i++)
    print(arguments[i])
}
printAll(4, 3, 5, 6, 4, 3);
printAll(4, 3, 5);
printAll("Rosetta", "Code", "Is", "Awesome!");
