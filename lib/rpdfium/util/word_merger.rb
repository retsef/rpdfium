# frozen_string_literal: true

module Rpdfium
  module Util
    # Fonde word adiacenti sulla stessa riga in un'unica word con bbox
    # aggregata e text concatenato.
    #
    # Tre strategie disponibili come metodi separati:
    #
    # - `merge_by_proximity` — fonde tutte le word adiacenti che soddisfano
    #   il criterio di vicinanza. Strategia base.
    #
    # - `merge_by_label` — fonde solo word che condividono la stessa "label"
    #   (chiave esterna calcolata dal chiamante). Utile per preservare la
    #   semantica quando label diverse cadono sulla stessa riga (es. flag
    #   in colonne adiacenti).
    #
    # - `merge_unlabeled` — fonde solo word "orfane" (label nil) lasciando
    #   intatte quelle con label. Inverso di merge_by_label.
    #
    # Tutte ritornano una nuova lista di word, con quelle fuse rappresentate
    # come hash `{ text:, x0:, x1:, top:, bottom: }`.
    #
    # @example merge per proximity
    #   merger = Rpdfium::Util::WordMerger.new(x_gap: 20.0, y_tol: 3.0)
    #   merged = merger.merge_by_proximity(words)
    #
    # @example merge per label, con label fornita dal chiamante
    #   labels_by_word = words.each_with_object({}) { |w, h| h[w] = compute_label(w) }
    #   merged = merger.merge_by_label(words, labels_by_word)
    class WordMerger
      DEFAULT_X_GAP = 20.0
      DEFAULT_Y_TOL = 3.0

      def initialize(x_gap: DEFAULT_X_GAP, y_tol: DEFAULT_Y_TOL)
        @x_gap = x_gap
        @y_tol = y_tol
      end

      # Fonde tutte le word adiacenti (stessa riga + gap orizzontale ≤ x_gap).
      def merge_by_proximity(words)
        merge_groups(words) { |a, b| true }
      end

      # Fonde solo word con la stessa label.
      # @param labels_by_word [Hash] mapping word → label (qualunque tipo).
      #   Word con stessa label vengono fuse, word con label diverse no.
      def merge_by_label(words, labels_by_word)
        merge_groups(words) do |a, b|
          labels_by_word[a] == labels_by_word[b]
        end
      end

      # Fonde solo word con label nil (orfane).
      def merge_unlabeled(words, labels_by_word)
        merge_groups(words) do |a, b|
          labels_by_word[a].nil? && labels_by_word[b].nil?
        end
      end

      private

      # Algoritmo generico di merging: scorre i word ordinati per (top, x0)
      # e li raggruppa quando soddisfano sia il criterio geometrico
      # (stessa riga e gap orizzontale stretto) che il predicato `yield`
      # fornito dal chiamante.
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
