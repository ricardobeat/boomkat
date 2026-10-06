function run(n) {
    let sum=0;
    const peek=()=>sum;
    for(let i=0;i<n;i++) { sum=peek()+i; }
    return sum;
}
if(run(3000000)!==4499998500000) throw new Error('capture sum mismatch');
console.log('captured numeric OK');
