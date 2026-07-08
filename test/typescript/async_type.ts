async function fetchIt(x: number): Promise<number> {
    return x + 1;
}
fetchIt(41).then((v: number) => print(v));
