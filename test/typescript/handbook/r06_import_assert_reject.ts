// Import assertions were replaced by import attributes (TS2880): `with`, not
// `assert`.
import data from "./t35_dep.ts" assert { type: "json" };
console.log(data);
