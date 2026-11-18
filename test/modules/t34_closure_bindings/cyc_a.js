import { readB } from "./cyc_b.js";
export let aValue = "a0";
export function setA(v) { aValue = v; }
export function readBFromA() { return readB(); }
