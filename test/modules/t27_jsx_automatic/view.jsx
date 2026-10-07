const kids = [1, 2];
export const cases = {
  bare: <div />,
  one: <a href="x">hi</a>,
  many: <ul key="k"><li /><li /></ul>,
  spread: <p {...{ a: 1 }} b>{...kids}</p>,
  fragment: <>x</>,
  nested: <a>{<b />}</a>,
  keyBool: <i key />,
  keyAfterSpread: <p {...{ k: 1 }} key="a">t</p>,
  keyBeforeSpread: <p key="a" {...{ k: 1 }} />,
};
