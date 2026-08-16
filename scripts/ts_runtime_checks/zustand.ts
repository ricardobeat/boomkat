import { createStore } from "./zustand_vanilla.ts";

const store = createStore<{ count: number; items: string[] }>((set) => ({
  count: 0,
  items: [],
}));
const log: string[] = [];
store.subscribe((s) => log.push(`count=${s.count} items=${s.items.length}`));
log.push(`init=${store.getState().count}`);
store.setState({ count: 5, items: ["a"] });
store.setState((s) => ({ count: s.count + 2, items: [...s.items, "b"] }));
log.push(`final=${JSON.stringify(store.getState())}`);
const unsub = store.subscribe(() => {});
unsub();
store.setState({ count: 99, items: [] });
log.push(`after-unsub=${log.length}`);
for (const l of log) console.log(l);
