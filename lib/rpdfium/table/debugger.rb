# frozen_string_literal: true

module Rpdfium
  module Table
    # Generates a debug visualization: the page rendered to PNG with the
    # detected edges and cell bboxes overlaid. Equivalent to
    # pdfplumber.Page.to_image().debug_tablefinder().
    #
    # Implemented in pure Ruby: rasterizes the page via render(), then draws
    # over the bitmap by manipulating the RGBA bytes, and finally saves to PNG.
    module Debugger
      module_function

      RED   = [255, 0, 0, 200].freeze
      GREEN = [0, 200, 0, 200].freeze
      BLUE  = [80, 80, 255, 120].freeze

      def visualize(page, output_path, scale: 2.0, **table_opts)
        extractor = Extractor.new(page, **table_opts)
        edges = extractor.edges
        intersections = extractor.intersections
        tables = extractor.tables

        w, h, bytes, _stride = page.render(scale: scale, output: :rgba)
        canvas = Canvas.new(w, h, bytes)

        # Draws edges. New format: each edge has orientation + x0/x1/top/bottom.
        # A horizontal edge has top == bottom; a vertical one has x0 == x1.
        edges.each do |e|
          canvas.line((e[:x0] * scale).to_i, (e[:top]    * scale).to_i,
                       (e[:x1] * scale).to_i, (e[:bottom] * scale).to_i, RED)
        end

        # Draws intersections (4px circles). They are Hashes keyed by [x, y].
        intersections.each_key do |(x, y)|
          canvas.dot((x * scale).to_i, (y * scale).to_i, GREEN, 4)
        end

        # Fills tables with transparent blue. Table#bbox is the tuple [x0, top, x1, bottom].
        tables.each do |t|
          x0, top, x1, bottom = t.bbox
          canvas.rect_fill((x0 * scale).to_i, (top    * scale).to_i,
                            (x1 * scale).to_i, (bottom * scale).to_i, BLUE)
        end

        Rpdfium::IO::PNG.write(output_path, w, h, canvas.bytes, stride: w * 4)
        output_path
      end
    end

    # Minimal RGBA canvas for drawing over the rendering. Nothing sophisticated:
    # Bresenham lines, dots, rect fill with simple alpha blending.
    class Canvas
      attr_reader :bytes, :width, :height

      def initialize(width, height, rgba_bytes)
        @width  = width
        @height = height
        # We work on a mutable string (binstring)
        @bytes = rgba_bytes.dup.force_encoding(Encoding::ASCII_8BIT)
      end

      def set_pixel(x, y, color)
        return if x < 0 || x >= @width || y < 0 || y >= @height

        idx = (y * @width + x) * 4
        r, g, b, a = color
        if a >= 255
          @bytes.setbyte(idx, r)
          @bytes.setbyte(idx + 1, g)
          @bytes.setbyte(idx + 2, b)
          @bytes.setbyte(idx + 3, 255)
        else
          # Simple alpha blending (over operator)
          src_a = a / 255.0
          inv = 1 - src_a
          @bytes.setbyte(idx,     (r * src_a + @bytes.getbyte(idx)     * inv).to_i)
          @bytes.setbyte(idx + 1, (g * src_a + @bytes.getbyte(idx + 1) * inv).to_i)
          @bytes.setbyte(idx + 2, (b * src_a + @bytes.getbyte(idx + 2) * inv).to_i)
        end
      end

      # Bresenham
      def line(x0, y0, x1, y1, color)
        dx = (x1 - x0).abs
        dy = -(y1 - y0).abs
        sx = x0 < x1 ? 1 : -1
        sy = y0 < y1 ? 1 : -1
        err = dx + dy
        x = x0; y = y0
        loop do
          set_pixel(x, y, color)
          break if x == x1 && y == y1

          e2 = 2 * err
          if e2 >= dy
            err += dy; x += sx
          end
          if e2 <= dx
            err += dx; y += sy
          end
        end
      end

      def dot(cx, cy, color, radius)
        (-radius..radius).each do |dy|
          (-radius..radius).each do |dx|
            set_pixel(cx + dx, cy + dy, color) if dx * dx + dy * dy <= radius * radius
          end
        end
      end

      def rect_fill(x0, y0, x1, y1, color)
        (y0..y1).each do |y|
          (x0..x1).each do |x|
            set_pixel(x, y, color)
          end
        end
      end
    end
  end
end
