// Inline object types: optional properties, readonly properties, method
// shorthand in the type, and a function taking an object parameter.
function draw(pt: { x: number; y: number; label?: string }) {
  return (pt.label ?? "dot") + "@" + pt.x + "," + pt.y;
}
const config: { readonly id: number; flags: { on: boolean } } = {
  id: 3,
  flags: { on: true },
};
type Op = { run(input: string): string };
const up: Op = { run: (s) => s.toUpperCase() };
console.log(draw({ x: 1, y: 2 }), draw({ x: 3, y: 4, label: "here" }));
console.log(config.id, config.flags.on, up.run("abc"));
