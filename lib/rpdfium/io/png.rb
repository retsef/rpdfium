# frozen_string_literal: true

require "zlib"

module Rpdfium
  module IO
    # PNG writer minimale, puro Ruby, zero dipendenze esterne.
    # Supporta solo RGBA 8bpc (color type 6) — il formato che PDFium produce
    # quando rendi con FPDF_REVERSE_BYTE_ORDER.
    #
    # Riferimento: PNG spec (RFC 2083). Nessun compromesso sulla validità:
    # genera CRC32 corretti e usa deflate via zlib stdlib.
    module PNG
      SIGNATURE = "\x89PNG\r\n\x1a\n".b
      COLOR_RGBA = 6

      module_function

      def write(path, width, height, rgba_bytes, stride: nil)
        stride ||= width * 4
        File.open(path, "wb") do |f|
          f.write(SIGNATURE)
          write_ihdr(f, width, height)
          write_idat(f, width, height, rgba_bytes, stride)
          write_iend(f)
        end
        path
      end

      def write_ihdr(io, width, height)
        data = [width, height].pack("N2") +
               [8, COLOR_RGBA, 0, 0, 0].pack("C5")
        write_chunk(io, "IHDR", data)
      end

      def write_idat(io, width, height, rgba, stride)
        # PNG richiede un byte di "filter type" all'inizio di ogni riga.
        # 0 = None (nessun filtro). Funziona ma comprime peggio.
        # Per semplicità usiamo None — output 1.5-2x più grande del minimo
        # ottimo, ma è una scelta esplicita di tradeoff complessità/zero-dep.
        row_bytes = width * 4
        scanlines = String.new(capacity: (row_bytes + 1) * height,
                                encoding: Encoding::ASCII_8BIT)
        height.times do |y|
          scanlines << "\x00".b
          scanlines << rgba.byteslice(y * stride, row_bytes)
        end
        compressed = Zlib::Deflate.deflate(scanlines, Zlib::DEFAULT_COMPRESSION)
        write_chunk(io, "IDAT", compressed)
      end

      def write_iend(io)
        write_chunk(io, "IEND", "".b)
      end

      def write_chunk(io, type, data)
        type_bin = type.b
        io.write([data.bytesize].pack("N"))
        io.write(type_bin)
        io.write(data)
        io.write([Zlib.crc32(type_bin + data)].pack("N"))
      end
    end
  end
end
