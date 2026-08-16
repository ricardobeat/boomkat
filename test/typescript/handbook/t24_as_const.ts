// as const: frozen literal types on arrays, objects, nested mixes, and the
// readonly-tuple result feeding indexed access.
const axis = ["x", "y", "z"] as const;
const settings = {
  retries: 3,
  labels: ["a", "b"] as const,
  nested: { on: true } as const,
} as const;
type Axis = (typeof axis)[number];
type Label = (typeof settings.labels)[number];
const a1: Axis = "z";
const l1: Label = "b";
console.log(axis.join(""), axis.length, a1, l1);
console.log(settings.retries, settings.labels[1], settings.nested.on);
console.log(Object.isFrozen(axis), Object.isFrozen(settings));
