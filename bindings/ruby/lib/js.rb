# js.rb -- Ruby binding for the bk_ embedding ABI.
#
# Pure Ruby: it drives the shared library through the stdlib `fiddle`, so there
# is no native gem to compile and no dependency on the `ffi` gem. Ruby 2.6 (the
# macOS system ruby) is enough.
#
#   require 'js'
#
#   JS.open do |vm|
#     vm.eval('[1,2,3].reduce((a,b) => a+b)')   # => 6.0
#
#     vm.register('shout') { |s| s.to_s.upcase + '!' }
#     vm.eval('shout("hi")')                    # => "HI!"
#   end
#
# The block form closes the runtime on the way out, including on exception.
#
# Runtimes are independent: any number may be open at once, each with its own
# globals, objects and host functions. A value belongs to the runtime that
# produced it and cannot be read by another.

require 'fiddle'
require 'fiddle/import'

module JS
  VERSION = '0.1.0'.freeze

  # Status codes from boomkat.h. Success is 0; every failure is negative.
  module Status
    OK         =  0
    NOMEM      = -1
    SYNTAX     = -2
    THROW      = -3
    INTERNAL   = -4
    INVALID    = -5
    TYPE       = -6
    FULL       = -7
    INTERRUPT  = -8
  end

  # Error constructors bk_throw_error can raise, from bk_error_kind.
  module ErrorKind
    ERROR     = 0
    TYPE      = 1
    RANGE     = 2
    REFERENCE = 3
    SYNTAX    = 4
  end

  # Value types reported by bk_type_of.
  module Type
    UNDEFINED = 0
    NULL      = 1
    BOOLEAN   = 2
    NUMBER    = 3
    STRING    = 4
    OBJECT    = 5
    FUNCTION  = 6
    OTHER     = 7
  end

  # Base of the exception hierarchy. Everything this binding raises is a JS::Error,
  # so `rescue JS::Error` catches any engine failure.
  class Error < StandardError
    # The bk_status code behind this failure.
    attr_reader :status

    def initialize(message, status = nil)
      @status = status
      super(message)
    end
  end

  # The JS source did not parse.
  class SyntaxError < Error; end

  # JS code threw and nothing caught it.
  #
  # The engine reports a formatted message; when it carries a recognisable
  # "Name: message" prefix, #js_class exposes the JS constructor name so callers
  # can branch on it without parsing strings themselves.
  class ThrowError < Error
    # e.g. "TypeError", or nil when a non-Error value was thrown.
    attr_reader :js_class

    def initialize(message, status = Status::THROW)
      # Matches the bare "Error" name and any "*Error" suffix convention
      # (TypeError, RangeError, a user-defined FooError, ...), so a name
      # that merely starts with "Error" (e.g. "Errorish") is rejected.
      @js_class = message[/\A(Error|[A-Z]\w*Error)(?::|\z)/, 1]
      super(message, status)
    end
  end

  # The library could not be found or loaded.
  class LoadError < Error; end

  # Raised when a JS function called through JS::Callback#call threw.
  #
  # The engine has already staged that exception on the host call, so letting
  # this propagate out of the host function hands the original JS error back to
  # JS unchanged -- the trampoline recognises this class and does not convert
  # it. Rescue it to handle the failure in Ruby instead.
  class CalleeThrow < ThrowError; end

  # Host functions are not usable on this Ruby build.
  #
  # Fiddle::Closure needs libffi closure support, which mainstream CRuby has but
  # hardened builds without writable-executable memory do not, and which JRuby
  # and TruffleRuby do not provide through fiddle at all. Raised at #register
  # rather than at load, so a program that never registers still works.
  class HostError < Error; end

  # Raise this from a host function to control which JS error class JS sees.
  #
  #   vm.register('parse') { |s| raise JS::HostThrow.new('bad input', :type) }
  #
  # Any other Ruby exception is mapped by class -- see Runtime#error_kind_for --
  # so ordinary ArgumentError/TypeError already land on sensible JS classes and
  # this is only needed to override that.
  class HostThrow < Error
    KINDS = {
      error: ErrorKind::ERROR,
      type: ErrorKind::TYPE,
      range: ErrorKind::RANGE,
      reference: ErrorKind::REFERENCE,
      syntax: ErrorKind::SYNTAX
    }.freeze

    # The bk_error_kind this becomes on the JS side.
    attr_reader :kind

    def initialize(message, kind = :error)
      @kind = KINDS.fetch(kind) do
        raise ArgumentError, "unknown JS error kind #{kind.inspect}"
      end
      super(message)
    end
  end

  # A JS value with no natural Ruby counterpart: a plain object, a function, a
  # symbol. An #eval result carries no handle, so serialise it in JS
  # (JSON.stringify) to read it; one reached inside a host function keeps its
  # handle and can be passed back to a JS callback.
  class Opaque
    NAMES = {
      Type::OBJECT   => 'object',
      Type::FUNCTION => 'function',
      Type::OTHER    => 'other'
    }.freeze

    attr_reader :type_id

    # The underlying handle when this value came from a live host call, so it
    # can be passed back into JS; nil for an #eval result, whose handle is
    # released before the value reaches the caller.
    attr_reader :handle

    def initialize(type_id, handle = nil)
      @type_id = type_id
      @handle = handle
    end

    def type_name
      NAMES.fetch(@type_id, 'value')
    end

    def to_s
      "#<JS::Opaque #{type_name}>"
    end
    alias inspect to_s
  end

  # Thin fiddle binding over the exported symbols. Loaded once per process.
  module Lib
    extend Fiddle::Importer

    SIGNATURES = [
      'void* bk_open()',
      'void bk_close(void*)',
      'const char* bk_version()',

      # Value-producing calls return the handle directly; 0 means failure,
      # with the detail in bk_error / bk_error_code.
      'unsigned long long bk_eval(void*, const char*, size_t)',
      'void bk_free(void*, unsigned long long)',
      'int bk_type_of(void*, unsigned long long)',
      'int bk_read_number(void*, unsigned long long, double*)',
      'int bk_read_bool(void*, unsigned long long, int*)',
      'int bk_read_string(void*, unsigned long long, char*, size_t, size_t*)',
      'const char* bk_error(void*)',
      'int bk_error_code(void*)',
      'int bk_drain(void*)',

      # Host functions: one call installs a bk_fn_def table ended by an
      # entry with a NULL name; target 0 means globalThis. The table is
      # handed over as a packed byte buffer (see Runtime#register).
      'int bk_register(void*, unsigned long long, void*)',
      'unsigned int bk_argc(void*)',
      'unsigned long long bk_arg(void*, unsigned int)',
      'unsigned long long bk_this(void*)',
      'int bk_is_construct(void*)',
      'void bk_return(void*, unsigned long long)',
      'void bk_throw_error(void*, int, const char*)',
      'unsigned long long bk_persist(void*, unsigned long long)',
      'unsigned long long bk_call(void*, unsigned long long, unsigned long long, const unsigned long long*, unsigned int)',

      # Constructors. The header's bk_return_* forms are static inline sugar
      # over these plus bk_return, so fiddle binds these instead.
      'unsigned long long bk_number(void*, double)',
      'unsigned long long bk_bool(void*, int)',
      'unsigned long long bk_string(void*, const char*, size_t)'
    ].freeze

    class << self
      attr_reader :path

      def load!(path)
        # Re-loading into the same process would rebind the module functions
        # while a runtime may still be using them, so the first path wins.
        return if @loaded

        begin
          dlload path
        rescue Fiddle::DLError => e
          raise JS::LoadError.new("cannot load #{path}: #{e.message}")
        end
        SIGNATURES.each { |sig| extern sig }
        @path = path
        @loaded = true
      end

      def loaded?
        !!@loaded
      end
    end
  end

  # A JS value that arrived as a host-function argument, remembering the scope
  # handle it came from.
  #
  # Passing an existing engine value to a JS callback is cheaper than building
  # a fresh one, so arguments carry their handle along: #arg returns a Float or
  # String that behaves exactly like an ordinary one but can also be handed
  # straight back to JS::Callback#call. Ruby's numeric and string operators
  # return plain Float/String, so the tag disappears the moment a value is
  # computed with -- which is correct, since a computed value has no handle to
  # reuse.
  module Tagged
    # The scope handle this value came from.
    attr_accessor :handle

    # Attach `handle` to `value`, returning something usable as `value`.
    #
    # Float is immediate in CRuby and cannot carry a singleton, so a numeric
    # argument is boxed in a Numeric subclass that delegates arithmetic.
    def self.wrap(value, handle)
      case value
      when Float  then TaggedNumber.new(value, handle)
      when String then value.dup.extend(Tagged).tap { |s| s.handle = handle }
      else value
      end
    end
  end

  # A JS number argument: a Float in every respect that also knows its handle.
  class TaggedNumber < Numeric
    attr_reader :handle, :value

    def initialize(value, handle)
      @value = value
      @handle = handle
      super()
    end

    def to_f
      @value
    end

    def to_i
      @value.to_i
    end
    alias to_int to_i

    def to_s
      @value.to_s
    end

    def inspect
      @value.inspect
    end

    def coerce(other)
      [other.to_f, @value]
    end

    def <=>(other)
      @value <=> (other.is_a?(TaggedNumber) ? other.value : other)
    end

    def ==(other)
      @value == (other.is_a?(TaggedNumber) ? other.value : other)
    end

    def eql?(other)
      @value.eql?(other.is_a?(TaggedNumber) ? other.value : other)
    end

    def hash
      @value.hash
    end

    # Arithmetic yields a plain Float: the result is a new value with no handle.
    %i[+ - * / % **].each do |op|
      define_method(op) { |other| @value.public_send(op, other.is_a?(TaggedNumber) ? other.value : other) }
    end

    # Anything else Float can do, forward.
    def method_missing(name, *args, &blk)
      @value.respond_to?(name) ? @value.public_send(name, *args, &blk) : super
    end

    def respond_to_missing?(name, include_private = false)
      @value.respond_to?(name, include_private) || super
    end
  end

  # A JS function reachable from a host callback.
  #
  # Handed to a host function in place of JS::Opaque when an argument is
  # callable, so the host can call back into JS. Valid only for the duration of
  # the call that produced it -- the underlying handle is a scope handle, and
  # #call after the host function returns raises JS::Error.
  class Callback
    # The underlying scope handle, so it can be passed back to JS as an
    # argument to another call.
    attr_reader :handle

    def initialize(call, handle)
      @call = call
      @handle = handle
    end

    # Invoke the JS function. Arguments are converted from Ruby the same way
    # return values are; the result is converted back to Ruby.
    #
    # A throw from the callee is recorded on the engine and re-raised here as
    # JS::ThrowError so ordinary Ruby `rescue` sees it. Letting it escape the
    # host function propagates the original JS exception to the JS caller,
    # which is usually what you want.
    def call(*args)
      @call.invoke(@handle, args)
    end
    alias [] call

    def to_s
      '#<JS::Callback>'
    end
    alias inspect to_s
  end

  # Resolves handles reached through one context. v2 has a single context
  # type: the runtime's own at top level, the callback's inside a host
  # function. Both resolve registry handles, and the callback's also resolves
  # the scope handles bk_arg / bk_this / bk_new_target return.
  class Reader
    def initialize(ctx)
      @p = ctx
    end

    def type_of(v)
      Lib.bk_type_of(@p, v)
    end

    def read_number(v, out)
      Lib.bk_read_number(@p, v, out)
    end

    def read_bool(v, out)
      Lib.bk_read_bool(@p, v, out)
    end

    def read_string(v, buf, cap, len)
      Lib.bk_read_string(@p, v, buf, cap, len)
    end
  end

  # The live context of one host-function invocation.
  #
  # Yielded as the second block parameter by Runtime#register when the block
  # takes one. Everything on it is valid only until the block returns.
  class Call
    # The runtime this call belongs to.
    attr_reader :runtime

    # Resolves every handle reached through this call. Scope handles are only
    # visible to the context tier, so this is the one reader a host body uses.
    attr_reader :reader

    def initialize(runtime, ctx)
      @runtime = runtime
      @ctx = ctx
      @reader = Reader.new(ctx)
      @live = true
      # Registry handles produced by #invoke and by argument conversion,
      # released when the call ends.
      @owned = []
    end

    # Number of arguments actually passed, which may differ from the declared
    # arity in either direction.
    def argc
      check_live!
      Lib.bk_argc(@ctx)
    end

    # Argument `i` converted to Ruby. Reading past argc yields nil, matching
    # JS semantics for a missing argument.
    def arg(index)
      check_live!
      @runtime.send(:handle_to_ruby, Lib.bk_arg(@ctx, index), self)
    end

    # All arguments as a Ruby array.
    def args
      Array.new(argc) { |i| arg(i) }
    end

    # The `this` receiver, converted. Strict semantics: a plain call sees nil.
    def this
      check_live!
      @runtime.send(:handle_to_ruby, Lib.bk_this(@ctx), self)
    end

    # True when invoked through `new` or `super()`.
    def construct?
      check_live!
      !Lib.bk_is_construct(@ctx).zero?
    end

    # Call a JS function handle with Ruby arguments. Used by JS::Callback;
    # hosts normally go through that rather than calling this directly.
    def invoke(func_handle, args)
      check_live!

      handles = args.map { |a| @runtime.send(:argument_handle, a, self) }
      argv = nil
      unless handles.empty?
        argv = Fiddle::Pointer.malloc(Fiddle::SIZEOF_LONG_LONG * handles.size)
        handles.each_with_index do |h, i|
          argv[i * Fiddle::SIZEOF_LONG_LONG, Fiddle::SIZEOF_LONG_LONG] = [h].pack('Q')
        end
      end

      id = Lib.bk_call(@ctx, func_handle, 0, argv, handles.size)

      if id.zero?
        # The callee's exception is already staged on this context, so letting
        # this escape the host function propagates the original JS error
        # untouched. CalleeThrow marks it as "already staged" so the trampoline
        # does not overwrite it with a re-derived one.
        status = Lib.bk_error_code(@ctx)
        message = Lib.bk_error(@ctx).to_s
        message = "JS call failed (status #{status})" if message.empty?
        raise CalleeThrow.new(message, status)
      end

      # bk_call hands back a registry handle. It is kept alive until this host
      # call ends and tagged onto the converted value, so a result can be fed
      # straight into another callback -- f.call(f.call(x)). The argument
      # handles are borrowed from the caller's scope (or released with the
      # rest of @owned when they were freshly constructed) and are not ours
      # to free here.
      @owned << id
      @runtime.send(:handle_to_ruby, id, self)
    end

    # Promote a scope handle to a registry handle on #runtime that outlives the
    # call. It stays a handle on that runtime: passing it to a different one is
    # refused, so move a value across by reading it out and writing it back in.
    def persist(handle)
      check_live!
      Lib.bk_persist(@ctx, handle)
    end

    def to_s
      "#<JS::Call#{@live ? '' : ' (expired)'}>"
    end
    alias inspect to_s

    # Marks every handle reached through this context dead once the trampoline
    # returns, so a Call captured by a closure fails loudly instead of handing
    # the engine a stale scope handle, and releases the registry handles
    # #invoke took ownership of. Without this every JS callback invocation
    # would leak one.
    def expire!
      @live = false
      @owned.each { |id| @runtime.send(:free_handle, id) }
      @owned.clear
    end

    private

    def check_live!
      raise Error.new('JS::Call used after its host function returned', Status::INVALID) unless @live
    end

    # Registers a freshly constructed handle for release when the call ends.
    def record_owned(handle)
      @owned << handle
      handle
    end
  end

  # Default search order for the shared library:
  #   1. $BK_LIBRARY
  #   2. ../../out/ relative to this file (a working tree after `make shared`)
  #   3. the bare soname, letting the dynamic loader search system paths
  def self.default_library
    return ENV['BK_LIBRARY'] if ENV['BK_LIBRARY'] && !ENV['BK_LIBRARY'].empty?

    ext  = RUBY_PLATFORM =~ /darwin/ ? 'dylib' : 'so'
    root = File.expand_path('../../..', File.dirname(__FILE__))
    built = File.join(root, 'out', "boomkat.#{ext}")
    File.exist?(built) ? built : "boomkat.#{ext}"
  end

  # Open a runtime. With a block, closes it afterwards and returns the block's
  # value; without one, the caller owns the runtime and must call #close.
  #
  # Runtimes are independent, so this may be called again while one is live:
  # each gets its own globals and shares nothing with the others.
  def self.open(library = nil)
    vm = Runtime.new(library)
    return vm unless block_given?

    begin
      yield vm
    ensure
      vm.close
    end
  end

  # A JavaScript runtime: its own globals, objects, prototypes and interned
  # strings, sharing nothing with any other.
  #
  # Any number may be open at once. Each must be driven from one thread at a
  # time -- the engine has no locking and enforces nothing -- but two threads
  # each driving their own runtime share no state and do not interfere.
  #
  # A value belongs to the runtime that produced it. #eval converts its result
  # to Ruby before returning, so ordinary results move freely; a handle held
  # inside a host function does not, and the other runtime refuses it.
  class Runtime
    def initialize(library = nil)
      Lib.load!(library || JS.default_library)

      @rt = Lib.bk_open
      raise Error.new('bk_open failed', Status::NOMEM) unless @rt

      @reader = Reader.new(@rt)
      @closed = false

      # Every Fiddle::Closure registered against this runtime. A closure that
      # is garbage collected frees its executable trampoline, and the next call
      # from JS jumps into unmapped memory -- so the runtime holds them for its
      # whole lifetime. Registration is permanent engine-side too, which makes
      # holding them until #close exactly right rather than merely cautious.
      @closures = []
    end

    # Bind a Ruby block as a JS global function.
    #
    #   vm.register('add') { |a, b| a + b }
    #   vm.eval('add(40, 2)')            # => 42.0
    #
    # The block receives the call's arguments, already converted to Ruby, and
    # its return value is converted back.
    #
    # Options:
    #   arity         -- the function's .length (default: the block's arity,
    #                    or 0 when it is variadic)
    #   constructable -- allow `new fn()` (default false, which makes `new`
    #                    throw a TypeError as ES2015 specifies for built-ins)
    #   with_call     -- call the block as (args_array, JS::Call) instead of
    #                    spreading the arguments, giving it `this`, argc, and
    #                    construct detection:
    #
    #     vm.register('describe', with_call: true) { |args, call|
    #       "#{args.length} args, new=#{call.construct?}"
    #     }
    #
    # This is an explicit flag rather than something inferred from the block's
    # arity, because { |a, b| } and { |args, call| } are indistinguishable to
    # Proc#arity and guessing wrong misroutes every call.
    #
    # A Ruby exception raised inside the block never crosses into C: it is
    # rescued and converted to a JS throw. Raise JS::HostThrow to choose the JS
    # error class explicitly; otherwise the Ruby class is mapped by
    # #error_kind_for.
    def register(name, arity: nil, constructable: false, with_call: false, &block)
      check_open!
      raise ArgumentError, 'register requires a block' unless block

      unless defined?(Fiddle::Closure::BlockCaller)
        raise HostError.new(
          'host functions need Fiddle::Closure, which this Ruby build does ' \
          'not provide (JRuby and TruffleRuby never do)', Status::INTERNAL
        )
      end

      declared = arity || (with_call || block.arity.negative? ? 0 : block.arity)

      closure = build_trampoline(block, with_call)
      # Hold the reference BEFORE handing the pointer to C: if registration
      # succeeded and we then failed to record it, a GC could free a trampoline
      # the engine already points at.
      @closures << closure

      bytes = name.to_s.dup.force_encoding(Encoding::BINARY)
      status = Lib.bk_register(@rt, 0, build_fn_table(bytes, closure, declared,
                                                      constructable))
      if status != Status::OK
        @closures.pop
        raise_status!(status)
      end
      self
    end

    # Engine version, e.g. "0.1.0".
    def version
      Lib.bk_version.to_s
    end

    def closed?
      @closed
    end

    # Evaluate source for its completion value, like eval(): the last expression
    # is the result. Returns it converted to Ruby -- Float, String, true/false,
    # nil, or JS::Opaque for objects and functions.
    #
    # Raises JS::SyntaxError if it does not parse, JS::ThrowError if it throws.
    def eval(source, filename = nil)
      check_open!

      # bk_eval takes a byte length, so measure bytes and not characters:
      # any non-ASCII source would otherwise be truncated mid-string.
      bytes = source.to_s.dup.force_encoding(Encoding::BINARY)

      id = Lib.bk_eval(@rt, source.to_s, bytes.bytesize)
      raise_status!(Lib.bk_error_code(@rt), filename) if id.zero?

      begin
        to_ruby(id)
      ensure
        # Handles are not garbage collected; release the slot even if the
        # conversion raised.
        Lib.bk_free(@rt, id) if id != 0
      end
    end

    # Evaluate for side effects only, skipping the value conversion. Returns self.
    def exec(source, filename = nil)
      check_open!
      bytes = source.to_s.dup.force_encoding(Encoding::BINARY)
      id = Lib.bk_eval(@rt, source.to_s, bytes.bytesize)
      raise_status!(Lib.bk_error_code(@rt), filename) if id.zero?
      Lib.bk_free(@rt, id) if id != 0
      self
    end

    # Read a handle held on THIS runtime -- one JS::Call#persist returned --
    # and convert it to Ruby.
    #
    # A handle indexes one runtime's registry, so it means nothing anywhere
    # else, and runtimes issue the same small integers independently: two of
    # them will both hand out 65537. A handle this runtime does not hold raises
    # JS::Error rather than reading whatever occupies that slot.
    #
    # bk_type_of reports an unheld handle as undefined, which is also what a
    # genuine `undefined` reads as, so the two are told apart by asking a
    # reader: it answers BK_ERR_INVALID for an unheld slot and BK_ERR_TYPE
    # for a real undefined.
    def read(handle)
      check_open!
      if @reader.type_of(handle) == Type::UNDEFINED
        probe = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE)
        if @reader.read_number(handle, probe) == Status::INVALID
          raise Error.new(
            "handle #{handle} is not held by this runtime", Status::INVALID
          )
        end
      end
      to_ruby(handle)
    end

    # Run pending promise jobs. #eval already drains before returning, so this
    # is only needed after resolving promises from outside the engine.
    def drain_microtasks
      check_open!
      status = Lib.bk_drain(@rt)
      raise_status!(status) if status != Status::OK
      self
    end

    # Release the runtime. Idempotent; every outstanding value becomes invalid.
    def close
      return self if @closed

      Lib.bk_close(@rt)
      @rt = nil
      @reader = nil
      @closed = true
      # The engine can no longer reach these trampolines, so dropping the last
      # reference is safe only now -- not a moment earlier.
      @closures.clear
      self
    end

    def inspect
      "#<JS::Runtime#{@closed ? ' (closed)' : ''}>"
    end

    private

    def check_open!
      raise Error.new('runtime is closed', Status::INVALID) if @closed
    end

    def pointer
      @rt
    end

    # Size of one bk_fn_def on the C ABI: two pointers, an int, an unsigned
    # int, and a trailing pointer, with no padding beyond that on any 64-bit
    # target this binding supports.
    FN_DEF_SIZE = Fiddle::SIZEOF_VOIDP * 3 + Fiddle::SIZEOF_INT * 2
    private_constant :FN_DEF_SIZE

    # Pack a two-entry registration table into a byte buffer: the function
    # itself, then the all-zero terminator bk_register stops at. The name
    # bytes live at the tail of the same buffer so nothing can be collected
    # between building the table and the call.
    def build_fn_table(name_bytes, closure, arity, constructable)
      name_off = FN_DEF_SIZE * 2
      buf = Fiddle::Pointer.malloc(name_off + name_bytes.bytesize + 1)
      buf[name_off, name_bytes.bytesize] = name_bytes

      buf[0, FN_DEF_SIZE] = [
        buf.to_i + name_off,
        closure.to_i,
        arity,
        constructable ? 1 : 0,
        0
      ].pack('Q Q l L Q')
      buf
    end

    # Wrap a Ruby block in the C callback shape bk_host_fn declares:
    #   void (*)(bk_call_ctx ctx, void *udata)
    #
    # The udata parameter is unused -- Ruby closes over the block directly,
    # which is both simpler and safer than round-tripping an object through a
    # raw pointer the GC does not know about.
    def build_trampoline(block, with_call)
      Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]
      ) do |ctx, _udata|
        call = Call.new(self, ctx)
        begin
          result = if with_call
                     block.call(call.args, call)
                   else
                     block.call(*call.args)
                   end
          return_value(call, ctx, result)
        rescue CalleeThrow
          # The callee's own exception is already staged on this context.
          # Recording anything here would replace it with a lesser one.
        rescue Exception => e # rubocop:disable Lint/RescueException
          # A Ruby exception must never unwind through the C frames between
          # here and the interpreter. Convert every one -- including
          # non-StandardError such as NoMemoryError and Interrupt, which would
          # otherwise escape a bare `rescue => e` and crash the process.
          record_throw(ctx, e)
        ensure
          # Scope handles die with this call; make later use fail loudly.
          call.expire!
        end
        nil
      end
    end

    # Convert a Ruby return value into the engine's return slot. Mirrors
    # #to_ruby, and deliberately refuses what it cannot represent rather than
    # silently returning undefined.
    def return_value(call, ctx, value)
      case value
      when nil            then # a callback that returns nothing yields undefined
      when true, false    then return_constructed(ctx, Lib.bk_bool(ctx, value ? 1 : 0))
      when Numeric        then return_constructed(ctx, Lib.bk_number(ctx, value.to_f))
      when String
        bytes = value.dup.force_encoding(Encoding::BINARY)
        return_constructed(ctx, Lib.bk_string(ctx, value, bytes.bytesize))
      when Symbol
        s = value.to_s
        bytes = s.dup.force_encoding(Encoding::BINARY)
        return_constructed(ctx, Lib.bk_string(ctx, s, bytes.bytesize))
      when Callback       then # already a JS value; returning it is a no-op here
      else
        raise HostThrow.new(
          "host function returned a #{value.class}, which has no JS " \
          'representation; return a number, string, boolean, or nil', :type
        )
      end
    end

    # Hand a freshly constructed handle to bk_return and give its slot back:
    # bk_return copies the value in, so the temporary does not outlive this.
    def return_constructed(ctx, handle)
      Lib.bk_return(ctx, handle)
      Lib.bk_free(ctx, handle) if handle != 0
    end

    # Resolve one JS::Callback#call argument to a handle bk_call can take.
    #
    # A JS value the engine already holds passes through by its existing
    # handle. A Ruby primitive is constructed on the fly -- v2 has value
    # constructors usable inside a callback -- and recorded on the call so it
    # is released with the call's other handles. Anything else is refused:
    # objects and arrays would need JSON round-tripping, which is the host's
    # call to make.
    def argument_handle(value, call)
      handle = value.handle if value.respond_to?(:handle)
      return handle if handle

      case value
      when true, false
        call.send(:record_owned, Lib.bk_bool(pointer, value ? 1 : 0))
      when Numeric
        call.send(:record_owned, Lib.bk_number(pointer, value.to_f))
      when String, Symbol
        s = value.to_s
        bytes = s.dup.force_encoding(Encoding::BINARY)
        call.send(:record_owned, Lib.bk_string(pointer, s, bytes.bytesize))
      else
        raise HostThrow.new(
          "cannot pass #{describe_unpassable(value)} to a JS callback: only " \
          'a primitive (number, string, boolean, nil), or a value the engine ' \
          'already holds -- an argument this call received, or a result an ' \
          'earlier call returned -- can be passed', :type
        )
      end
    end

    def describe_unpassable(value)
      case value
      when Callback, Opaque, Tagged, TaggedNumber
        'a JS value whose handle has been released'
      else
        "a Ruby #{value.class}"
      end
    end

    # Record a Ruby exception as a JS throw. Never raises: it runs on the path
    # that exists precisely to stop exceptions escaping.
    def record_throw(ctx, exception)
      kind = exception.is_a?(HostThrow) ? exception.kind : error_kind_for(exception)
      message = begin
        exception.message.to_s
      rescue StandardError
        exception.class.name.to_s
      end
      # bk_throw_error takes a NUL-terminated C string, so a message with an
      # embedded NUL would be silently truncated there; cut it here instead.
      message = message.split("\0", 2).first.to_s
      message = exception.class.name.to_s if message.empty?
      Lib.bk_throw_error(ctx, kind, message)
    rescue Exception # rubocop:disable Lint/RescueException
      Lib.bk_throw_error(ctx, ErrorKind::ERROR, 'host function failed')
    end

    # Map a Ruby exception class onto a JS error constructor. The pairs chosen
    # are the ones whose meaning genuinely matches across the two languages;
    # anything else becomes a plain Error rather than a misleading subclass.
    #
    # This is the inverse of JS::ThrowError#js_class, which reads a JS error
    # name back out of an engine message.
    def error_kind_for(exception)
      case exception
      when ::TypeError, ::ArgumentError     then ErrorKind::TYPE
      # NoMethodError is a NameError, but calling something that cannot be
      # called is a TypeError in JS -- which is what `f.call(x)` on a
      # non-function argument means -- so it is checked first.
      when ::NoMethodError                  then ErrorKind::TYPE
      when ::RangeError, ::FloatDomainError then ErrorKind::RANGE
      when ::NameError                      then ErrorKind::REFERENCE
      when ::SyntaxError                    then ErrorKind::SYNTAX
      else ErrorKind::ERROR
      end
    end

    def free_handle(id)
      Lib.bk_free(@rt, id) if id && id != 0 && !@closed
    end

    # Convert a handle reached through a live host call -- an argument's scope
    # handle, or a registry handle bk_call returned -- into Ruby, keeping the
    # handle attached so the value can be passed back into JS. Functions become
    # JS::Callback so the host can call back into JS.
    #
    # Everything resolves through the call's context reader. A scope handle
    # names a slot in this call rather than in the runtime's registry, so the
    # runtime tier cannot see it: read through it and bk_type_of reports
    # UNDEFINED and every reader fails with BK_ERR_INVALID.
    def handle_to_ruby(id, call)
      return nil if id.zero?

      reader = call.reader
      type = reader.type_of(id)
      case type
      when Type::UNDEFINED, Type::NULL then nil
      when Type::BOOLEAN  then read_bool(id, reader)
      # Numbers and strings keep their handle, so they can be passed back into
      # bk_call without a fresh allocation.
      when Type::NUMBER   then Tagged.wrap(read_number(id, reader), id)
      when Type::STRING   then Tagged.wrap(read_string(id, reader), id)
      when Type::FUNCTION then Callback.new(call, id)
      when Type::OTHER
        # bk_type_of reports OTHER for a lightfunc -- the compact
        # representation the engine uses for many built-ins, where Math.sqrt
        # and friends live -- as well as for symbols and bigints. A lightfunc
        # is callable, so expose the whole class as a Callback and let
        # bk_call's own TypeError reject the ones that are not.
        Callback.new(call, id)
      else Opaque.new(type, id)
      end
    end

    # Turn a non-OK status into the matching exception, using the engine's
    # message. bk_error owns its buffer and the next call overwrites it, so
    # copy the string out immediately.
    def raise_status!(status, filename = nil)
      message = Lib.bk_error(@rt).to_s
      message = "JS error (status #{status})" if message.empty?
      message = "#{filename}: #{message}" if filename

      case status
      when Status::SYNTAX then raise SyntaxError.new(message, status)
      when Status::THROW  then raise ThrowError.new(message, status)
      else raise Error.new(message, status)
      end
    end

    def to_ruby(id)
      type = @reader.type_of(id)
      case type
      when Type::UNDEFINED, Type::NULL then nil
      when Type::BOOLEAN then read_bool(id, @reader)
      when Type::NUMBER  then read_number(id, @reader)
      when Type::STRING  then read_string(id, @reader)
      else Opaque.new(type)
      end
    end

    # The readers take the context that can resolve the handle: the runtime's
    # own for a registry handle from #eval, the call's for a scope handle from
    # a host function's arguments.
    def read_bool(id, reader)
      out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
      status = reader.read_bool(id, out)
      raise Error.new('bk_read_bool failed', status) if status != Status::OK

      out[0, Fiddle::SIZEOF_INT].unpack1('l') != 0
    end

    def read_number(id, reader)
      out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE)
      status = reader.read_number(id, out)
      raise Error.new('bk_read_number failed', status) if status != Status::OK

      out[0, Fiddle::SIZEOF_DOUBLE].unpack1('d')
    end

    # Two-call protocol: a NULL buffer measures, then a second call fills.
    # The engine converts its internal CESU-8 to real UTF-8 here, so astral
    # characters arrive as proper 4-byte sequences.
    def read_string(id, reader)
      len = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T)
      status = reader.read_string(id, nil, 0, len)
      raise Error.new('bk_read_string (measure) failed', status) if status != Status::OK

      size = len[0, Fiddle::SIZEOF_SIZE_T].unpack1('J')
      return ''.dup.force_encoding(Encoding::UTF_8) if size.zero?

      buf = Fiddle::Pointer.malloc(size + 1)
      status = reader.read_string(id, buf, size + 1, len)
      raise Error.new('bk_read_string (read) failed', status) if status != Status::OK

      buf[0, size].force_encoding(Encoding::UTF_8)
    end
  end
end
