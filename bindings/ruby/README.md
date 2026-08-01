# Ruby binding

Pure-Ruby binding to the `jse_` embedding ABI, built on the stdlib
[`fiddle`](https://docs.ruby-lang.org/en/master/Fiddle.html). It dlopens the
shared library and calls the symbols `include/jse.h` declares, including the
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

That produces `out/libjse.dylib` (macOS) or `out/libjse.so` (Linux).

## Run

```sh
make example-ruby
```

or directly:

```sh
ruby bindings/ruby/examples/example.rb
```

The binding finds the library by searching, in order:

1. `$JSE_LIBRARY`, if set, for an installed or relocated build
2. `out/libjse.{dylib,so}` relative to the repository root
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

Every one carries `#status`, the raw `jse_status` code. `JS::ThrowError` also
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
`jse_call` and converts the result.

```ruby
vm.register('twice') { |f, x| f.call(f.call(x)) }
vm.eval('twice(x => x * 3, 5)')   # => 45.0
```

If the JS callee throws, the original error propagates back to JS unchanged.
Rescue `JS::CalleeThrow` to handle it in Ruby instead.

Only values the engine already holds can be passed to a callback: an argument
this call received, or a result an earlier `#call` returned. The v1 ABI has no
value constructors (`jse_new_number` and friends do not exist), so a fresh Ruby
object cannot become a JS value. Passing one raises a `TypeError` in JS rather
than failing silently. Arguments therefore carry their handle along: a JS
number arrives as a `JS::TaggedNumber`, which behaves as a `Float` but can also
be handed back to JS.

## Limitations

These come from the v1 ABI, not from the binding:

- One runtime per process. The engine keeps process-global state, so a second
  `JS.open` while one is live raises `JS::Error`. Close the first.
- No thread safety. Confine a runtime to one thread.
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

An arrow-function IIFE containing a loop loses call arguments under `jse_eval`:
the callee sees `undefined`. It affects JS callees too, so it is not specific
to host functions. The same source run as a script file does not reproduce it.

```js
(() => { let a = 7; for (let i = 0; i < 1; i++) probe(a); })()   // probe sees undefined
(function () { let a = 7; for (let i = 0; i < 1; i++) probe(a); })()  // probe sees 7
```

Use a `function` IIFE, a named function, or a top-level loop until it is fixed.
