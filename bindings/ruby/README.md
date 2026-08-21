# Ruby binding

Pure-Ruby binding to the `bk_` embedding ABI, built on the stdlib
[`fiddle`](https://docs.ruby-lang.org/en/master/Fiddle.html). It dlopens the
shared library and calls the symbols `include/boomkat.h` declares, including the
host-function entry points that let JS call Ruby. There is no native gem to
compile and no dependency on the `ffi` gem.

## Prerequisites

- Ruby 2.6 or newer with `fiddle`. The macOS system Ruby (`/usr/bin/ruby`,
  2.6.10) works as-is; `fiddle` ships with the stdlib. Check with `ruby -v` and
  `ruby -e "require 'fiddle'"`.
- A C3 compiler (`c3c` 0.8.2) to build the engine.

## Build

Build the shared library from the repository root:

```sh
make shared
```

That produces `out/boomkat.dylib` (macOS) or `out/boomkat.so` (Linux).

## Run

```sh
just example-ruby
```

Or directly:

```sh
ruby bindings/ruby/examples/example.rb
```

The binding finds the library by searching, in order:

1. `$BK_LIBRARY`, if set, for an installed or relocated build
2. `out/boomkat.{dylib,so}` relative to the repository root
3. the bare soname, letting the dynamic loader search system paths
   (works after `make install PREFIX=…`)

## Expected output

```
engine version: 0.1.0
sum of 1..5: 15
Math.hypot(3, 4): 5.0
greeting: hello from 😂
3 > 2: true, null: nil
slugify: hello-embedded-world
opaque: #<JS::Opaque object>
as JSON: {"a":1,"b":[2,3]}
caught: TypeError: Cannot read properties of null (reading 'property')
  js_class was "TypeError" -- branch on that, not the text
caught syntax error: expected '<identifier>', got '('
caught JS::Error (status -3): RangeError: out of range
caught: Error: boom
  js_class was "Error"
recovered: SyntaxError

hostAdd(40, 2): 42.0
as a callback: A! B!
tally called 3 times from JS
divide(10, 4): 2.5
JS caught TypeError: division by zero
percent(80): 80%
JS caught RangeError: 140 is out of range
twice(x => x * 3, 5): 45.0
mapPair: LEFT / RIGHT
propagated RangeError: from JS
runtime closed
```

and from `two_runtimes.rb`:

```
two runtimes open: #<JS::Runtime> #<JS::Runtime>
A.x=111, B.x=222
A has only_in_a: function
B has only_in_a: undefined
A.o.k199=199, B.o.k199=1990
A.s="alpha-A", B.s="alpha-B"
A: host on A, B: host on B
moved through Ruby: B.got="carried from A"
handle 458753: A reads "secret from A", B refused: handle 458753 is not held by this runtime
A closed: #<JS::Runtime (closed)>; B still works: B.x=222
both runtimes closed
```

## Usage

```ruby
$LOAD_PATH.unshift 'bindings/ruby/lib'
require 'js'

JS.open do |vm|
  vm.eval('[1, 2, 3].map(n => n * n).join(",")')   # => "1,4,9"
end
```

`JS.open` with a block closes the runtime on the way out, including when the
block raises. Without a block it returns the runtime and you call `#close`
yourself.

### Values

Source is evaluated for its completion value, like `eval()`, and converted:

| JavaScript              | Ruby                            |
| ----------------------- | ------------------------------- |
| number                  | `Float` (JS numbers are doubles)|
| string                  | `String` (UTF-8)                |
| boolean                 | `true` / `false`                |
| `null`, `undefined`     | `nil`                           |
| object, function, symbol| `JS::Opaque`                    |

`JS::Opaque` is a marker: an `#eval` result has no property accessors, so
serialise it in JS instead, as in `vm.eval('JSON.stringify(x)')`. Inside a host
function the same value arrives with its handle attached and can be passed back
to a JS callback that reads it.

Use `#exec` instead of `#eval` to run for side effects and skip the conversion.

### Errors

| Exception          | Raised when                                     |
| ------------------ | ----------------------------------------------- |
| `JS::SyntaxError`  | the source does not parse                       |
| `JS::ThrowError`   | JS threw and nothing caught it                  |
| `JS::LoadError`    | the shared library could not be found or loaded |
| `JS::Error`        | base class of all of the above                  |

Every one carries `#status`, the raw `bk_status` code. `JS::ThrowError` also
exposes `#js_class` (`"TypeError"`, `"RangeError"`, …) so you can branch on the
JS error class without parsing message text; it is `nil` when a non-`Error`
value was thrown, as in `throw 42`.

```ruby
begin
  vm.eval('null.foo')
rescue JS::ThrowError => e
  e.js_class   # => "TypeError"
  e.status     # => -3
end
```

## Host functions

`#register` binds a Ruby block as a JS global. Arguments arrive converted to
Ruby and the return value is converted back.

```ruby
vm.register('add') { |a, b| a + b }
vm.eval('add(40, 2)')                        # => 42.0

vm.register('shout') { |s| "#{s.to_s.upcase}!" }
vm.eval("['a', 'b'].map(shout).join(' ')")   # => "A! B!"
```

The result is an ordinary JS function value, so it works as a method, as a
callback to a built-in, and with `.call` / `.apply` / `.bind`. The block is a
Ruby closure, so state persists across calls.

Options:

| Option          | Meaning                                                     |
| --------------- | ----------------------------------------------------------- |
| `arity:`        | the function's `.length` (default: the block's arity)        |
| `constructable:`| allow `new fn()`; default `false`, so `new` throws TypeError |
| `with_call:`    | call the block as `(args_array, JS::Call)`                   |

