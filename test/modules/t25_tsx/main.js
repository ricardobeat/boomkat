import { list, ns, cast, frag } from './view.tsx';
const eq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(m + ': ' + JSON.stringify(a)); };
eq(list.tag, 'ul', 'tag'); eq(list.props, null, 'props'); eq(list.kids.length, 2, 'spread children');
eq(list.kids[1].tag.name, 'Item', 'component passed by reference');
eq(list.kids[1].props, { id: 2, label: 'n2' }, 'component props');
eq(ns, { tag: 'svg:path', props: { 'a:b': '1' }, kids: [] }, 'namespaced names');
eq(cast.props, { title: '1' }, 'as in attribute');
eq(frag, { tag: 'F', props: null, kids: [{ tag: 'i', props: null, kids: [] }, 'x'] }, 'fragment');
