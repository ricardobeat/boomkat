// Dependency module for t35: exported types plus one runtime value.
export type Token = { kind: string };
export type Pair<A, B> = [A, B];
export interface Cfg {
  retries: number;
}
export type Hidden = string;
export function makePair<A, B>(a: A, b: B): [A, B] {
  return [a, b];
}
