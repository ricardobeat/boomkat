// Erased multiline types leave bytecode coordinates in the original TS file.
interface Shape {
    value: number;
}
type Result<T> = {
    field: T;
};
function checkFrame(stack: string, frame: number, line: number, column: number): void {
    const actual = stack.split('\n')[frame + 1];
    const suffix = ':' + line + ':' + column + ')';
    if (!actual || actual.slice(-suffix.length) !== suffix) {
        throw new Error('Expected ' + suffix + ', got ' + actual);
    }
}
function leaf<T>(value: {
    field: T;
}): Error {
    return new Error('typed');
}
function caller(): Error {
    return [leaf<Shape>(
        { field: { value: 42 as number } } satisfies Result<Shape> as any
    )][0];
}
const error: Error = caller();
checkFrame(error.stack, 0, 18, 12);
checkFrame(error.stack, 1, 21, 13);
function propertyError(value: Shape | null): number {
    return value!.value;
}
try { propertyError(null); } catch (e: unknown) {
    checkFrame((e as Error).stack, 0, 29, 19);
}
print('PASS: TS stack source columns');
