const make = (many, from) => (type, props, key) => ({ from, many, type, props, key });
export const jsx = make(false, 'alt');
export const jsxs = make(true, 'alt');
export const Fragment = 'Fragment';
