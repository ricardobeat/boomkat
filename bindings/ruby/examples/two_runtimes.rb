#!/usr/bin/env ruby
# frozen_string_literal: true

# Two runtimes in one process: independent globals and objects, and a value
# that belongs to whichever runtime made it.
#
#   ruby bindings/ruby/examples/two_runtimes.rb

$LOAD_PATH.unshift(File.expand_path('../lib', File.dirname(__FILE__)))
require 'js'

a = JS.open
b = JS.open

begin
  puts "two runtimes open: #{a.inspect} #{b.inspect}"

  # --- independent globals ---------------------------------------------------
  # Same name, different runtime, different value. Neither assignment is
  # visible to the other side.
  a.exec('var x = 111')
  b.exec('var x = 222')
  puts "A.x=#{a.eval('x').to_i}, B.x=#{b.eval('x').to_i}"

  # A global defined in A is simply not there in B.
  a.exec('function only_in_a() { return "from A" }')
  puts "A has only_in_a: #{a.eval('typeof only_in_a')}"
  puts "B has only_in_a: #{b.eval('typeof only_in_a')}"

  # --- independent objects ---------------------------------------------------
  # Build the same property sequence in both. Shapes, objects and interned
  # strings are per runtime, so the two builds cannot disturb each other.
  a.exec('var o = {}; for (let i = 0; i < 200; i++) o["k" + i] = i')
  b.exec('var o = {}; for (let i = 0; i < 200; i++) o["k" + i] = i * 10')
  puts "A.o.k199=#{a.eval('o.k199').to_i}, B.o.k199=#{b.eval('o.k199').to_i}"

  # Strings intern per runtime too, so identical text is a separate string in
  # each -- which is exactly why a handle cannot be shared.
  a.exec('var s = "alpha-" + "A"')
  b.exec('var s = "alpha-" + "B"')
  puts "A.s=#{a.eval('s').inspect}, B.s=#{b.eval('s').inspect}"

  # --- host functions are per runtime ----------------------------------------
  # The same name registered on both, closing over different Ruby state.
  a.register('whoami') { 'host on A' }
  b.register('whoami') { 'host on B' }
  puts "A: #{a.eval('whoami()')}, B: #{b.eval('whoami()')}"

  # --- a value belongs to one runtime ----------------------------------------
  # #eval converts to Ruby before returning, so ordinary results move between
  # runtimes as plain Ruby objects -- there is no handle left to misuse.
  moved = a.eval('"' + 'carried from A' + '"')
  b.exec("var got = #{moved.inspect}")
  puts "moved through Ruby: B.got=#{b.eval('got').inspect}"

  # A handle is different: it indexes ONE runtime's registry. Each runtime
  # numbers its own slots from the same starting point, so the same integer is
  # live in both at once soon enough -- B asked to read A's handle would
  # otherwise answer with an unrelated value of its own. #read refuses it.
  a.register('hand_over', with_call: true) do |args, call|
    # Promote A's scope handle to one that outlives this call.
    handle = call.persist(args[0].handle)
    mine = call.runtime.read(handle)

    theirs = begin
      b.read(handle)
      'READ SOMETHING -- values leaked across runtimes'
    rescue JS::Error => e
      "refused: #{e.message}"
    end

    "handle #{handle}: A reads #{mine.inspect}, B #{theirs}"
  end
  puts a.eval('hand_over("secret from A")')

  # --- lifetimes are independent ---------------------------------------------
  # Closing one runtime leaves the other untouched.
  a.close
  puts "A closed: #{a.inspect}; B still works: B.x=#{b.eval('x').to_i}"
ensure
  a.close
  b.close
end

puts 'both runtimes closed'
