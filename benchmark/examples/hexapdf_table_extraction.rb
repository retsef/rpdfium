# frozen_string_literal: true

# Reference: extracting ruled tables with hexapdf alone.
#
# rpdfium ships a table pipeline; hexapdf does not. But hexapdf is NOT missing
# the raw material — as its author notes, HexaPDF::Content::Processor gives you
#   * per-character bounding boxes (decode_text_with_positioning), even for
#     rotated/stretched glyphs, in device coordinates, and
#   * every vector path (move_to / line_to / append_rectangle / stroke) in the
#     content stream.
#
# Those are exactly the two inputs pdfplumber's (and rpdfium's) "lines"
# strategy needs. This file builds a minimal lines-based table extractor on
# top of them: collect the stroked horizontal/vertical segments, snap them
# into a grid, drop each word into the cell it falls in.
#
# It is deliberately small (no snap/join tolerances beyond a single epsilon,
# no text-strategy fallback) — a proof that the pipeline is buildable in pure
# Ruby, not a drop-in replacement for rpdfium's full TableFinder port.
#
#   gem install hexapdf
#   ruby benchmark/examples/hexapdf_table_extraction.rb path/to/file.pdf

require "hexapdf"

module HexaTable
  EPS = 2.0 # coordinate snapping tolerance, in PDF points

  # Collects ruling segments and positioned words from one page.
  class Collector < HexaPDF::Content::Processor
    attr_reader :h_lines, :v_lines, :words

    def initialize
      super
      @h_lines = [] # [x0, x1, y]
      @v_lines = [] # [y0, y1, x]
      @words = []   # { text:, x0:, x1:, y0:, y1: }
      @path = []    # buffered [p1, p2] segments in device space
      @cur = nil
    end

    # --- path construction: operands are in user space, transform via CTM ----

    def move_to(x, y)
      @cur = graphics_state.ctm.evaluate(x, y)
    end

    def line_to(x, y)
      p2 = graphics_state.ctm.evaluate(x, y)
      @path << [@cur, p2] if @cur
      @cur = p2
    end

    def append_rectangle(x, y, w, h)
      a = graphics_state.ctm.evaluate(x, y)
      b = graphics_state.ctm.evaluate(x + w, y)
      c = graphics_state.ctm.evaluate(x + w, y + h)
      d = graphics_state.ctm.evaluate(x, y + h)
      @path.push([a, b], [b, c], [c, d], [d, a])
      @cur = a
    end

    # --- painting: commit buffered segments as axis-aligned rulings ----------

    def stroke_path
      @path.each do |(x0, y0), (x1, y1)|
        if (y1 - y0).abs <= EPS && (x1 - x0).abs > EPS
          @h_lines << [[x0, x1].min, [x0, x1].max, (y0 + y1) / 2.0]
        elsif (x1 - x0).abs <= EPS && (y1 - y0).abs > EPS
          @v_lines << [[y0, y1].min, [y0, y1].max, (x0 + x1) / 2.0]
        end
      end
      @path.clear
    end
    alias close_and_stroke_path stroke_path
    alias fill_and_stroke_path_non_zero stroke_path
    alias fill_and_stroke_path_even_odd stroke_path
    alias close_fill_and_stroke_path_non_zero stroke_path
    alias close_fill_and_stroke_path_even_odd stroke_path

    def end_path
      @path.clear
    end
    alias fill_path_non_zero end_path
    alias fill_path_even_odd end_path

    # --- text: glyph boxes are already in device coordinates -----------------

    def show_text(str)
      box = decode_text_with_positioning(str)
      return if box.string.strip.empty?

      glyphs = box.boxes.reject { |g| g.string.strip.empty? }
      return if glyphs.empty?

      # Cluster glyphs into words on horizontal gaps wider than ~30% of the
      # mean glyph width (good enough for the benchmark fixtures).
      mean_w = glyphs.sum { |g| (g.lower_right[0] - g.lower_left[0]).abs } / glyphs.size
      gap = [mean_w * 0.3, 1.0].max
      run = [glyphs.first]
      glyphs[1..].each do |g|
        if g.lower_left[0] - run.last.lower_right[0] > gap
          flush_word(run)
          run = [g]
        else
          run << g
        end
      end
      flush_word(run)
    end
    alias show_text_with_positioning show_text

    private

    def flush_word(glyphs)
      text = glyphs.map(&:string).join.strip
      return if text.empty?

      xs = glyphs.flat_map { |g| [g.lower_left[0], g.lower_right[0]] }
      ys = glyphs.flat_map { |g| [g.lower_left[1], g.upper_left[1]] }
      @words << { text: text, x0: xs.min, x1: xs.max, y0: ys.min, y1: ys.max }
    end
  end

  module_function

  # Snap a list of coordinates into representative cluster centers.
  def snap(coords)
    coords.sort.each_with_object([]) do |c, acc|
      acc << [c] and next if acc.empty? || (c - acc.last.last) > EPS

      acc.last << c
    end.map { |group| group.sum / group.size }
  end

  # Turn collected rulings + words into Array<Array<Array<String>>> (tables).
  def build_tables(collector)
    x_edges = snap(collector.v_lines.map { |l| l[2] })
    y_edges = snap(collector.h_lines.map { |l| l[2] })
    return [] if x_edges.size < 2 || y_edges.size < 2

    rows_y = y_edges.sort.reverse # top-to-bottom
    grid = Array.new(rows_y.size - 1) { Array.new(x_edges.size - 1) { +"" } }

    collector.words.each do |w|
      cx = (w[:x0] + w[:x1]) / 2.0
      cy = (w[:y0] + w[:y1]) / 2.0
      ci = (0...x_edges.size - 1).find { |i| cx.between?(x_edges[i], x_edges[i + 1]) }
      ri = (0...rows_y.size - 1).find { |i| cy.between?(rows_y[i + 1], rows_y[i]) }
      next unless ci && ri

      cell = grid[ri][ci]
      cell << " " unless cell.empty?
      cell << w[:text]
    end

    [grid] # one grid per page in this minimal version
  end

  # Public entry point: returns Array<table> for every page, table = rows.
  def extract(path)
    tables = []
    HexaPDF::Document.open(path) do |doc|
      doc.pages.each do |page|
        collector = Collector.new
        page.process_contents(collector)
        build_tables(collector).each { |t| tables << t }
      end
    end
    tables
  end
end

if $PROGRAM_NAME == __FILE__
  file = ARGV[0] or abort "usage: ruby #{__FILE__} file.pdf"
  HexaTable.extract(file).each_with_index do |table, ti|
    puts "── table #{ti + 1} (#{table.size} rows) ──"
    table.each { |row| p row }
  end
end
