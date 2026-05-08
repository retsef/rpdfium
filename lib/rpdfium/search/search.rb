# frozen_string_literal: true

module Rpdfium
  # Ricerca testuale interna alla pagina, basata su FPDFText_Find*.
  # Mantiene lo stato (cursor) e supporta forward/backward.
  #
  # Esempio:
  #   page.search("totale").each_match { |m| p m[:bbox], m[:text] }
  class Search
    include Enumerable

    def initialize(page, query, match_case: false, whole_word: false, start_index: 0)
      @page = page
      @query = query
      @start_index = start_index
      flags = 0
      flags |= Raw::FPDF_MATCHCASE      if match_case
      flags |= Raw::FPDF_MATCHWHOLEWORD if whole_word

      utf16 = query.encode("UTF-16LE") + "\x00\x00".b
      @query_buf = FFI::MemoryPointer.new(:uchar, utf16.bytesize)
      @query_buf.put_bytes(0, utf16)

      @handle = Raw.FPDFText_FindStart(@page.text_page.handle, @query_buf,
                                        flags, start_index)
      raise Error, "FindStart failed" if @handle.null?

      ObjectSpace.define_finalizer(self, self.class.finalizer(@handle))
    end

    def self.finalizer(handle)
      proc { Raw.FPDFText_FindClose(handle) unless handle.null? }
    end

    # Itera tutte le occorrenze in avanti. Ritorna hash con :char_index, :length,
    # :text, :rects (array di bbox top-down: una per riga di testo).
    def each_match
      return enum_for(:each_match) unless block_given?

      while Raw.FPDFText_FindNext(@handle) == 1
        yield current_match
      end
    end
    alias each each_match

    def current_match
      idx = Raw.FPDFText_GetSchResultIndex(@handle)
      n   = Raw.FPDFText_GetSchCount(@handle)
      {
        char_index: idx,
        length:     n,
        text:       extract_text(idx, n),
        rects:      extract_rects(idx, n)
      }
    end

    def close
      Raw.FPDFText_FindClose(@handle) unless @handle.null?
      @handle = FFI::Pointer::NULL
    end

    private

    def extract_text(idx, n)
      buf = FFI::MemoryPointer.new(:ushort, n + 1)
      Raw.FPDFText_GetText(@page.text_page.handle, idx, n, buf)
      buf.read_bytes((n + 1) * 2).force_encoding("UTF-16LE")
        .encode("UTF-8", invalid: :replace, undef: :replace)
        .delete("\x00")
    end

    def extract_rects(idx, n)
      cnt = Raw.FPDFText_CountRects(@page.text_page.handle, idx, n)
      h = @page.height
      Array.new(cnt) do |ri|
        l = FFI::MemoryPointer.new(:double)
        t = FFI::MemoryPointer.new(:double)
        r = FFI::MemoryPointer.new(:double)
        b = FFI::MemoryPointer.new(:double)
        Raw.FPDFText_GetRect(@page.text_page.handle, ri, l, t, r, b)
        { x0: l.read_double, x1: r.read_double,
          top: h - t.read_double, bottom: h - b.read_double }
      end
    end
  end
end
