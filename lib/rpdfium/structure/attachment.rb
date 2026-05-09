# frozen_string_literal: true

module Rpdfium
  # File embedded nel PDF (allegati). PDFium li espone via FPDFDoc_GetAttachment.
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

    # Ritorna i bytes del file allegato. Pattern probe-then-fetch.
    def bytes
      out_size = FFI::MemoryPointer.new(:ulong)
      Raw.FPDFAttachment_GetFile(@handle, FFI::Pointer::NULL, 0, out_size)
      n = out_size.read_ulong
      return "" if n.zero?

      buf = FFI::MemoryPointer.new(:uchar, n)
      Raw.FPDFAttachment_GetFile(@handle, buf, n, out_size)
      buf.read_bytes(out_size.read_ulong)
    end

    def save(path)
      File.binwrite(path, bytes)
      path
    end
  end
end
