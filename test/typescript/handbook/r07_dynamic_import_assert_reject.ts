// TypeScript 7 rejects an `assert` key in import() options too (TS2880).
const data = await import("./t35_dep.ts", { assert: { type: "json" } });
console.log(data);
