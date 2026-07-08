// Basic TypeScript type stripping smoke test.
let x: number = 42;
let name: string = "world";

function greet(who: string, times: number = 1): string {
    let out: string = "";
    for (let i: number = 0; i < times; i++) {
        out = out + "hello " + who + " ";
    }
    return out;
}

print(greet(name, 2));
print(x);
