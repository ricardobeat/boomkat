import { type Something } from "./nowhere";
type Erased = number;
export type { Erased };
print((2 as number) + 3);
function value(): number { return 7; }
print((value as () => number)());
const increment = (x: number): number => x + 1;
print(increment(4));
class Outer {
    static public<T>(): number { return 6; }
}
print(Outer.public<string>());
