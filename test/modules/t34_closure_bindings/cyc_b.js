import { aValue } from "./cyc_a.js";
export let bValue = "b0";
export function readB() { return aValue + "/" + bValue; }
export function setB(v) { bValue = v; }
