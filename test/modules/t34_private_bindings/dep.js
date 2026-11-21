import { live, bumpLive } from './main.js';
export function readLive() { return live; }
export function bumpFromDep() { bumpLive(); return live; }
