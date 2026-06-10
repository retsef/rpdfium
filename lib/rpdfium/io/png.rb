# frozen_string_literal: true

require "zlib"

module Rpdfium
  module IO
    # Minimal PNG writer, pure Ruby, zero external dependencies.
    # Supports only RGBA 8bpc (color type 6) — the format PDFium produces
    # when rendering with FPDF_REVERSE_BYTE_ORDER.
    #
    # Reference: PNG spec (RFC 2083). No compromise on validity:
    # generates correct CRC32 values and uses deflate via the zlib stdlib.
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
        # PNG requires a "filter type" byte at the start of each row.
        # 0 = None (no filter). It works but compresses worse.
        # For simplicity we use None — output 1.5-2x larger than the optimal
        # minimum, but it is an explicit complexity/zero-dep tradeoff choice.
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
