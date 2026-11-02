// A TypeScript script is strict code even without a "use strict" prologue, as
// TypeScript 6 and later assume for all code.
function self(this: unknown): unknown { return this; }
function aliased(a: number): number {
    a = 2;
    return arguments[0];
}
print(self() === undefined, aliased(1));
