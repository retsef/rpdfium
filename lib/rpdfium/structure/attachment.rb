# frozen_string_literal: true

module Rpdfium
  # Files embedded in the PDF (attachments). PDFium exposes them via FPDFDoc_GetAttachment.
  class Attachment
    attr_reader :document, :index, :handle

    def initialize(document, index)
      @document = document
      @index    = index
      @handle   = Raw.FPDFDoc_GetAttachment(document.handle, index)
      raise Error, "Attachment #{index} not found" if @handle.null?
    end

    def name
      Raw.read_utf16_string(:FPDFAttachment_GetName, @handle)
    end

    # Returns the bytes of the attached file. Probe-then-fetch pattern.
    def bytes
      out_size = FFI::MemoryPointer.new(:ulong)
      Raw.FPDFAttachment_GetFile(@handle, FFI::Pointer::NULL, 0, out_size)
      n = out_size.read_ulong
      return "" if n.zero?

      buf = FFI::MemoryPointer.new(:uchar, n)
      Raw.FPDFAttachment_GetFile(@handle, buf, n, out_size)
      # Read n bytes (the size of OUR buffer), not out_size.read_ulong:
      # PDFium may update out_size with a value different from n (e.g. the
      # total size required), which would read past the buffer → IndexError.
      # If the actual write is < n, the remainder is filled with NUL.
      buf.read_bytes(n)
    end

    def save(path)
      File.binwrite(path, bytes)
      path
    end
  end
end
