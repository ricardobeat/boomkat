import { signal, computed, effect, batch, untracked } from "./signals_core.ts";

const log: string[] = [];
const count = signal(0);
const doubled = computed(() => count.value * 2);
const quad = computed(() => doubled.value * 2);

effect(() => log.push(`eff: count=${count.value} doubled=${doubled.value}`));

count.value = 1;
count.value = 2;
batch(() => {
  count.value = 3;
  count.value = 4;
});
log.push(`quad=${quad.value}`);
log.push(`peek=${count.peek()} untracked=${untracked(() => count.value)}`);
count.value = 5;
const msg = signal("hi");
effect(() => log.push(`msg=${msg.value}`));
msg.value = msg.peek() + "!";
batch(() => {
  msg.value = "batched";
  msg.value = "final";
});
// conditional effect: reruns when the condition flips
const flag = signal(false);
const dep = signal("a");
let runs = 0;
effect(() => {
  runs++;
  if (flag.value) log.push(`branch=${dep.value} run=${runs}`);
});
flag.value = true;
dep.value = "b";
// diamond graph updates once
const src = signal(1);
const l = computed(() => src.value + 1);
const r = computed(() => src.value * 10);
const sum = computed(() => l.value + r.value);
let sumRuns = 0;
effect(() => { const _ = sum.value; sumRuns++; });
src.value = 2;
log.push(`sum=${sum.value} sumRuns=${sumRuns}`);
for (const line of log) console.log(line);
