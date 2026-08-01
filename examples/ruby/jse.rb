# fiddle wrapper for the jse_ embedding ABI.
#
# Loads the shared library built by `make shared` and wraps the same 12
# exported symbols the C header declares.
#
#   require_relative 'jse'
#   JSE::Runtime.open { |rt| puts rt.eval('40 + 2') }   # => 42.0

require 'fiddle'
require 'fiddle/import'

module JSE
  OK = 0
  ERR_NOMEM, ERR_SYNTAX, ERR_THROW = -1, -2, -3
  ERR_INTERNAL, ERR_INVALID, ERR_TYPE, ERR_FULL = -4, -5, -6, -7

  UNDEFINED, NULL, BOOLEAN, NUMBER, STRING, OBJECT, FUNCTION, OTHER = (0..7).to_a

  class JSError < StandardError
    attr_reader :code
    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  def self.default_lib
    ext = RUBY_PLATFORM =~ /darwin/ ? 'dylib' : 'so'
    root = File.expand_path('../..', __dir__)
    File.join(root, 'out', "libjse.#{ext}")
  end

  module Lib
    extend Fiddle::Importer

    def self.load!(path)
      return if @loaded
      dlload path
      extern 'int jse_open(void*)'
      extern 'void jse_close(void*)'
      extern 'const char* jse_version()'
      extern 'int jse_eval(void*, const char*, size_t, unsigned int*)'
      extern 'void jse_value_free(void*, unsigned int)'
      extern 'int jse_type_of(void*, unsigned int)'
      extern 'int jse_get_number(void*, unsigned int, double*)'
      extern 'int jse_get_bool(void*, unsigned int, int*)'
      extern 'int jse_get_string(void*, unsigned int, char*, size_t, size_t*)'
      extern 'const char* jse_last_error(void*)'
      extern 'int jse_last_error_code(void*)'
      extern 'void jse_drain_microtasks(void*)'
      @loaded = true
    end
  end

  # One engine instance. Only one may exist per process.
  class Runtime
    def self.open(path = nil)
      rt = new(path)
      return rt unless block_given?
      begin
        yield rt
      ensure
        rt.close
      end
    end

    def initialize(path = nil)
      Lib.load!(path || JSE.default_lib)
      slot = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
      rc = Lib.jse_open(slot)
      raise JSError.new(rc, 'jse_open failed (a runtime is already open?)') if rc != OK
      @rt = slot.ptr
    end

    def version
      Lib.jse_version.to_s
    end

    # Evaluate source and return the completion value as a Ruby object.
    def eval(src)
      bytes = src.dup.force_encoding(Encoding::BINARY)
      handle = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
      rc = Lib.jse_eval(@rt, src, bytes.bytesize, handle)
      raise JSError.new(rc, Lib.jse_last_error(@rt).to_s) if rc != OK

      h = handle[0, Fiddle::SIZEOF_INT].unpack1('L')
      begin
        unwrap(h)
      ensure
        Lib.jse_value_free(@rt, h)
      end
    end

    def drain_microtasks
      Lib.jse_drain_microtasks(@rt)
    end

    def close
      return unless @rt
      Lib.jse_close(@rt)
      @rt = nil
    end

    private

    def unwrap(h)
      case Lib.jse_type_of(@rt, h)
      when UNDEFINED, NULL then nil
      when BOOLEAN
        out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        Lib.jse_get_bool(@rt, h, out)
        out[0, Fiddle::SIZEOF_INT].unpack1('l') != 0
      when NUMBER
        out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_DOUBLE)
        Lib.jse_get_number(@rt, h, out)
        out[0, Fiddle::SIZEOF_DOUBLE].unpack1('d')
      when STRING then read_string(h)
      else Opaque.new(Lib.jse_type_of(@rt, h))
      end
    end

    # Two-call protocol: measure with a NULL buffer, then fill.
    def read_string(h)
      len = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T)
      rc = Lib.jse_get_string(@rt, h, nil, 0, len)
      raise JSError.new(rc, 'jse_get_string measure failed') if rc != OK

      n = len[0, Fiddle::SIZEOF_SIZE_T].unpack1('J')
      buf = Fiddle::Pointer.malloc(n + 1)
      rc = Lib.jse_get_string(@rt, h, buf, n + 1, len)
      raise JSError.new(rc, 'jse_get_string read failed') if rc != OK

      buf[0, n].force_encoding(Encoding::UTF_8)
    end
  end

  # A value with no Ruby equivalent (object, function, symbol).
  class Opaque
    NAMES = { OBJECT => 'object', FUNCTION => 'function', OTHER => 'other' }.freeze
    attr_reader :type_id
    def initialize(type_id)
      @type_id = type_id
    end

    def inspect
      "#<jse #{NAMES.fetch(@type_id, 'value')}>"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  JSE::Runtime.open do |rt|
    puts "version: #{rt.version}"
    puts "40 + 2 = #{rt.eval('40 + 2')}"
    puts "string: #{rt.eval("'hi ' + String.fromCodePoint(0x1F600)").inspect}"
    puts "array: #{rt.eval('[1,2,3].map(n => n*n).join(",")')}"
    begin
      rt.eval("throw new Error('boom')")
    rescue JSE::JSError => e
      puts "caught: #{e.code} #{e.message}"
    end
  end
end
