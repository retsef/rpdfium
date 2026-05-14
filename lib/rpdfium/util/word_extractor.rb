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

        # Fast path: 1 solo char → 1 word triviale (se non whitespace).
        if chars.size == 1
          c = chars.first
          return [] if blank?(c) && !@keep_blank_chars

          return [build_word([c])]
        end

        # 1. Ordina per (top, x0). Top-down, left-to-right.
        sorted = chars.sort_by { |c| [c[:top], c[:x0]] }

        # 2. Cluster in righe per `top`.
        # `presorted: true`: sorted è già ordinato per [top, x0], quindi
        # implicitamente anche per top — cluster_objects salta il proprio
        # sort interno.
        rows = Cluster.cluster_objects(sorted, :top,
                                        tolerance: @y_tolerance,
                                        presorted: true)

        words = []
        rows.each do |row|
          # Re-sort per x0 dentro ogni riga clusterizzata.
          #
          # NOTA: in linea di principio l'input `sorted` è già ordinato per
          # [top, x0], quindi i cluster di top dovrebbero essere già in
          # ordine x0. MA il sort globale `[top, x0]` rispetta strettamente
          # l'ordine per top — se due char della stessa riga visiva hanno
          # top diversi entro tolerance (es. la "i" minuscola spesso ha
          # top più alto di 0.008pt rispetto alle altre lettere a causa di
          # come PDFium calcola la bbox), il sort globale li interfoglia.
          # Il cluster_objects per :top non riordina internamente i char,
          # quindi un char con top leggermente minore finisce DAVANTI a
          # tutte le altre lettere della parola.
          #
          # Esempio reale: "Categoria" dove "i" ha top=414.9789 e le altre
          # 414.9869 → output `iCategora` invece di `Categoria`.
          # Il fix è semplicemente ri-sortare per x0 dentro la riga.
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
