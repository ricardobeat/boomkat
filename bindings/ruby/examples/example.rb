#!/usr/bin/env ruby
# frozen_string_literal: true

# Embedding the JS engine in Ruby: evaluate, read values back, handle errors.
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

  # JS can of course catch its own exceptions; only what escapes reaches Ruby.
  recovered = vm.eval(<<~JS)
    (() => {
      try { JSON.parse('not json') }
      catch (e) { return 'recovered: ' + e.name }
    })()
  JS
  puts recovered
end

# Leaving the block closed the runtime, so another can be opened.
puts 'runtime closed'
