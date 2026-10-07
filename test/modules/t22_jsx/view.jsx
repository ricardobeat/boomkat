// Default classic runtime: React.createElement / React.Fragment.
export const React = {
  createElement: (type, props, ...children) => ({ type, props, children }),
  Fragment: 'Fragment',
};
function Comp() {}
export const cases = {
  empty: <div/>,
  attrs: <a href="x" b data-id={1 + 1} {...{ c: 3 }} d='q"q' />,
  text: <p>
    first line
    second   line
  </p>,
  entities: <i title="&lt;&amp;&#65;">&nbsp;&#x42;&gt;</i>,
  nested: <ul><li>{1}</li>{[2]}{/* comment */}<li/></ul>,
  component: <Comp k="v" />,
  member: <React.Fragment x="1"/>,
  fragment: <>a<b/></>,
  expr_after: <b/> ? 1 : 2,
};
