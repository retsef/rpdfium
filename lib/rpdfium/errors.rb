# frozen_string_literal: true

module Rpdfium
  class Error < StandardError; end
  class LoadError    < Error; end
  class PageError    < Error; end
  class PasswordError < Error; end
  class FormError    < Error; end

  PDFIUM_ERRORS = {
    0 => "Success",
    1 => "Unknown error",
    2 => "File not found or could not be opened",
    3 => "File not in PDF format or corrupted",
    4 => "Password required or incorrect",
    5 => "Unsupported security scheme",
    6 => "Page not found or content error"
  }.freeze

  class << self
    def init!
      @init_mutex ||= Mutex.new
      @init_mutex.synchronize do
        return if @initialized

        unless Raw.native_loaded?
          raise LoadError, <<~MSG.strip
            PDFium native library not loaded.
            Set ENV["PDFIUM_LIBRARY_PATH"] to libpdfium.{so,dylib,dll}, or
            install the rpdfium-binary gem.
            Original load error: #{Raw.load_error&.message}
          MSG
        end

        Raw.FPDF_InitLibrary
        @initialized = true
        # Automatic cleanup at process exit. Order is guaranteed: all Ruby
        # finalizers run before the at_exit of our own blocks.
        at_exit { Raw.FPDF_DestroyLibrary if @initialized }
      end
    end

    def initialized?
      @initialized == true
    end

    def last_error_code
      Raw.FPDF_GetLastError
    end

    def last_error_message
      PDFIUM_ERRORS[last_error_code] || "Unknown PDFium error (#{last_error_code})"
    end
  end
end
