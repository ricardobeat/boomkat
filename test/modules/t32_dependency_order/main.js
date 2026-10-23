import { evaluations } from "./state.js";
import defer * as a from "./a.js";
import "./b.js";
import "./a.js";
import "./c.js";
import defer * as d from "./d.js";
import "./e.js";
import "./d.js";
import "./f.js";
import defer * as lazy from "./lazy.js";

// Eager upgrades move a and d later while preserving their request slots.
// The requests immediately following each upgrade share its evaluation order.
if (evaluations.join(",") !== "b,a,c,e,d,f") {
    throw new Error("dependency evaluation order: " + evaluations.join(","));
}
if (a.value !== "a" || d.value !== "d") {
    throw new Error("dependency request slots changed");
}
if (lazy.value !== "lazy" || evaluations.join(",") !== "b,a,c,e,d,f,lazy") {
    throw new Error("deferred evaluation order: " + evaluations.join(","));
}
print("dependency evaluation order: PASS");
