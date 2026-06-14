// Abstract equality (==) — TinyDuck rules:
//   === / !==  — strict, no coercion
//   == / !=    — only null/undefined coalesce; everything else requires ===
// See tinyduck.md "Equality".
var pass = 0;
var fail = 0;

// Same type — same as strict
if (1 == 1) { pass = pass + 1; } else { fail = fail + 1; }
if ("a" == "a") { pass = pass + 1; } else { fail = fail + 1; }
if (true == true) { pass = pass + 1; } else { fail = fail + 1; }
if (null == null) { pass = pass + 1; } else { fail = fail + 1; }
if (undefined == undefined) { pass = pass + 1; } else { fail = fail + 1; }

// Different type — false (TinyDuck does not coerce)
if (1 == "1") { fail = fail + 1; } else { pass = pass + 1; }
if (0 == "") { fail = fail + 1; } else { pass = pass + 1; }
if (0 == false) { fail = fail + 1; } else { pass = pass + 1; }
if (1 == true) { fail = fail + 1; } else { pass = pass + 1; }
if (true == "1") { fail = fail + 1; } else { pass = pass + 1; }
if (255 == "0xFF") { fail = fail + 1; } else { pass = pass + 1; }

// null / undefined coalesce, but only with each other
if (null == undefined) { pass = pass + 1; } else { fail = fail + 1; }
if (undefined == null) { pass = pass + 1; } else { fail = fail + 1; }
if (null == 0) { fail = fail + 1; } else { pass = pass + 1; }
if (undefined == "") { fail = fail + 1; } else { pass = pass + 1; }
if (undefined == 0) { fail = fail + 1; } else { pass = pass + 1; }

// != mirrors the same rules
if (1 != "1") { pass = pass + 1; } else { fail = fail + 1; }
if (null != undefined) { fail = fail + 1; } else { pass = pass + 1; }
if (1 != 2) { pass = pass + 1; } else { fail = fail + 1; }

// Use === / !== for cross-type comparisons
if (1 !== "1") { pass = pass + 1; } else { fail = fail + 1; }
if (null === undefined) { fail = fail + 1; } else { pass = pass + 1; }

print("pass:", pass, "fail:", fail);