`with_call: true` passes a `JS::Call` giving `#argc`, `#this`, and
`#construct?`. It is an explicit flag because `{ |a, b| }` and
`{ |args, call| }` are indistinguishable to `Proc#arity`.

### Errors from a host function

A Ruby exception never crosses into C. The trampoline rescues it, including
non-`StandardError` such as `NoMemoryError`, and converts it to a JS throw, so
JS catches it like any other error. The Ruby class picks the JS class:

| Ruby                              | JavaScript       |
| --------------------------------- | ---------------- |
| `TypeError`, `ArgumentError`, `NoMethodError` | `TypeError`  |
| `RangeError`, `FloatDomainError`  | `RangeError`     |
| `NameError`                       | `ReferenceError` |
| `SyntaxError`                     | `SyntaxError`    |
| anything else                     | `Error`          |

Raise `JS::HostThrow` to choose explicitly:

```ruby
vm.register('percent') do |n|
  raise JS::HostThrow.new("#{n.to_i} is out of range", :range) unless (0..100).cover?(n.to_f)

  "#{n.to_i}%"
end
```

### Calling JS from a host function

A JS function argument arrives as a `JS::Callback`; `#call` runs it through
`bk_call` and converts the result.

```ruby
vm.register('twice') { |f, x| f.call(f.call(x)) }
vm.eval('twice(x => x * 3, 5)')   # => 45.0
```

If the JS callee throws, the original error propagates back to JS unchanged.
Rescue `JS::CalleeThrow` to handle it in Ruby instead.

Only values the engine already holds can be passed to a callback: an argument
this call received, or a result an earlier `#call` returned. The v1 ABI has no
value constructors (`bk_new_number` and friends do not exist), so a fresh Ruby
object cannot become a JS value. Passing one raises a `TypeError` in JS rather
than failing silently. Arguments therefore carry their handle along: a JS
number arrives as a `JS::TaggedNumber`, which behaves as a `Float` but can also
be handed back to JS.

## Multiple runtimes

Any number of runtimes can be open at once. Each has its own globals, objects,
prototypes, host functions and interned strings, and shares nothing with the
others.

```ruby
a = JS.open
b = JS.open

a.exec('var x = 111')
b.exec('var x = 222')
a.eval('x')   # => 111.0
b.eval('x')   # => 222.0

a.register('whoami') { 'host on A' }
b.register('whoami') { 'host on B' }
```

Closing one leaves the others running.

### Values belong to one runtime

`#eval` converts its result to Ruby before returning, so ordinary results are
plain `Float`/`String`/`true`/`nil` and move between runtimes freely.

A *handle* does not. It indexes one runtime's registry, and each runtime
numbers its slots independently, so the same integer is soon live in both.
`#read` refuses a handle this runtime does not hold rather than resolving it
against an unrelated value:

```ruby
a.register('hand_over', with_call: true) do |args, call|
  handle = call.persist(args[0].handle)
  call.runtime.read(handle)   # => "secret from A"
  b.read(handle)              # raises JS::Error: not held by this runtime
end
```

To move a value across, read it out and write it back in.

Run the example:

```sh
ruby bindings/ruby/examples/two_runtimes.rb
```

## Limitations

These come from the v1 ABI, not from the binding:

- No thread safety. A runtime must be driven from one thread at a time; the
  engine has no locking and enforces nothing. Two threads each driving their
  own runtime share no state and do not interfere.
- No value constructors. A host function can return a Ruby primitive, but it
  cannot build a new JS value to *pass* to a JS callback, as described above.
- No direct property access. Reach into objects from JS source and return a
  primitive or a JSON string.
- CRuby only. Host functions need `Fiddle::Closure`, which depends on libffi
  closure support. `#register` raises `JS::HostError` where it is missing;
  JRuby and TruffleRuby never provide it through fiddle.
- Value handles are freed automatically by `#eval`. The slot table holds 65535
  live handles.

### Known engine bug

An arrow-function IIFE containing a loop loses call arguments under `bk_eval`:
the callee sees `undefined`. It affects JS callees too, so it is not specific
to host functions. The same source run as a script file does not reproduce it.

```js
(() => { let a = 7; for (let i = 0; i < 1; i++) probe(a); })()   // probe sees undefined
(function () { let a = 7; for (let i = 0; i < 1; i++) probe(a); })()  // probe sees 7
```

Use a `function` IIFE, a named function, or a top-level loop until it is fixed.
