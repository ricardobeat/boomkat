// Runtime namespaces are not erasable syntax: the compiler must reject them
// in ts_mode (tsc: TS1294). Type-only `declare namespace` is fine and is
// covered by t33_declare.
namespace Util {
  export function twice(n: number): number {
    return n * 2;
  }
}
console.log(Util.twice(3));
