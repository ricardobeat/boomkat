// Verify that runtime errors point at the .ts source location, not
// some offset shifted by the stripped annotations.
function boom(x: number): number {
    throw new Error("BOOM@line5");
}
try {
    boom(42 as number);
} catch (e) {
    print((e as Error).message);
}
