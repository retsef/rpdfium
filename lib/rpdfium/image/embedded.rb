# frozen_string_literal: true

module Rpdfium
  module Image
    # Wrapper for an image object placed in a page. Allows you to:
    # - read metadata (pixel size, DPI, colorspace, BPP)
    # - obtain raw bytes (as stored: typically JPEG)
    # - obtain decoded bytes (raster after filters)
    # - obtain a rendered bitmap (with masks and matrix applied)
    class Embedded
      COLORSPACES = {
        0 => :unknown, 1 => :devicegray, 2 => :devicergb, 3 => :devicecmyk,
        4 => :calgray, 5 => :calrgb, 6 => :lab, 7 => :iccbased,
        8 => :separation, 9 => :devicen, 10 => :indexed, 11 => :pattern
      }.freeze

      attr_reader :page, :handle

      def initialize(page, page_object_handle)
        @page   = page
        @handle = page_object_handle
      end

      def metadata
        meta = Raw::FPDF_IMAGEOBJ_METADATA.new
        return nil if Raw.FPDFImageObj_GetImageMetadata(@handle, @page.handle, meta) == 0

        {
          width:           meta[:width],
          height:          meta[:height],
          horizontal_dpi:  meta[:horizontal_dpi],
          vertical_dpi:    meta[:vertical_dpi],
          bits_per_pixel:  meta[:bits_per_pixel],
          colorspace:      COLORSPACES[meta[:colorspace]] || :unknown
        }
      end

      def pixel_size
        wbuf = FFI::MemoryPointer.new(:uint)
        hbuf = FFI::MemoryPointer.new(:uint)
        return nil if Raw.FPDFImageObj_GetImagePixelSize(@handle, wbuf, hbuf) == 0

        [wbuf.read_uint, hbuf.read_uint]
      end

      def bbox
        l = FFI::MemoryPointer.new(:float)
        r = FFI::MemoryPointer.new(:float)
        b = FFI::MemoryPointer.new(:float)
        t = FFI::MemoryPointer.new(:float)
        return nil if Raw.FPDFPageObj_GetBounds(@handle, l, r, b, t) == 0

        h = @page.height
        { x0: l.read_float, x1: r.read_float,
          top: h - t.read_float, bottom: h - b.read_float }
      end

      # Filters applied in PDF order: e.g. ["DCTDecode"] → JPEG,
      # ["FlateDecode"] → zlib, ["DCTDecode","DCTDecode"] → re-encodings.
      def filters
        n = Raw.FPDFImageObj_GetImageFilterCount(@handle)
        Array.new(n) do |i|
          # Probe + read
          len = Raw.FPDFImageObj_GetImageFilter(@handle, i, FFI::Pointer::NULL, 0)
          if len > 1
            buf = FFI::MemoryPointer.new(:uchar, len)
            Raw.FPDFImageObj_GetImageFilter(@handle, i, buf, len)
            buf.read_bytes(len - 1).force_encoding("UTF-8")
          else
            ""
          end
        end
      end

      # "Raw" bytes: as they are stored in the PDF. If filters ==
      # ["DCTDecode"] these bytes are a complete JPEG that you can save
      # with a .jpg extension.
      def raw_bytes
        len = Raw.FPDFImageObj_GetImageDataRaw(@handle, FFI::Pointer::NULL, 0)
        return "" if len.zero?

        buf = FFI::MemoryPointer.new(:uchar, len)
        Raw.FPDFImageObj_GetImageDataRaw(@handle, buf, len)
        buf.read_bytes(len)
      end

      # Decoded bytes: raster pixels after the filters are applied.
      # Layout depends on the colorspace.
      def decoded_bytes
        len = Raw.FPDFImageObj_GetImageDataDecoded(@handle, FFI::Pointer::NULL, 0)
        return "" if len.zero?

        buf = FFI::MemoryPointer.new(:uchar, len)
        Raw.FPDFImageObj_GetImageDataDecoded(@handle, buf, len)
        buf.read_bytes(len)
      end

      # Bitmap rendered applying matrix and masks. Returns [w, h, bytes(BGRA)].
      def render_bitmap
        bitmap = Raw.FPDFImageObj_GetRenderedBitmap(
          @page.document.handle, @page.handle, @handle
        )
        return nil if bitmap.null?

        begin
          w = Raw.FPDFBitmap_GetWidth(bitmap)
          h = Raw.FPDFBitmap_GetHeight(bitmap)
          stride = Raw.FPDFBitmap_GetStride(bitmap)
          buf = Raw.FPDFBitmap_GetBuffer(bitmap)
          [w, h, buf.read_bytes(stride * h), stride]
        ensure
          Raw.FPDFBitmap_Destroy(bitmap)
        end
      end

      # Saves the file. If the filters are DCTDecode → writes a direct
      # .jpg. Otherwise renders the bitmap to PNG.
      def save(path)
        if filters == ["DCTDecode"]
          File.binwrite(path, raw_bytes)
        else
          w, h, bytes, stride = render_bitmap
          # The rendered bitmaps are BGRA: we convert to RGBA for the PNG writer
          rgba = swap_bgra_to_rgba(bytes, w, h, stride)
          Rpdfium::IO::PNG.write(path, w, h, rgba, stride: w * 4)
        end
        path
      end

      private

      def swap_bgra_to_rgba(bgra, w, h, stride)
        out = String.new(capacity: w * h * 4, encoding: Encoding::ASCII_8BIT)
        h.times do |y|
          row = bgra.byteslice(y * stride, w * 4)
          # Swap B<->R for each pixel
          (0...row.bytesize).step(4) do |i|
            out << row.getbyte(i + 2) << row.getbyte(i + 1) <<
                   row.getbyte(i)     << row.getbyte(i + 3)
          end
        end
        out
      end
    end
  end
end
