import { f, g, h } from './asi.js'

console.log('f=' + f())
console.log('g=' + g())
h().then((v) => console.log('h=' + v))
