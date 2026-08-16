import { proxy, snapshot, subscribe } from "./valtio_vanilla.ts";

const state: any = proxy({ count: 0, nested: { list: [] as string[], flag: true } });
const log: string[] = [];
subscribe(state, () => log.push(`notify count=${state.count} list=${state.nested.list.join(",")}`));
state.count = 1;
state.nested.list.push("x");
log.push(`snap=${JSON.stringify(snapshot(state))}`);
state.count = 2;
delete state.nested.flag;
log.push(`snap2=${JSON.stringify(snapshot(state))}`);
const arr: any = proxy([1, 2, 3]);
arr.push(4);
arr[1] = 99;
log.push(`arrsnap=${JSON.stringify(snapshot(arr))}`);
for (const l of log) console.log(l);
