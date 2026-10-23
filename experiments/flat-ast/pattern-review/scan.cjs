// Static syntax inventory, not a profile or proof of optimization eligibility.
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const acorn = require(process.env.ACORN_PATH || '/Users/rtomasi/.local/share/mise/installs/node/24.13.0/lib/node_modules/eas-cli/node_modules/acorn/dist/acorn.js');
const root = process.argv[2] || '/Users/rtomasi/cousas/boomkat/.worktrees/octane/bench/mini';
const output = [];
const inputs = fs.readdirSync(root).filter(x => x.endsWith('.js')).sort().map(file=>({file,source:fs.readFileSync(path.join(root,file),'utf8'),minimumLine:430}));
for (const input of inputs) {
  const {file,source,minimumLine}=input;
  const tree = acorn.parse(source,{ecmaVersion:'latest',locations:true,allowReturnOutsideFunction:true});
  const counts = {}, examples = {}, decls = {var:0,let:0,const:0};
  let nodes=0;
  function record(kind,node,fn) {
    counts[kind]=(counts[kind]||0)+1;
    (examples[kind] ||= []);
    if (examples[kind].length < 14) examples[kind].push({line:node.loc.start.line,function:fn,source:source.slice(node.start,node.end).replace(/\s+/g,' ').slice(0,250)});
  }
  function label(n,parent,fn) {
    if(n.id) return n.id.name;
    if(parent?.type==='AssignmentExpression') return source.slice(parent.left.start,parent.left.end);
    if(parent?.type==='VariableDeclarator') return source.slice(parent.id.start,parent.id.end);
    if(parent?.type==='Property') return source.slice(parent.key.start,parent.key.end);
    return fn+'::<anonymous@'+n.loc.start.line+'>';
  }
  function walk(n,parent=null,fn='<top>') {
    if(!n||typeof n.type!=='string')return;
    nodes++;
    if (n.type==='Literal' && typeof n.value==='string' && n.value.length>1000 && minimumLine!==0) {
      const name=parent?.type==='VariableDeclarator'?parent.id.name:parent?.type==='CallExpression'&&parent.callee.type==='Identifier'?parent.callee.name:null;
      if(['BASE_JS','JQUERY_JS','zlibEval'].includes(name)) {
        inputs.push({file:file+'::'+name+'@'+n.loc.start.line,source:n.value,minimumLine:0});
      }
    }
    if(/Function/.test(n.type))fn=label(n,parent,fn);
    // Every input repeats base.js. Exclude its first 430 lines from counts.
    if(n.loc.start.line>minimumLine) {
      if(n.type==='VariableDeclaration') decls[n.kind]+=n.declarations.length;
      if(n.type==='BinaryExpression') {
        if(['|','&','^','<<','>>','>>>'].includes(n.operator))record('bitwise',n,fn);
        if(n.operator==='|'&&n.right.type==='Literal'&&n.right.value===0)record('or_zero',n,fn);
        if(n.operator==='>>>'&&n.right.type==='Literal'&&n.right.value===0)record('unsigned_zero',n,fn);
        if(n.operator==='|'&&n.left.type==='BinaryExpression'&&n.right.type==='BinaryExpression'&&['<<','>>>'].includes(n.left.operator)&&['<<','>>>'].includes(n.right.operator))record('rotate_candidate',n,fn);
        if(['+','-','*','/'].includes(n.operator))record('arithmetic',n,fn);
      }
      if(n.type==='MemberExpression') {
        if(n.computed) {
          record('index',n,fn);
          if(n.property.type==='BinaryExpression'&&['>>','>>>'].includes(n.property.operator))record('shifted_index',n,fn);
        } else if(n.property.name==='length') record('length',n,fn);
        else if(n.object.type==='MemberExpression')record('property_chain',n,fn);
      }
      if(n.type==='AssignmentExpression'&&n.left.type==='MemberExpression')record('member_store',n,fn);
      if(n.type==='AssignmentExpression'&&n.operator!=='=')record('compound_assign',n,fn);
      if(n.type==='UpdateExpression'&&n.argument.type==='MemberExpression')record('member_update',n,fn);
      if(n.type==='CallExpression') {
        if(n.callee.type==='MemberExpression') {
          record('method_call',n,fn);
          if(n.callee.object.type==='Identifier'&&n.callee.object.name==='Math')record('math_call',n,fn);
          if(!n.callee.computed&&['charCodeAt','charAt','substring','substr','slice','indexOf','exec','test','replace','push','pop'].includes(n.callee.property.name))record('call_'+n.callee.property.name,n,fn);
        }
        if(n.callee.type==='Identifier'&&n.callee.name==='eval')record('eval',n,fn);
      }
      if(n.type==='NewExpression') record('new',n,fn);
      if(n.type==='SwitchStatement') {
        record('switch',n,fn);
        const values=n.cases.filter(c=>c.test?.type==='Literal'&&Number.isInteger(c.test.value)).map(c=>c.test.value);
        if(values.length>=4)record('integer_switch',n,fn);
      }
      if(['ForStatement','WhileStatement','DoWhileStatement'].includes(n.type))record('loop',n,fn);
      if(n.type==='LogicalExpression')record('logical',n,fn);
    }
    for(const [k,v] of Object.entries(n)) {
      if(k==='loc')continue;
      if(Array.isArray(v)) for(const x of v) {if(x&&typeof x.type==='string')walk(x,n,fn);}
      else if(v&&typeof v.type==='string')walk(v,n,fn);
    }
  }
  walk(tree);
  output.push({file,sha256:crypto.createHash('sha256').update(source).digest('hex'),bytes:Buffer.byteLength(source),nodes,declarations_after_line_430:decls,counts,examples});
}
console.log(JSON.stringify(output,null,2));
