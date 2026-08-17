import { z } from "./zod/src/index.ts";

const log: string[] = [];

// string with a minimum length
const name = z.string().min(3);
log.push("name=" + name.parse("hello"));
const r1 = name.safeParse("ab");
log.push("fail=" + (r1.success ? "ok" : r1.error.issues.map((i) => i.message).join("|")));

// object with default and optional fields
const person = z.object({
  name: z.string().min(2),
  age: z.number().int().positive(),
  tags: z.array(z.string()).optional().default([]),
});
log.push("p=" + JSON.stringify(person.parse({ name: "Ann", age: 30 })));
log.push("p2=" + JSON.stringify(person.parse({ name: "Bo", age: 41, tags: ["x", "y"] })));
const r2 = person.safeParse({ name: "A", age: -3 });
log.push("r2=" + (r2.success ? "ok" : r2.error.issues.map((i) => i.path.join(".") + ":" + i.message).join("|")));

// enum
const color = z.enum(["red", "green", "blue"]);
log.push("color=" + color.parse("green"));

// union dispatches on the value
const num = z.union([z.string(), z.number()]);
log.push("union=" + num.parse(42) + "/" + num.parse("s"));

// refinement
const even = z.number().refine((n) => n % 2 === 0, { message: "even required" });
log.push("even=" + even.parse(4));
const r3 = even.safeParse(3);
log.push("odd=" + (r3.success ? "ok" : r3.error.issues.map((i) => i.message).join("|")));

// array of objects with a transform
const rows = z.array(z.object({ id: z.number(), v: z.string() })).transform((xs) => xs.map((x) => x.id).join("-"));
log.push("rows=" + rows.parse([{ id: 2, v: "a" }, { id: 5, v: "b" }]));

// instanceof-style: errors carry the schema name
const r4 = z.number().safeParse("nope");
log.push("type=" + (r4.success ? "ok" : r4.error.issues.map((i) => i.code).join("|")));

for (const line of log) console.log(line);