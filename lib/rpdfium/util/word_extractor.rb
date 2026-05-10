# frozen_string_literal: true

module Rpdfium
  module Util
    # Estrae "words" da una lista di char, fedelmente a pdfplumber.WordExtractor.
    #
    # Algoritmo:
    #   1. Ordina i char per (top, x0): righe top-to-bottom, char left-to-right
    #      dentro ogni riga.
    #   2. Cluster per top con `y_tolerance` → "righe logiche" di char.
    #   3. Dentro ogni riga, cluster per gap orizzontale: due char sono nella
    #      stessa word se `next.x0 - prev.x1 <= x_tolerance`. Anche un char
    #      whitespace separa la word (a meno che `keep_blank_chars`).
    #   4. Per ogni cluster di char emette una word: text concatenato, bbox.
    #
    # Differenze da pdfplumber (semplificazioni accettabili per il nostro uso):
    #   - Non gestiamo `line_dir`/`char_dir` rotated (testo ruotato non
    #     orizzontale ltr): non rilevante per i casi d'uso correnti.
    #   - Non gestiamo `use_text_flow` (ordering basato sul content stream):
    #     i nostri char arrivano già da PDFium nell'ordine geometrico via
    #     `chars` (top, x0).
    #   - Non gestiamo `expand_ligatures`: PDFium di solito espande i
    #     codepoint correttamente già a livello char.
    #
    # Queste differenze sono documentate; se mai necessarie si aggiungono
    # come feature toggles senza cambiare il path di default.
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

      # Restituisce un Array di Hash: { text:, x0:, x1:, top:, bottom:, chars: }.
      # Se `extra_attrs` è non vuoto, ogni word splitta anche al cambio di
      # questi attributi (es. fontname/size diversi → word diverse).
      def extract_words(chars)
        return [] if chars.empty?

        # 1. Ordina per (top, x0). Top-down, left-to-right.
        sorted = chars.sort_by { |c| [c[:top], c[:x0]] }

        # 2. Cluster in righe per `top`.
        rows = Cluster.cluster_objects(sorted, :top, tolerance: @y_tolerance)

        words = []
        rows.each do |row|
          # Dentro la riga, ordina per x0 (importantissimo: il cluster_objects
          # mantiene l'ordine in cui i top arrivano, non quello x).
          row_sorted = row.sort_by { |c| c[:x0] }

          word_chars = []
          row_sorted.each do |c|
            if char_begins_new_word?(word_chars.last, c)
              words << build_word(word_chars) unless word_chars.empty?
              word_chars = []
            end
            # Whitespace: per default lo usiamo come separatore (lo scartiamo).
            # Con keep_blank_chars=true lo includiamo nella word corrente.
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

        # Gap orizzontale (PDF font hinting può dare overlap leggero, max 0)
        gap = curr[:x0] - prev[:x1]
        return true if gap > @x_tolerance

        # Cambio di riga (può succedere se y_tolerance è grande ma due
        # char sono comunque su righe diverse)
        return true if (curr[:top] - prev[:top]).abs > @y_tolerance

        # Cambio di un extra_attr richiesto
        @extra_attrs.any? { |attr| prev[attr] != curr[attr] }
      end

      def blank?(c)
        c[:char].nil? || c[:char].match?(/\A\s\z/) || c[:generated]
      end

      def build_word(chars)
        text = chars.map { |c| c[:char] }.join
        x0 = chars.map { |c| c[:x0] }.min
        x1 = chars.map { |c| c[:x1] }.max
        top = chars.map { |c| c[:top] }.min
        bottom = chars.map { |c| c[:bottom] }.max
        word = {
          text: text,
          x0: x0, x1: x1, top: top, bottom: bottom,
          chars: chars
        }
        # Riporta extra_attrs dal primo char (sono uniformi nella word)
        @extra_attrs.each { |a| word[a] = chars.first[a] }
        word
      end
    end
  end
end
