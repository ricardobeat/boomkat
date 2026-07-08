// Full erasable-subset smoke test.
interface Point { x: number; y: number; }
type Vec = { dx: number; dy: number };

let raw: unknown = "hello" as string;
let s: string = raw as string;
let arr: number[] = [1, 2, 3] satisfies number[];
let n: number = arr[0]!;

print(s);
print(n);
print(arr.length);

function tag(x: number | string, mode: "on" | "off" = "on"): string {
    return mode + ":" + x;
}
print(tag(42));
print(tag("x", "off"));
