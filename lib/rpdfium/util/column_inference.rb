# frozen_string_literal: true

module Rpdfium
  module Util
    # Inference of data columns on non-tabular PDFs.
    #
    # Identifies groups of words that belong to the same vertical
    # "column" of a layout (e.g. a column of amounts in a prestamped
    # form) even when no lines are drawn.
    #
    # The algorithm operates in three passes:
    #
    # 1. **Cluster by X coordinate** — groups words with the same x0
    #    (left-aligned) or x1 (right-aligned, typical of numbers) within
    #    the configurable tolerance.
    #
    # 2. **Split by vertical gaps** — if two consecutive words in a
    #    group have an "anomalous" vertical gap (> 3x the median, or
    #    > 40pt), they are separated into distinct columns. Resolves
    #    cases such as "fiscal code at the top + table below" that share
    #    the same X.
    #
    # 3. **Filter by density** — a "true" column has regularly
    #    equispaced values (coefficient of variation of the gaps <
    #    threshold). Excludes false positives such as isolated values
    #    that happen to be aligned by chance.
    #
    # @example
    #   inference = Rpdfium::Util::ColumnInference.new(
    #     x_tolerance: 3.0,
    #     min_size: 3,
    #     cv_threshold: 0.15
    #   )
    #   columns = inference.infer(words)
    #   # => [
    #   #   [word1, word2, ..., word12],   # 12 amounts in column 1
    #   #   [word1, word2, ..., word12]    # 12 codes in column 2
    #   # ]
    class ColumnInference
      DEFAULT_X_TOLERANCE = 3.0
      DEFAULT_MIN_SIZE = 3
      DEFAULT_CV_THRESHOLD = 0.15
      DEFAULT_GAP_MULTIPLIER = 3.0
      DEFAULT_GAP_ABSOLUTE = 40.0

      def initialize(x_tolerance: DEFAULT_X_TOLERANCE,
                     min_size: DEFAULT_MIN_SIZE,
                     cv_threshold: DEFAULT_CV_THRESHOLD,
                     gap_multiplier: DEFAULT_GAP_MULTIPLIER,
                     gap_absolute: DEFAULT_GAP_ABSOLUTE)
        @x_tolerance = x_tolerance
        @min_size = min_size
        @cv_threshold = cv_threshold
        @gap_multiplier = gap_multiplier
        @gap_absolute = gap_absolute
      end

      # Infers the columns from the supplied words. Uses both x0
      # (left-align) and x1 (right-align) as alignment criteria, returns
      # the union of the identified columns.
      #
      # @param words [Array<Hash>] words with :x0, :x1, :top
      # @return [Array<Array<Hash>>] array of columns, each one an array
      #   of words ordered by ascending :top
      def infer(words)
        return [] if words.empty?

        by_x0 = cluster_by(words, :x0)
        by_x1 = cluster_by(words, :x1)

        # Union: a word may appear in more than one column. It is the
        # caller's responsibility to decide how to handle this (e.g.
        # prefer the first column, or the largest one). Here we return all.
        (by_x0 + by_x1)
      end

      # Clusters words by a specific coordinate.
      # @param coord [Symbol] :x0 or :x1
      def cluster_by(words, coord)
        sorted = words.sort_by { |v| v[coord] }
        x_groups = []
        current = []
        sorted.each do |v|
          if current.empty? || (v[coord] - current.last[coord]).abs <= @x_tolerance
            current << v
          else
            x_groups << current
            current = [v]
          end
        end
        x_groups << current

        columns = []
        x_groups.each do |group|
          sorted_y = group.sort_by { |v| v[:top] }
          gaps = sorted_y.each_cons(2).map { |a, b| b[:top] - a[:top] }

          if gaps.empty?
            columns << sorted_y if dense_enough?(sorted_y)
            next
          end

          median_gap = gaps.sort[gaps.size / 2]
          threshold = [median_gap * @gap_multiplier, @gap_absolute].max

          sub = [sorted_y.first]
          sorted_y.each_cons(2) do |a, b|
            gap = b[:top] - a[:top]
            if gap > threshold
              columns << sub if dense_enough?(sub)
              sub = [b]
            else
              sub << b
            end
          end
          columns << sub if dense_enough?(sub)
        end
        columns
      end

      # A column is "dense enough" if it has at least min_size values
      # and the coefficient of variation (std_dev/mean) of the vertical
      # gaps is below the threshold. Low CV = regular spacing = a true
      # repetitive column (vs. scattered values accidentally aligned).
      def dense_enough?(col_values)
        return false if col_values.size < @min_size

        sorted_y = col_values.sort_by { |v| v[:top] }
        gaps = sorted_y.each_cons(2).map { |a, b| b[:top] - a[:top] }
        return true if gaps.size < 2

        mean = gaps.sum / gaps.size.to_f
        variance = gaps.map { |g| (g - mean)**2 }.sum / gaps.size
        std_dev = Math.sqrt(variance)
        cv = mean.zero? ? Float::INFINITY : std_dev / mean

        cv < @cv_threshold
      end
    end
  end
end
