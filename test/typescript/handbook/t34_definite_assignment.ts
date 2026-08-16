// Definite assignment assertions (`let x!: T`): a binding initialized
// later in a function body, after a constructor call, and through a helper.
let late!: number;
function initialize(): void {
  late = 41;
}
initialize();
class Ready {
  value!: string;
  ready = false;
  prepare(): void {
    this.value = "set";
    this.ready = true;
  }
}
const r = new Ready();
r.prepare();
let filled!: boolean;
function fillIt(): boolean {
  filled = true;
  return filled;
}
console.log(late + 1, r.value, r.ready, fillIt());
