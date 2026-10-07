// @jsx h
const h = (tag, props, ...kids) => ({ tag, props, kids });
const o = { Cmp: function Cmp() {}, k: 'v' };
export const cases = {
  thisTag: (function () { return <this.k />; }).call({ k: 'x' }),
  member: <o.Cmp />,
  lt: 1 < 2,
  // `>` and `=` in text and unknown entities stay as written
  text: <p>a > b = c &bogus; &#xZZ; &amp</p>,
  // a string attribute keeps its newline and does not process escapes
  attr: <a title="x\ny
z" />,
  braces: <p>{'}'}{"{"}</p>,
  adjacent: [<a/>, <b/>],
  // text, entities and comments inside an expression container
  comment: <p>{/* none */}{1 /* one */}</p>,
  crlf: <p>
    a
    b
  </p>,
  keyword: <label class="c" for="f" data-x-y="1" />,
  tail: <b/> + '',
};
