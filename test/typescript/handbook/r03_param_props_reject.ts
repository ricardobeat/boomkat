// Parameter properties (constructor(private x) and friends) generate
// assignments, so they are not erasable: the compiler must reject them
// (tsc: TS1294).
class Account {
  constructor(
    public id: number,
    private secret: string,
    readonly tag = "acct",
  ) {}
  reveal(): string {
    return this.id + this.secret + this.tag;
  }
}
console.log(new Account(1, "s").reveal());
