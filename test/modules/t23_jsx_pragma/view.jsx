/** @jsx h
 *  @jsxFrag Frag
 */
export const h = (type, props, ...kids) => type + '|' + JSON.stringify(props) + '|' + kids.join(',');
export const Frag = 'F';
export const out = [<a x="1">hi</a>, <>1<b/></>];
