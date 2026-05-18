# frozen_string_literal: true

module Rpdfium
  module Util
    # Associa label semantiche a valori inseriti su PDF di moduli compilati
    # (F24, comunicazioni IVA, modelli 770, dichiarazioni). Su questi PDF
    # il modello prestampato e i dati coesistono come testo grafico:
    # `Page#chars_where(font: ...)` separa i due layer, `LabelMatcher`
    # associa ai valori la loro etichetta semantica nel template.
    #
    # Strategia in 3 step:
    #
    # 1. **Cluster** le parole del template in "label coerenti": word
    #    geometricamente vicine (stessa riga adiacenti, o righe successive
    #    in colonna) formano un'unica label semantica. Esempio: "importi"
    #    + "a" + "debito" + "versati" → label unica "importi a debito
    #    versati" (frase di 4 parole su 1-2 righe).
    #
    # 2. **Per ogni valore**, cerca due tipi di label:
    #    - `:col` — label SOPRA in stessa colonna (x sovrapposto col valore,
    #      bottom < value top, scelta più vicina verticalmente). Tipico
    #      ruolo: nome del campo/colonna ("importi a debito versati").
    #    - `:row` — label A SINISTRA in stessa riga (y sovrapposto col
    #      valore, x1 < value x0, scelta più vicina orizzontalmente).
    #      Tipico ruolo: identificatore di riga ("TOTALE A", "B",
    #      "SALDO (A-B)").
    #
    # 3. **Ritorna** un Array di Hash `{ value:, labels: { col:, row: }, geometry: }`.
    #
    # I parametri sono tutti opzionali con default sensati per moduli
    # italiani A4 (F24, Agenzia Entrate, INPS). Tarali se i tuoi moduli
    # hanno densità diversa.
    class LabelMatcher
      # Massima distanza verticale label SOPRA → valore (punti)
      DEFAULT_COL_MAX_DY = 80.0
      # Massima distanza orizzontale label SINISTRA → valore (punti)
      DEFAULT_ROW_MAX_DX = 200.0
      # Tolleranza overlap x per "label sopra in stessa colonna"
      DEFAULT_COL_X_TOLERANCE = 10.0
      # Tolleranza overlap y per "label sinistra in stessa riga"
      DEFAULT_ROW_Y_TOLERANCE = 2.0

      # Cluster dell'anchor (template) word-to-word: stessa riga
      DEFAULT_CLUSTER_SAME_ROW_DY = 4.0
      DEFAULT_CLUSTER_SAME_ROW_DX = 12.0
      # Cluster anchor: righe adiacenti con x sovrapposto
      DEFAULT_CLUSTER_ADJ_ROW_DY = 4.0

      def initialize(col_max_dy: DEFAULT_COL_MAX_DY,
                     row_max_dx: DEFAULT_ROW_MAX_DX,
                     col_x_tolerance: DEFAULT_COL_X_TOLERANCE,
                     row_y_tolerance: DEFAULT_ROW_Y_TOLERANCE,
                     cluster_same_row_dy: DEFAULT_CLUSTER_SAME_ROW_DY,
                     cluster_same_row_dx: DEFAULT_CLUSTER_SAME_ROW_DX,
                     cluster_adj_row_dy: DEFAULT_CLUSTER_ADJ_ROW_DY)
        @col_max_dy = col_max_dy
        @row_max_dx = row_max_dx
        @col_x_tolerance = col_x_tolerance
        @row_y_tolerance = row_y_tolerance
        @cluster_same_row_dy = cluster_same_row_dy
        @cluster_same_row_dx = cluster_same_row_dx
        @cluster_adj_row_dy = cluster_adj_row_dy
      end

      # Calcola le associazioni label → valore.
      #
      # @param values [Array<Hash>] word del layer "dati" (formato pdfplumber:
      #   text, x0, x1, top, bottom). Tipicamente ottenuto da:
      #   `WordExtractor.new.extract_words(page.chars_where(font: ...))`.
      # @param anchors [Array<Hash>] word del layer "template", stesso formato.
      #
      # @return [Array<Hash>] uno per valore in `values`, nella stessa
      #   sequenza dell'input. Ogni elemento:
      #     {
      #       value: "499,81",            # text del valore
      #       labels: {
      #         col: "importi a debito versati",   # o nil
      #         row: "TOTALE A"                     # o nil
      #       },
      #       geometry: { x0:, x1:, top:, bottom: }
      #     }
      def match(values, anchors)
        labels = cluster_anchors(anchors)
        values.map do |v|
          col = find_col_label(v, labels)
          row = find_row_label(v, labels)
          {
            value: v[:text],
            labels: {
              col: col&.dig(:text),
              row: row&.dig(:text)
            },
            geometry: {
              x0: v[:x0], x1: v[:x1], top: v[:top], bottom: v[:bottom]
            }
          }
        end
      end

      # Esposto come API pubblica: ricostruisce le label dai word del template.
      # Utile per ispezionare cosa il matcher considera label.
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
                # Righe adiacenti con x sovrapposto
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
        groups.map { |g| group_to_label(g) }
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
        vx = (value[:x0] + value[:x1]) / 2.0
        labels.select do |l|
          l[:x0] - @col_x_tolerance <= vx &&
            l[:x1] + @col_x_tolerance >= vx &&
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
    end
  end
end
