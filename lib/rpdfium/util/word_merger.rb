# frozen_string_literal: true

module Rpdfium
  module Util
    # Merges adjacent words on the same row into a single word with an
    # aggregated bbox and concatenated text.
    #
    # Three strategies are available as separate methods:
    #
    # - `merge_by_proximity` — merges all adjacent words that satisfy the
    #   proximity criterion. Base strategy.
    #
    # - `merge_by_label` — merges only words that share the same "label"
    #   (external key computed by the caller). Useful for preserving
    #   semantics when different labels fall on the same row (e.g. flags
    #   in adjacent columns).
    #
    # - `merge_unlabeled` — merges only "orphan" words (label nil), leaving
    #   labeled ones intact. Inverse of merge_by_label.
    #
    # All return a new list of words, with merged ones represented as the
    # hash `{ text:, x0:, x1:, top:, bottom: }`.
    #
    # @example merge by proximity
    #   merger = Rpdfium::Util::WordMerger.new(x_gap: 20.0, y_tol: 3.0)
    #   merged = merger.merge_by_proximity(words)
    #
    # @example merge by label, with the label provided by the caller
    #   labels_by_word = words.each_with_object({}) { |w, h| h[w] = compute_label(w) }
    #   merged = merger.merge_by_label(words, labels_by_word)
    class WordMerger
      DEFAULT_X_GAP = 20.0
      DEFAULT_Y_TOL = 3.0

      def initialize(x_gap: DEFAULT_X_GAP, y_tol: DEFAULT_Y_TOL)
        @x_gap = x_gap
        @y_tol = y_tol
      end

      # Merges all adjacent words (same row + horizontal gap ≤ x_gap).
      def merge_by_proximity(words)
        merge_groups(words) { |a, b| true }
      end

      # Merges only words with the same label.
      # @param labels_by_word [Hash] mapping word → label (any type).
      #   Words with the same label are merged; words with different
      #   labels are not.
      def merge_by_label(words, labels_by_word)
        merge_groups(words) do |a, b|
          labels_by_word[a] == labels_by_word[b]
        end
      end

      # Merges only words with a nil label (orphans).
      def merge_unlabeled(words, labels_by_word)
        merge_groups(words) do |a, b|
          labels_by_word[a].nil? && labels_by_word[b].nil?
        end
      end

      private

      # Generic merging algorithm: iterates over the words sorted by
      # (top, x0) and groups them when they satisfy both the geometric
      # criterion (same row and narrow horizontal gap) and the `yield`
      # predicate provided by the caller.
      def merge_groups(words)
        return [] if words.empty?

        sorted = words.sort_by { |w| [w[:top].round(1), w[:x0]] }
        groups = []
        current = [sorted.first]
        sorted.drop(1).each do |w|
          prev = current.last
          on_same_row = (w[:top] - prev[:top]).abs <= @y_tol
          adjacent = w[:x0] - prev[:x1] <= @x_gap && w[:x0] >= prev[:x0]
          if on_same_row && adjacent && yield(prev, w)
            current << w
          else
            groups << current
            current = [w]
          end
        end
        groups << current

        groups.map { |g| merge_group(g) }
      end

      def merge_group(group)
        return group.first if group.size == 1

        {
          text: group.map { |w| w[:text] }.join(" "),
          x0: group.map { |w| w[:x0] }.min,
          x1: group.map { |w| w[:x1] }.max,
          top: group.map { |w| w[:top] }.min,
          bottom: group.map { |w| w[:bottom] }.max
        }
      end
    end
  end
end
