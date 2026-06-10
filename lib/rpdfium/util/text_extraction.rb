# frozen_string_literal: true

module Rpdfium
  module Util
    # "Linear" text extraction from a collection of chars, layout=False.
    # Equivalent of pdfplumber.utils.text.chars_to_textmap in the variant
    # without preservation of the graphic layout.
    #
    # Algorithm:
    #   1. Extract words with WordExtractor (same tolerances).
    #   2. Cluster words by `top` with y_tolerance → logical lines.
    #   3. For each line, sort by x0 and join with a single space.
    #   4. Join the lines with "\n".
    #
    # NOTE on a subtlety: pdfplumber allows using an x_tolerance different
    # from y_tolerance both for word-extraction and for line-clustering.
    # We replicate this flexibility.
    module TextExtraction
      module_function

      DEFAULT_X_TOLERANCE = WordExtractor::DEFAULT_X_TOLERANCE
      DEFAULT_Y_TOLERANCE = WordExtractor::DEFAULT_Y_TOLERANCE

      def extract_text(chars,
                       x_tolerance: DEFAULT_X_TOLERANCE,
                       y_tolerance: DEFAULT_Y_TOLERANCE,
                       keep_blank_chars: false)
        return "" if chars.empty?

        words = WordExtractor.new(
          x_tolerance: x_tolerance,
          y_tolerance: y_tolerance,
          keep_blank_chars: keep_blank_chars
        ).extract_words(chars)
        return "" if words.empty?

        # Cluster the WORDS by top: final output lines.
        # Uses the "line" y_tolerance — pdfplumber here uses the same
        # y_tolerance passed in, consistent with how extract_text behaves.
        line_clusters = Cluster.cluster_objects(words, :top, tolerance: y_tolerance)

        # For each output line, join with a single space.
        line_clusters.map do |line_words|
          line_words.sort_by { |w| w[:x0] }.map { |w| w[:text] }.join(" ")
        end.join("\n")
      end
    end
  end
end
