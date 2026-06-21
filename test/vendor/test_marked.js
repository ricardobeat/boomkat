import {marked} from './marked.js';

var __pass = 0;
var __fail = 0;

function assert_eq(actual, expected, msg) {
  if (actual === expected) { __pass++; return; }
  __fail++;
  var a = actual.length > 80 ? actual.slice(0, 80) + "..." : actual;
  var e = expected.length > 80 ? expected.slice(0, 80) + "..." : expected;
  print("  FAIL: " + msg);
}

function assert_contains(actual, substr, msg) {
  if (actual.indexOf(substr) !== -1) { __pass++; return; }
  __fail++;
  print("  FAIL: " + msg);
}

assert_eq(marked('# Hello'), '<h1 id="hello">Hello</h1>\n', 'heading 1');
assert_eq(marked('**bold**'), '<p><strong>bold</strong></p>\n', 'bold');
assert_eq(marked('*italic*'), '<p><em>italic</em></p>\n', 'italic');
assert_eq(marked('> quote'), '<blockquote>\n<p>quote</p>\n</blockquote>\n', 'blockquote');
assert_eq(marked('`code`'), '<p><code>code</code></p>\n', 'inline code');
assert_eq(marked('[link](http://x.com)'), '<p><a href="http://x.com">link</a></p>\n', 'link');
assert_contains(marked('---'), '<hr', 'hr');
assert_eq(marked('plain'), '<p>plain</p>\n', 'paragraph');
assert_eq(marked(''), '', 'empty');

print("marked: pass=" + __pass + " fail=" + __fail);
if (__fail > 0) { throw "MARKED TEST FAILED"; }
