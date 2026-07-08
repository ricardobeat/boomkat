function sum(first: number, ...rest: number[]): number {
    let total = first;
    for (let i = 0; i < rest.length; i++) total += rest[i];
    return total;
}
print(sum(1, 2, 3, 4));
