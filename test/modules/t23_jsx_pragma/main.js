import { out } from './view.jsx';
if (out[0] !== 'a|{"x":"1"}|hi') throw new Error(out[0]);
if (out[1] !== 'F|null|1,b|null|') throw new Error(out[1]);
