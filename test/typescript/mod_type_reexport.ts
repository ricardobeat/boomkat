// A local export of a type-only import names a type: TypeScript drops it from
// its output, and so does the engine.
import type { Label, Shape as S } from "./mod_types";
import type * as Types from "./mod_types";
import { type Shape, square } from "./mod_types";
export { Label, S, Types, Shape };
const l: Label = "box";
const t: Types.Shape = square;
print(l, t.sides);
