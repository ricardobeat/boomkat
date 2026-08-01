# js.rb -- Ruby binding for the jse_ embedding ABI.
#
# Pure Ruby: it drives the shared library through the stdlib `fiddle`, so there
# is no native gem to compile and no dependency on the `ffi` gem. Ruby 2.6 (the
# macOS system ruby) is enough.
#
#   require 'js'
#
#   JS.open do |vm|
#     vm.eval('[1,2,3].reduce((a,b) => a+b)')   # => 6.0
#   end
#
# The block form closes the runtime on the way out, including on exception.
#
# Only one runtime may exist per process -- the engine keeps process-global
# state -- so a second JS.open while one is live raises JS::Error.

require 'fiddle'
require 'fiddle/import'

module JS
  VERSION = '0.1.0'.freeze

  # Status codes from jse.h. Success is 0; every failure is negative.
  module Status
    OK       =  0
    NOMEM    = -1
    SYNTAX   = -2
    THROW    = -3
    INTERNAL = -4
    INVALID  = -5
    TYPE     = -6
    FULL     = -7
  end

  # Value types reported by jse_type_of.
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
    # The jse_status code behind this failure.
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

  # A JS value with no natural Ruby counterpart: a plain object, a function, a
  # symbol. Getting the value itself across the boundary needs jse_call, which
  # the v1 ABI does not expose; serialise it in JS (JSON.stringify) to read it.
  class Opaque
    NAMES = {
      Type::OBJECT   => 'object',
      Type::FUNCTION => 'function',
      Type::OTHER    => 'other'
    }.freeze

    attr_reader :type_id

    def initialize(type_id)
      @type_id = type_id
    end

    def type_name
      NAMES.fetch(@type_id, 'value')
    end

    def to_s
      "#<JS::Opaque #{type_name}>"
    end
    alias inspect to_s
  end

  # Thin fiddle binding over the 12 exported symbols. Loaded once per process.
  module Lib
    extend Fiddle::Importer

    SIGNATURES = [
      'int jse_open(void*)',
      'void jse_close(void*)',
      'const char* jse_version()',
      'int jse_eval(void*, const char*, size_t, unsigned int*)',
      'void jse_value_free(void*, unsigned int)',
      'int jse_type_of(void*, unsigned int)',
      'int jse_get_number(void*, unsigned int, double*)',
      'int jse_get_bool(void*, unsigned int, int*)',
      'int jse_get_string(void*, unsigned int, char*, size_t, size_t*)',
      'const char* jse_last_error(void*)',
      'int jse_last_error_code(void*)',
      'void jse_drain_microtasks(void*)'
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

  # Default search order for the shared library:
  #   1. $JSE_LIBRARY
  #   2. ../../out/ relative to this file (a working tree after `make shared`)
  #   3. the bare soname, letting the dynamic loader search system paths
  def self.default_library
    return ENV['JSE_LIBRARY'] if ENV['JSE_LIBRARY'] && !ENV['JSE_LIBRARY'].empty?

    ext  = RUBY_PLATFORM =~ /darwin/ ? 'dylib' : 'so'
    root = File.expand_path('../../..', File.dirname(__FILE__))
    built = File.join(root, 'out', "libjse.#{ext}")
    File.exist?(built) ? built : "libjse.#{ext}"
  end

  # Open a runtime. With a block, closes it afterwards and returns the block's
  # value; without one, the caller owns the runtime and must call #close.
  def self.open(library = nil)
    vm = Runtime.new(library)
    return vm unless block_given?

    begin
      yield vm
    ensure
      vm.close
    end
  end

  # A JavaScript runtime. Not thread-safe, and only one may be open per process.
  class Runtime
    def initialize(library = nil)
      Lib.load!(library || JS.default_library)

      out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
      status = Lib.jse_open(out)
      if status != Status::OK
        raise Error.new(
          'jse_open failed -- a runtime is already open in this process ' \
          '(the engine allows only one)', status
        )
      end
      @rt = out.ptr
      @closed = false
    end

    # Engine version, e.g. "0.1.0".
    def version
      Lib.jse_version.to_s
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

      # jse_eval takes a byte length, so measure bytes and not characters:
      # any non-ASCII source would otherwise be truncated mid-string.
      bytes  = source.to_s.dup.force_encoding(Encoding::BINARY)
      handle = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)

      status = Lib.jse_eval(@rt, source.to_s, bytes.bytesize, handle)
      raise_status!(status, filename) if status != Status::OK

      id = handle[0, Fiddle::SIZEOF_INT].unpack1('L')
      begin
        to_ruby(id)
      ensure
        # Handles are not garbage collected; the slot table holds 1024.
        Lib.jse_value_free(@rt, id) if id != 0
      end
    end

    # Evaluate for side effects only, skipping the value conversion. Returns self.
    def exec(source, filename = nil)
      check_open!
      bytes = source.to_s.dup.force_encoding(Encoding::BINARY)
      status = Lib.jse_eval(@rt, source.to_s, bytes.bytesize, nil)
      raise_status!(status, filename) if status != Status::OK
      self
    end

    # Run pending promise jobs. #eval already drains before returning, so this
    # is only needed after resolving promises from outside the engine.
    def drain_microtasks
      check_open!
      Lib.jse_drain_microtasks(@rt)
      self
    end

    # Release the runtime. Idempotent; every outstanding value becomes invalid.
    def close
      return self if @closed

      Lib.jse_close(@rt)
      @rt = nil
      @closed = true
      self
    end

    def inspect
      "#<JS::Runtime#{@closed ? ' (closed)' : ''}>"
    end

    private

    def check_open!
      raise Error.new('runtime is closed', Status::INVALID) if @closed
    end

    # Turn a non-OK status into the matching exception, using the engine's
    # message. jse_last_error owns its buffer and the next call overwrites it,
    # so copy the string out immediately.
    def raise_status!(status, filename = nil)
      message = Lib.jse_last_error(@rt).to_s
      message = "JS error (status #{status})" if message.empty?
      message = "#{filename}: #{message}" if filename

      case status
      when Status::SYNTAX then raise SyntaxError.new(message, status)
      when Status::THROW  then raise ThrowError.new(message, status)
      else raise Error.new(message, status)
      end
    end

    def to_ruby(id)
      case Lib.jse_type_of(@rt, id)
      when Type::UNDEFINED, Type::NULL then nil
      when Type::BOOLEAN then read_bool(id)
      when Type::NUMBER  then read_number(id)
      when Type::STRING  then read_string(id)
      else Opaque.new(Lib.jse_type_of(@rt, id))
      end
    end

    def read_bool(id)
      out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
      status = Lib.jse_get_bool(@rt, id, out)
      raise Error.new('jse_get_bool failed', status) if status != Status::OK

      out[0, Fiddle::SIZEOF_INT].unpack1('l') != 0
    end

    def read_number(id)
      out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE)
      status = Lib.jse_get_number(@rt, id, out)
      raise Error.new('jse_get_number failed', status) if status != Status::OK

      out[0, Fiddle::SIZEOF_DOUBLE].unpack1('d')
    end

    # Two-call protocol: a NULL buffer measures, then a second call fills.
    # The engine converts its internal CESU-8 to real UTF-8 here, so astral
    # characters arrive as proper 4-byte sequences.
    def read_string(id)
      len = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T)
      status = Lib.jse_get_string(@rt, id, nil, 0, len)
      raise Error.new('jse_get_string (measure) failed', status) if status != Status::OK

      size = len[0, Fiddle::SIZEOF_SIZE_T].unpack1('J')
      return ''.dup.force_encoding(Encoding::UTF_8) if size.zero?

      buf = Fiddle::Pointer.malloc(size + 1)
      status = Lib.jse_get_string(@rt, id, buf, size + 1, len)
      raise Error.new('jse_get_string (read) failed', status) if status != Status::OK

      buf[0, size].force_encoding(Encoding::UTF_8)
    end
  end
end
