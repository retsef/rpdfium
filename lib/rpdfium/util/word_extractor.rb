# frozen_string_literal: true

module Rpdfium
  module Util
    # Extracts "words" from a list of chars, faithfully to
    # pdfplumber.WordExtractor.
    #
    # Algorithm:
    #   1. Sort the chars by (top, x0): rows top-to-bottom, chars
    #      left-to-right within each row.
    #   2. Cluster by top with `y_tolerance` → "logical rows" of chars.
    #   3. Within each row, cluster by horizontal gap: two chars belong to
    #      the same word if `next.x0 - prev.x1 <= x_tolerance`. A whitespace
    #      char also separates the word (unless `keep_blank_chars`).
    #   4. For each cluster of chars, emit a word: concatenated text, bbox.
    #
    # Differences from pdfplumber (simplifications acceptable for our use):
    #   - We do not handle rotated `line_dir`/`char_dir` (text rotated away
    #     from horizontal ltr): not relevant for current use cases.
    #   - We do not handle `use_text_flow` (ordering based on the content
    #     stream): our chars already arrive from PDFium in geometric order
    #     via `chars` (top, x0).
    #   - We do not handle `expand_ligatures`: PDFium usually expands the
    #     codepoints correctly already at the char level.
    #
    # These differences are documented; if ever needed they can be added
    # as feature toggles without changing the default path.
    class WordExtractor
      DEFAULT_X_TOLERANCE = 3.0
      DEFAULT_Y_TOLERANCE = 3.0

      attr_reader :x_tolerance, :y_tolerance, :keep_blank_chars

      def initialize(x_tolerance: DEFAULT_X_TOLERANCE,
                     y_tolerance: DEFAULT_Y_TOLERANCE,
                     keep_blank_chars: false,
                     extra_attrs: nil)
        @x_tolerance = x_tolerance.to_f
        @y_tolerance = y_tolerance.to_f
        @keep_blank_chars = keep_blank_chars
        @extra_attrs = extra_attrs || []
      end

      # Returns an Array of Hash: { text:, x0:, x1:, top:, bottom:, chars: }.
      # If `extra_attrs` is non-empty, each word also splits when these
      # attributes change (e.g. different fontname/size → different words).
      def extract_words(chars)
        return [] if chars.empty?

        # Fast path: a single char → 1 trivial word (if not whitespace).
        if chars.size == 1
          c = chars.first
          return [] if blank?(c) && !@keep_blank_chars

          return [build_word([c])]
        end

        # 1. Sort by (top, x0). Top-down, left-to-right.
        sorted = chars.sort_by { |c| [c[:top], c[:x0]] }

        # 2. Cluster into rows by `top`.
        # `presorted: true`: sorted is already ordered by [top, x0], hence
        # implicitly also by top — cluster_objects skips its own internal
        # sort.
        rows = Cluster.cluster_objects(sorted, :top,
                                        tolerance: @y_tolerance,
                                        presorted: true)

        words = []
        rows.each do |row|
          # Re-sort by x0 within each clustered row.
          #
          # NOTE: in principle the input `sorted` is already ordered by
          # [top, x0], so the top clusters should already be in x0 order.
          # BUT the global sort `[top, x0]` strictly respects the order by
          # top — if two chars of the same visual row have different tops
          # within tolerance (e.g. the lowercase "i" often has a top higher
          # by 0.008pt than the other letters because of how PDFium computes
          # the bbox), the global sort interleaves them. cluster_objects by
          # :top does not internally reorder the chars, so a char with a
          # slightly lower top ends up AHEAD of all the other letters of the
          # word.
          #
          # Real example: "Categoria" where "i" has top=414.9789 and the
          # others 414.9869 → output `iCategora` instead of `Categoria`.
          # The fix is simply to re-sort by x0 within the row.
          row_sorted = row.sort_by { |c| c[:x0] }

          word_chars = []
          row_sorted.each do |c|
            if char_begins_new_word?(word_chars.last, c)
              words << build_word(word_chars) unless word_chars.empty?
              word_chars = []
            end
            # Whitespace: by default we use it as a separator (we discard it).
            # With keep_blank_chars=true we include it in the current word.
            if blank?(c) && !@keep_blank_chars
              words << build_word(word_chars) unless word_chars.empty?
              word_chars = []
            else
              word_chars << c
            end
          end
          words << build_word(word_chars) unless word_chars.empty?
        end

        words
      end

      private

      def char_begins_new_word?(prev, curr)
        return false if prev.nil?

        # Horizontal gap (PDF font hinting may give a slight overlap, max 0)
        gap = curr[:x0] - prev[:x1]
        return true if gap > @x_tolerance

        # Row change (can happen if y_tolerance is large but two chars are
        # nonetheless on different rows)
        return true if (curr[:top] - prev[:top]).abs > @y_tolerance

        # Change of a required extra_attr
        @extra_attrs.any? { |attr| prev[attr] != curr[attr] }
      end

      def blank?(c)
        c[:char].nil? || c[:char].match?(/\A\s\z/) || c[:generated]
      end

      def build_word(chars)
        text   = +""
        x0     =  Float::INFINITY
        x1     = -Float::INFINITY
        top    =  Float::INFINITY
        bottom = -Float::INFINITY

        chars.each do |c|
          text   << c[:char]
          x0     = c[:x0]     if c[:x0]     < x0
          x1     = c[:x1]     if c[:x1]     > x1
          top    = c[:top]    if c[:top]    < top
          bottom = c[:bottom] if c[:bottom] > bottom
        end

        word = { text: text, x0: x0, x1: x1, top: top, bottom: bottom, chars: chars }
        @extra_attrs.each { |a| word[a] = chars.first[a] }
        word
      end
    end
  end
end
