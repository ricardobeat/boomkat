// @jsx h
// @jsxFrag Frag
type Props = { id: number; label?: string };
interface Node { tag: unknown; props: Record<string, unknown> | null; kids: unknown[] }
export const h = (tag: unknown, props: Record<string, unknown> | null, ...kids: unknown[]): Node => ({ tag, props, kids });
export const Frag = 'F';
function Item(p: Props): Node { return <li id={p.id as unknown as string}>{p.label ?? 'none'}</li>; }
const items: Node[] = [1, 2].map((id: number) => <Item id={id} label={`n${id}`} />);
export const list = <ul>{...items}</ul>;
export const ns = <svg : path a:b="1"></svg : path>;
export const cast = <div title={(1 as number).toString()} />;
export const frag = <><i/>{'x' satisfies string}</>;
