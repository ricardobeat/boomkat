#!/usr/bin/env ruby
# frozen_string_literal: true

# Embedding the JS engine in Ruby: evaluate, read values back, handle errors,
# and expose Ruby code to JS as host functions.
#
#   ruby bindings/ruby/examples/example.rb

$LOAD_PATH.unshift(File.expand_path('../lib', File.dirname(__FILE__)))
require 'js'

# The block form always closes the runtime, even if the block raises.
JS.open do |vm|
  puts "engine version: #{vm.version}"

  # --- computing a value -----------------------------------------------------
  # Source is evaluated for its completion value, like eval().
  sum = vm.eval('[1, 2, 3, 4, 5].reduce((a, b) => a + b, 0)')
  puts "sum of 1..5: #{sum.to_i}"

  # JS numbers are doubles, so they arrive as Float.
  puts "Math.hypot(3, 4): #{vm.eval('Math.hypot(3, 4)')}"

  # Strings come back as UTF-8, including characters outside the BMP.
  puts "greeting: #{vm.eval(%q{'hello from ' + String.fromCodePoint(0x1F602)})}"

  # Booleans and null/undefined map to true/false and nil.
  puts "3 > 2: #{vm.eval('3 > 2').inspect}, null: #{vm.eval('null').inspect}"

  # Define state in one eval and use it in the next -- it is one runtime.
  vm.exec('function slugify(s) { return s.toLowerCase().replace(/\s+/g, "-") }')
  puts "slugify: #{vm.eval('slugify("Hello Embedded World")')}"

  # Objects have no direct Ruby counterpart; serialise them in JS to read one.
  puts "opaque: #{vm.eval('({ a: 1 })')}"
  puts "as JSON: #{vm.eval('JSON.stringify({ a: 1, b: [2, 3] })')}"

  # --- errors ----------------------------------------------------------------
  # A throw becomes JS::ThrowError, carrying the JS constructor name.
  begin
    vm.eval('null.property')
  rescue JS::ThrowError => e
    puts "caught: #{e.message}"
    puts "  js_class was #{e.js_class.inspect} -- branch on that, not the text"
  end

  # Code that does not parse raises JS::SyntaxError instead.
  begin
    vm.eval('function ( {')
  rescue JS::SyntaxError => e
    puts "caught syntax error: #{e.message}"
  end

  # Both descend from JS::Error, so one rescue handles either.
  begin
    vm.eval('throw new RangeError("out of range")')
  rescue JS::Error => e
    puts "caught JS::Error (status #{e.status}): #{e.message}"
  end

  # The base Error class is a case of its own: js_class must come back
  # "Error", not nil, when nothing more specific was thrown.
  begin
    vm.eval('throw new Error("boom")')
  rescue JS::ThrowError => e
    puts "caught: #{e.message}"
    puts "  js_class was #{e.js_class.inspect}"
  end

  # JS can of course catch its own exceptions; only what escapes reaches Ruby.
  recovered = vm.eval(<<~JS)
    (() => {
      try { JSON.parse('not json') }
      catch (e) { return 'recovered: ' + e.name }
    })()
  JS
  puts recovered

  # --- host functions --------------------------------------------------------
  # #register binds a Ruby block as a JS global. Arguments arrive converted to
  # Ruby and the return value is converted back.
  puts

  vm.register('hostAdd') { |a, b| a + b }
  puts "hostAdd(40, 2): #{vm.eval('hostAdd(40, 2)')}"

  # It is a real function value, so it works everywhere a function does.
  vm.register('shout') { |s| "#{s.to_s.upcase}!" }
  puts "as a callback: #{vm.eval(%q{['a', 'b'].map(shout).join(' ')})}"

  # The block is a closure, so Ruby state persists across calls.
  hits = 0
  vm.register('tally', arity: 0) { hits += 1 }
  vm.exec('tally(); tally(); tally()')
  puts "tally called #{hits} times from JS"

  # A Ruby exception never crosses into C: it is rescued in the trampoline and
  # converted to a JS throw, which JS catches like any other error. The Ruby
  # class picks the JS class -- ArgumentError becomes TypeError.
  vm.register('divide') do |a, b|
    raise ArgumentError, 'division by zero' if b.to_f.zero?

    a / b
  end
  puts "divide(10, 4): #{vm.eval('divide(10, 4)')}"
  puts vm.eval(<<~JS)
    (() => {
      try { divide(1, 0) }
      catch (e) { return 'JS caught ' + e.name + ': ' + e.message }
    })()
  JS

  # Raise JS::HostThrow to choose the JS error class explicitly. JS numbers are
  # doubles, so they arrive as Float -- #to_i keeps the message tidy.
  vm.register('percent') do |n|
    raise JS::HostThrow.new("#{n.to_i} is out of range", :range) unless (0..100).cover?(n.to_f)

    "#{n.to_i}%"
  end
  puts "percent(80): #{vm.eval('percent(80)')}"
  puts vm.eval(<<~JS)
    (() => {
      try { percent(140) }
      catch (e) { return 'JS caught ' + e.name + ': ' + e.message }
    })()
  JS

  # A host function can call back into JS. A JS function argument arrives as a
  # JS::Callback; #call runs it through bk_call and converts the result.
  vm.register('twice') { |f, x| f.call(f.call(x)) }
  puts "twice(x => x * 3, 5): #{vm.eval('twice(x => x * 3, 5)')}"

  # Values passed to a callback must be ones the engine already holds -- an
  # argument this call received, or a result a previous call returned. The v1
  # ABI has no value constructors, so a fresh Ruby object cannot become a JS
  # value here.
  vm.register('mapPair') { |f, a, b| "#{f.call(a)} / #{f.call(b)}" }
  puts "mapPair: #{vm.eval('mapPair(s => s.toUpperCase(), "left", "right")')}"

  # If the JS callback throws, the original error propagates back to JS.
  puts vm.eval(<<~JS)
    (() => {
      try { twice(() => { throw new RangeError('from JS') }, 1) }
      catch (e) { return 'propagated ' + e.name + ': ' + e.message }
    })()
  JS
end

# Leaving the block closed the runtime, so another can be opened.
puts 'runtime closed'
