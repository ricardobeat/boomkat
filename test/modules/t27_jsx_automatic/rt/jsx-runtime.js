const make = (many, from) => (type, props, key) => ({ from, many, type, props, key });
export const jsx = make(false, 'rt');
export const jsxs = make(true, 'rt');
export const Fragment = 'Fragment';
