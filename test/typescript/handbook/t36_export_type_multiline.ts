// export type with multi-line generic parameters (the zustand StateCreator
// shape): each parameter on its own line, constraints with defaults, a
// multi-line conditional body, and runtime declarations following the alias.
type StoreMutatorIdentifier = keyof {
  persist: 1;
  devtools: 1;
};
export type Mutate<S, Ms> = number extends Ms["length"]
  ? S
  : Ms extends []
    ? S
    : Ms extends [[infer Mi, infer Ma], ...infer Mrs]
      ? Mutate<Ma, Mrs>
      : never;
export type StateCreator<
  T,
  Mis extends [StoreMutatorIdentifier, unknown][] = [],
  Mos extends [StoreMutatorIdentifier, unknown][] = [],
  U = T,
> = (
  setState: (partial: T | ((state: T) => T)) => void,
  getState: () => T,
) => U;
type ExtractState<S> = S extends { getState: () => infer R } ? R : never;
export function create<T>(
  initializer: StateCreator<T, [], []>,
): { getState: () => T; setState: (p: T | ((s: T) => T)) => void } {
  const setState = (partial: T | ((s: T) => T)) => {
    state = typeof partial === "function" ? (partial as (s: T) => T)(state) : partial;
  };
  const getState = (): T => state;
  let state: T = initializer(setState, getState);
  return { getState, setState };
}
const store = create<{ count: number; items: string[] }>((set) => {
  return { count: 1, items: [] };
});
store.setState((s) => ({ ...s, count: s.count + 6, items: [...s.items, "a"] }));
console.log(JSON.stringify(store.getState()));
