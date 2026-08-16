// Template literal types: string placeholders, unions expanding into the
// literal set, intrinsic string manipulation types as upper bounds, and a
// mapped type built from them.
type Greet = `hello ${string}`;
type Axis = "x" | "y";
type Vec = `${Axis}-${number}`;
type EventName<T extends string> = `on${Capitalize<T>}`;
type Loose = `${string}${string}`;
type WithSuffix = `${Greet}!`;
const g: Greet = "hello world";
const v: Vec = "x-3";
const e: EventName<"click"> = "onClick";
const l: Loose = "anything";
const w: WithSuffix = "hello there!";
type Handlers = { [K in EventName<Axis>]?: () => string };
const h: Handlers = { onX: () => "x!" };
console.log(g, v, e, l, w, h.onX?.());
