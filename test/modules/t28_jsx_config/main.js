import out from './view.jsx';
import near from './nearer/view.jsx';
if (out[0] !== 'a|{"x":"1"}|t') throw new Error(out[0]);
if (out[1] !== 'F|null|1') throw new Error(out[1]);
if (near !== 'near:a') throw new Error(near);
