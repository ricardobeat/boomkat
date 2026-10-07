export const createElement = (type, props, ...kids) => ({ from: 'rt', create: true, type, props, kids });
