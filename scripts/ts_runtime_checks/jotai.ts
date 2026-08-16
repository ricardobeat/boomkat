import { atom } from "./jotai/src/vanilla/atom.ts";
import { createStore } from "./jotai/src/vanilla/store.ts";

const log: string[] = [];
const store = createStore();
const countAtom = atom(0);
const doubleAtom = atom((get) => get(countAtom) * 2);
const sumAtom = atom((get) => get(countAtom) + get(doubleAtom));

log.push("init=" + store.get(countAtom));
store.sub(countAtom, () => log.push("sub count=" + store.get(countAtom)));
store.sub(sumAtom, () => log.push("sub sum=" + store.get(sumAtom)));
store.set(countAtom, 1);
store.set(countAtom, 2);
log.push("double=" + store.get(doubleAtom));
log.push("sum=" + store.get(sumAtom));

// writable derived atom
const stepAtom = atom(10);
const incBy = atom(
  null,
  (get, set, by: number) => {
    set(stepAtom, get(stepAtom) + by);
  },
);
store.set(stepAtom, 1);
store.set(incBy, 5);
log.push("step=" + store.get(stepAtom));

// a computed-from-two atoms updates when either input changes
const a = atom("x");
const b = atom("y");
const combo = atom((get) => get(a) + get(b));
store.set(a, "p");
store.set(b, "q");
log.push("combo=" + store.get(combo));

// unsubscribing stops notifications
const unsub = store.sub(countAtom, () => log.push("again"));
unsub();
store.set(countAtom, 99);
log.push("final=" + store.get(countAtom) + " sum=" + store.get(sumAtom));

for (const line of log) console.log(line);
