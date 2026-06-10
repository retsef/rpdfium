# frozen_string_literal: true

module Rpdfium
  module Util
    # Associates semantic labels with values placed on PDFs of filled-in
    # forms (F24, VAT communications, Modello 770) where template and data
    # coexist as graphic text in different fonts.
    #
    # Base strategy:
    #
    # 1. **Cluster** the template words into "coherent labels": words that
    #    are geometrically close form a single label.
    #
    # 2. **For each value** search for:
    #    - `:col` — the label ABOVE in the same column
    #    - `:row` — the label TO THE LEFT in the same row
    #
    # 3. (Optional) **Column reassignment**: uses `ColumnInference` to
    #    identify repetitive columns (e.g. ST2..ST13 of the 770 Quadro
    #    ST) and propagates the canonical header to all the values in the
    #    column, overriding the `col_max_dy` limit.
    #
    # @example basic usage
    #   matcher = Rpdfium::Util::LabelMatcher.new
    #   matcher.match(value_words, anchor_words)
    #
    # @example with repetitive tables (header at the top of the column)
    #   matcher = Rpdfium::Util::LabelMatcher.new(
    #     column_inference: Rpdfium::Util::ColumnInference.new
    #   )
    #   matcher.match(value_words, anchor_words)
    class LabelMatcher
      DEFAULT_COL_MAX_DY = 80.0
      DEFAULT_ROW_MAX_DX = 200.0
      DEFAULT_COL_X_TOLERANCE = 10.0
      DEFAULT_ROW_Y_TOLERANCE = 2.0
      DEFAULT_CLUSTER_SAME_ROW_DY = 4.0
      DEFAULT_CLUSTER_SAME_ROW_DX = 12.0
      DEFAULT_CLUSTER_ADJ_ROW_DY = 4.0
      DEFAULT_IGNORE_LABEL_PATTERN = /\A\d{1,3}\z|\A[IVX]{1,5}\z/.freeze
      WIDE_VALUE_THRESHOLD = 60.0

      def initialize(col_max_dy: DEFAULT_COL_MAX_DY,
                     row_max_dx: DEFAULT_ROW_MAX_DX,
                     col_x_tolerance: DEFAULT_COL_X_TOLERANCE,
                     row_y_tolerance: DEFAULT_ROW_Y_TOLERANCE,
                     cluster_same_row_dy: DEFAULT_CLUSTER_SAME_ROW_DY,
                     cluster_same_row_dx: DEFAULT_CLUSTER_SAME_ROW_DX,
                     cluster_adj_row_dy: DEFAULT_CLUSTER_ADJ_ROW_DY,
                     ignore_label_pattern: DEFAULT_IGNORE_LABEL_PATTERN,
                     column_inference: nil)
        @col_max_dy = col_max_dy
        @row_max_dx = row_max_dx
        @col_x_tolerance = col_x_tolerance
        @row_y_tolerance = row_y_tolerance
        @cluster_same_row_dy = cluster_same_row_dy
        @cluster_same_row_dx = cluster_same_row_dx
        @cluster_adj_row_dy = cluster_adj_row_dy
        @ignore_label_pattern = ignore_label_pattern
        @column_inference = column_inference
      end

      # Computes the label → value associations.
      #
      # @param values [Array<Hash>] words of the "data" layer
      # @param anchors [Array<Hash>] words of the "template" layer
      # @return [Array<Hash>] one per value: { value:, labels: { col:, row: }, geometry: }
      def match(values, anchors)
        labels = cluster_anchors(anchors)

        prelim = values.map do |v|
          col = find_col_label(v, labels)
          row = find_row_label(v, labels)
          { value: v, col: col, row: row }
        end

        # Optional reassignment for repetitive columns
        prelim = reassign_by_columns(prelim, labels, values) if @column_inference

        prelim.map do |entry|
          v = entry[:value]
          {
            value: v[:text],
            labels: {
              col: entry[:col]&.dig(:text),
              row: entry[:row]&.dig(:text)
            },
            geometry: {
              x0: v[:x0], x1: v[:x1], top: v[:top], bottom: v[:bottom]
            }
          }
        end
      end

      # Reconstructs the labels from the cluster of template words.
      # Exposed publicly for inspection/debug.
      def cluster_anchors(anchor_words)
        remaining = anchor_words.dup
        groups = []
        until remaining.empty?
          seed = remaining.shift
          group = [seed]
          grew = true
          while grew
            grew = false
            remaining.dup.each do |w|
              close = group.any? do |g|
                dx_horiz = [w[:x0] - g[:x1], g[:x0] - w[:x1]].max
                same_row = (w[:top] - g[:top]).abs < @cluster_same_row_dy &&
                           dx_horiz < @cluster_same_row_dx
                dy_above = (g[:top] - w[:bottom]).abs
                dy_below = (w[:top] - g[:bottom]).abs
                vertical_adjacent = [dy_above, dy_below].min < @cluster_adj_row_dy
                x_overlap = !(w[:x1] < g[:x0] - 3 || w[:x0] > g[:x1] + 3)
                adj_row = vertical_adjacent && x_overlap
                same_row || adj_row
              end
              if close
                group << w
                remaining.delete(w)
                grew = true
              end
            end
          end
          groups << group
        end
        labels = groups.map { |g| group_to_label(g) }
        if @ignore_label_pattern
          labels = labels.reject { |l| l[:text].match?(@ignore_label_pattern) }
        end
        labels
      end

      private

      def group_to_label(group)
        sorted = group.sort_by { |w| [w[:top].round(0), w[:x0]] }
        {
          text: sorted.map { |w| w[:text] }.join(" "),
          x0: group.map { |w| w[:x0] }.min,
          x1: group.map { |w| w[:x1] }.max,
          top: group.map { |w| w[:top] }.min,
          bottom: group.map { |w| w[:bottom] }.max
        }
      end

      def find_col_label(value, labels)
        # For "wide" words (wider than most labels, typically because
        # they result from the merge of a string that spans several
        # template columns) use the left edge: the correct label is the
        # one below which the value STARTS.
        value_width = value[:x1] - value[:x0]
        anchor_point =
          if value_width > WIDE_VALUE_THRESHOLD
            value[:x0] + 5.0
          else
            (value[:x0] + value[:x1]) / 2.0
          end

        labels.select do |l|
          l[:x0] - @col_x_tolerance <= anchor_point &&
            l[:x1] + @col_x_tolerance >= anchor_point &&
            l[:bottom] < value[:top] &&
            (value[:top] - l[:bottom]) <= @col_max_dy
        end.min_by { |l| value[:top] - l[:bottom] }
      end

      def find_row_label(value, labels)
        vy = (value[:top] + value[:bottom]) / 2.0
        labels.select do |l|
          l[:top] <= vy &&
            l[:bottom] >= vy - @row_y_tolerance &&
            l[:x1] < value[:x0] &&
            (value[:x0] - l[:x1]) <= @row_max_dx
        end.max_by { |l| l[:x1] }
      end

      # Identifies data columns and propagates the canonical header
      # printed at the top of the column to ALL the values of the column.
      # Uses the @column_inference provided to the constructor.
      def reassign_by_columns(prelim, labels, values)
        columns = @column_inference.infer(values)
        return prelim if columns.empty?

        # Sort larger columns first (more statistical evidence)
        sorted_columns = columns.sort_by { |c| -c.size }

        column_headers = {}
        sorted_columns.each do |col_values|
          col_top = col_values.map { |v| v[:top] }.min
          anchor_x = col_values.map { |v| (v[:x0] + v[:x1]) / 2.0 }.sum / col_values.size

          header = labels.select do |l|
            l[:x0] - @col_x_tolerance <= anchor_x &&
              l[:x1] + @col_x_tolerance >= anchor_x &&
              l[:bottom] <= col_top + 1
          end.min_by { |l| col_top - l[:bottom] }

          next unless header

          col_values.each do |v|
            column_headers[v.object_id] ||= header
          end
        end

        prelim.map do |entry|
          v = entry[:value]
          new_col = column_headers[v.object_id]
          new_col ? entry.merge(col: new_col) : entry
        end
      end
    end
  end
end
