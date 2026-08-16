// Type aliases for objects, unions, arrays, functions, and a multi-line
// alias body (every `?`/`|` continues across the line break).
type User = {
  readonly id: number;
  name: string;
  tags: string[];
};
type Id = string | number;
type Handler = (event: string) => boolean;
type Lookup = Record<string, number>;
const u: User = { id: 1, name: "ann", tags: ["admin", "dev"] };
const key: Id = 42;
const h: Handler = (e) => e.length > 1;
const table: Lookup = { a: 1, b: 2 };
console.log(u.name, u.tags.join("+"), key, h("xy"), h("x"));
console.log(table.a + table.b);
