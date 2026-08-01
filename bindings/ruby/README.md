# Ruby binding

Pure-Ruby binding to the `jse_` embedding ABI, built on the stdlib
[`fiddle`](https://docs.ruby-lang.org/en/master/Fiddle.html). There is no native
gem to compile and no dependency on the `ffi` gem — it dlopens the shared
library and calls the same 12 symbols `include/jse.h` declares.

## Prerequisites

- **Ruby 2.6 or newer with `fiddle`.** The macOS system Ruby
  (`/usr/bin/ruby`, 2.6.10) works as-is; `fiddle` ships with the stdlib.
  Check with `ruby -v` and `ruby -e "require 'fiddle'"`.
- **A C3 compiler** (`c3c` 0.8.2) to build the engine.

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

1. `$JSE_LIBRARY`, if set — the escape hatch for an installed or relocated build
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
recovered: SyntaxError
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

`JS::Opaque` is a marker: reading an object's contents needs `jse_call`, which
the v1 ABI does not expose. Serialise it in JS instead —
`vm.eval('JSON.stringify(x)')`.

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

## Limitations

These come from the v1 ABI, not from the binding:

- **One runtime per process.** The engine keeps process-global state, so a
  second `JS.open` while one is live raises `JS::Error`. Close the first.
- **Not thread-safe.** Confine a runtime to one thread.
- **No Ruby callbacks from JS.** Built-in dispatch is a compile-time ordinal
  table with no host function pointer, so registering a Ruby proc as a JS
  function is impossible without engine changes.
- **No direct property access.** There is no `jse_call` yet; reach into objects
  from JS source and return a primitive or a JSON string.
- Value handles are freed automatically by `#eval`. The slot table holds 1024
  live handles.
