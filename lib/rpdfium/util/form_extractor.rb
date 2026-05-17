# frozen_string_literal: true

module Rpdfium
  module Util
    # Generic word-level extractor for form PDFs with visual grid layouts
    # (Italian fiscal forms, bank statements, etc.).
    #
    # These forms use graphic rectangles for the grid — extract_tables()
    # picks up visual clutter instead of data. The correct approach is:
    #   1. Extract words via page.words()
    #   2. Anchor to structural labels that appear at predictable positions
    #   3. Filter words by calibrated Y bands and X column ranges
    #
    # Example — extract data relative to a record label:
    #
    #   fx = Rpdfium::Util::FormExtractor.new(page.words(x_tolerance: 3, y_tolerance: 3))
    #
    #   fx.records(/^ST\d+$/, skip: /^ST1$/) do |lbl|
    #     ly       = lbl[:top]
    #     row_a    = fx.band(ly - 9, ly - 3)       # data row above label
    #     ritenute = fx.pick(row_a, 233, 293)       # column X range
    #     mese     = fx.join_digits(row_a, 134, 156) # digit cluster "0","7" → "07"
    #   end
    class FormExtractor
      attr_reader :words

      def initialize(words)
        @words = words
      end

      # Words whose :top falls in [y_lo, y_hi], optionally constrained by X.
      # Uses :x0 for X filtering (left edge of word).
      def band(y_lo, y_hi, x_lo = 0, x_hi = Float::INFINITY)
        @words.select do |w|
          w[:top] >= y_lo && w[:top] <= y_hi &&
            w[:x0] >= x_lo && w[:x0] < x_hi
        end
      end

      # Text of words whose :x0 falls in [x_lo, x_hi], joined left→right.
      # Pass a pre-filtered list (e.g. from #band) to restrict the Y range first.
      def pick(words, x_lo, x_hi)
        words.select { |w| w[:x0] >= x_lo && w[:x0] < x_hi }
             .sort_by { |w| w[:x0] }
             .map { |w| w[:text] }
             .join(" ")
             .strip
      end

      # Like #pick but concatenates without spaces.
      # Use when a multi-character value is split into single-char tokens,
      # e.g. "0" and "7" rendered as separate glyphs → "07".
      def join_digits(words, x_lo, x_hi)
        words.select { |w| w[:x0] >= x_lo && w[:x0] < x_hi }
             .sort_by { |w| w[:x0] }
             .map { |w| w[:text] }
             .join
             .strip
      end

      # Words matching `pattern`, sorted top→bottom.
      # `skip:` is an optional pattern for labels to exclude.
      # Yields each label word if a block is given; returns the array otherwise.
      def records(pattern, skip: nil)
        matches = @words.select { |w| w[:text].match?(pattern) }
                        .sort_by { |w| w[:top] }
        matches = matches.reject { |w| w[:text].match?(skip) } if skip
        block_given? ? matches.each { |lbl| yield lbl } : matches
      end

      # True if any word on the page matches `pattern`.
      def has_label?(pattern)
        @words.any? { |w| w[:text].match?(pattern) }
      end

      # First word matching `pattern` whose :x0 falls in [x_lo, x_hi].
      # Useful for detecting structural markers like campo numbers.
      def find_label(pattern, x_lo = 0, x_hi = Float::INFINITY)
        @words.find { |w| w[:text].match?(pattern) && w[:x0] >= x_lo && w[:x0] < x_hi }
      end
    end
  end
end
