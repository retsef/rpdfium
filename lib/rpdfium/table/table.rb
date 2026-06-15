# frozen_string_literal: true

module Rpdfium
  module Table
    # Represents a table found on a page. Exposes cells, rows,
    # columns, bbox, and the `extract` method that returns the textual data.
    #
    # Each cell is a bbox `[x0, top, x1, bottom]` (top-down).
    # A "row" is the group of cells sharing the same `top`.
    # A "column" is the group sharing the same `x0`.
    class Table
      attr_reader :page, :cells

      def initialize(page, cells)
        @page = page
        @cells = cells
      end

      def bbox
        @cells.each_with_object(
          [Float::INFINITY, Float::INFINITY, -Float::INFINITY, -Float::INFINITY]
        ) do |c, acc|
          acc[0] = c[0] if c[0] < acc[0]
          acc[1] = c[1] if c[1] < acc[1]
          acc[2] = c[2] if c[2] > acc[2]
          acc[3] = c[3] if c[3] > acc[3]
        end
      end

      # Returns the rows as Array<Array<bbox|nil>>. The "missing" cells
      # in a row (e.g. because the table has an irregular topology) are
      # represented as nil — consistent with pdfplumber.
      def rows
        rows_or_columns(:row)
      end

      def columns
        rows_or_columns(:col)
      end

      # Extract data: Array<Array<String>>. For each row, for each cell,
      # filter the page chars whose MIDPOINT lies within the cell's bbox,
      # then reconstruct the text via Util::TextExtraction (which in turn
      # goes through WordExtractor).
      #
      # This is the pdfplumber.Table.extract path — for each row it first
      # filters the row's chars (optimization: nearly all chars from the
      # other rows are discarded immediately), then for each cell filters
      # again within the sub-bbox.
      #
      # Optimization over the naïve path: the chars are sorted by their
      # vertical midpoint only once; for each row bsearch is used to find
      # the candidate chars in O(log n) instead of scanning the whole
      # array O(n) for every row.
      #
      # NOTE on the :text strategy: `words_to_edges_h` emits by design TWO
      # edges per row (top and bottom of the cluster bbox). This means that
      # a table detected by the text-strategy will have "real" rows
      # interleaved with "empty" rows between the bottom-edge of row N and
      # the top-edge of row N+1. This is identical to pdfplumber's behavior.
      # The caller may filter via `result.reject { |row| row.all?(&:empty?) }`
      # if it wants to drop them.
      # `cell_padding`: extends each cell's bbox toward the left and toward
      # the top by N points. Default 0 (= identical pdfplumber behavior).
      # Useful for PDFs where chars protrude slightly past the cell border
      # (e.g. the uppercase "I" of the "Intermediario" cell in a CR Banca
      # d'Italia form has x0=24.0 but the cell border is at x=25.6 — it gets
      # discarded by the midpoint filter, output "ntermediario:"). With
      # `cell_padding: 2.0` the cell becomes [23.6, ..., 100, ...] and the
      # "I" is captured.
      #
      # Padding only on the "inner-left" and "inner-top" borders to avoid
      # duplicating chars shared between adjacent cells (a char between
      # cell A and cell B would end up in both if both padded on all
      # sides).
      def extract(x_tolerance: Util::WordExtractor::DEFAULT_X_TOLERANCE,
                  y_tolerance: Util::WordExtractor::DEFAULT_Y_TOLERANCE,
                  keep_blank_chars: false,
                  cell_padding: 0.0)
        # `geometry: true`: the strongest lean mode — on top of skipping
        # font/weight/angle/hyphen/unicode-error it also drops the per-char
        # origin read and emits a minimal hash. It keeps only the fields the
        # table/word pipeline reads, cutting both FFI roundtrips and hash
        # allocation. On tables with thousands of chars this is the dominant
        # cost of extract_tables. See Page#chars.
        chars = @page.chars(lean: true, geometry: true)

        # Sort by vertical midpoint once; build a parallel array of vmid
        # for bsearch. Cost: O(n log n) one-time.
        sorted_chars = chars.sort_by { |c| (c[:top] + c[:bottom]) / 2.0 }
        vmids = sorted_chars.map { |c| (c[:top] + c[:bottom]) / 2.0 }

        # Instantiate WordExtractor ONCE and reuse it for all cells
        # (a table may have dozens of cells; avoid allocations).
        word_extractor = Util::WordExtractor.new(
          x_tolerance: x_tolerance,
          y_tolerance: y_tolerance,
          keep_blank_chars: keep_blank_chars
        )

        all_rows = rows
        all_rows.map do |row|
          row_bbox = row_bounding_box(row)
          lo = vmids.bsearch_index { |v| v >= row_bbox[1] - cell_padding } || sorted_chars.size
          hi = vmids.bsearch_index { |v| v >= row_bbox[3] } || sorted_chars.size
          row_chars = sorted_chars[lo...hi]

          row.map do |cell|
            next nil if cell.nil?

            padded = cell_padding.zero? ? cell : pad_cell_bbox(cell, cell_padding)
            cell_chars = row_chars.select { |c| char_in_bbox?(c, padded) }
            if cell_chars.empty?
              ""
            else
              extract_text_with(cell_chars, word_extractor, y_tolerance)
            end
          end
        end
      end

      private

      # "Inlined" version of Util::TextExtraction.extract_text that reuses
      # a pre-existing WordExtractor instead of creating one every time.
      def extract_text_with(chars, word_extractor, y_tolerance)
        words = word_extractor.extract_words(chars)
        return "" if words.empty?

        line_clusters = Util::Cluster.cluster_objects(words, :top, tolerance: y_tolerance)
        line_clusters.map do |line_words|
          line_words.sort_by { |w| w[:x0] }.map { |w| w[:text] }.join(" ")
        end.join("\n")
      end

      def pad_cell_bbox(bbox, padding)
        x0, top, x1, bottom = bbox
        # Extend only the "inner-left" and "inner-top" borders to avoid
        # capturing chars from the adjacent cell to the right/below.
        [x0 - padding, top - padding, x1, bottom]
      end

      # Test "char midpoint inside bbox" — exactly like pdfplumber.
      # The char's midpoint (not the bbox extremes) is the criterion:
      # a char straddling the border is assigned to the cell in which it
      # has more "visual weight".
      def char_in_bbox?(char, bbox)
        x0, top, x1, bottom = bbox
        h_mid = (char[:x0] + char[:x1]) / 2.0
        v_mid = (char[:top] + char[:bottom]) / 2.0
        h_mid >= x0 && h_mid < x1 && v_mid >= top && v_mid < bottom
      end

      def row_bounding_box(row)
        row.compact.each_with_object(
          [Float::INFINITY, Float::INFINITY, -Float::INFINITY, -Float::INFINITY]
        ) do |c, acc|
          acc[0] = c[0] if c[0] < acc[0]
          acc[1] = c[1] if c[1] < acc[1]
          acc[2] = c[2] if c[2] > acc[2]
          acc[3] = c[3] if c[3] > acc[3]
        end
      end

      # Reconstructs rows or columns. axis 0 = x (for row clustering antiaxis=top),
      # axis 1 = top (for column clustering antiaxis=x0). Uses the invariant key
      # as "anchor" and the variable key as the internal ordering.
      def rows_or_columns(kind)
        # For row: sortBy = top, antiaxis = x0
        # For col: sortBy = x0, antiaxis = top
        sort_idx, group_idx = kind == :row ? [1, 0] : [0, 1]

        # All distinct x0 (for row) or top (for col), sorted
        all_keys = @cells.map { |c| c[group_idx] }.uniq.sort

        # Group by sort_idx
        sorted_cells = @cells.sort_by { |c| [c[sort_idx], c[group_idx]] }
        grouped = sorted_cells.chunk_while { |a, b| a[sort_idx] == b[sort_idx] }.to_a

        grouped.map do |group_cells|
          by_anchor = group_cells.to_h { |c| [c[group_idx], c] }
          all_keys.map { |k| by_anchor[k] }
        end
      end
    end
  end
end
