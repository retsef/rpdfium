# frozen_string_literal: true

module Rpdfium
  module Util
    # Associa label semantiche a valori inseriti su PDF di moduli compilati
    # (F24, comunicazioni IVA, modelli 770, dichiarazioni). Su questi PDF
    # il modello prestampato e i dati coesistono come testo grafico:
    # `Page#chars_where(font: ...)` separa i due layer, `LabelMatcher`
    # associa ai valori la loro etichetta semantica nel template.
    #
    # Strategia:
    #
    # 1. **Cluster** le parole del template in "label coerenti": word
    #    geometricamente vicine (stessa riga adiacenti, o righe successive
    #    in colonna) formano un'unica label semantica.
    #
    # 2. **Per ogni valore**, cerca due tipi di label:
    #    - `:col` — label SOPRA in stessa colonna (più vicina verticalmente).
    #    - `:row` — label A SINISTRA in stessa riga (più vicina orizzontalmente).
    #
    # 3. **Riassegnazione per tabelle ripetitive** (opt: `repeat_headers:`):
    #    identifica colonne dati (≥3 valori con stessa x) e propaga
    #    l'header canonico stampato in cima alla colonna a TUTTI i valori
    #    della colonna, anche oltre `col_max_dy`. Risolve casi tipo 770
    #    Quadro ST dove ST3, ST4, ..., ST13 ereditano le intestazioni
    #    stampate solo sopra ST2.
    class LabelMatcher
      DEFAULT_COL_MAX_DY = 80.0
      DEFAULT_ROW_MAX_DX = 200.0
      DEFAULT_COL_X_TOLERANCE = 10.0
      DEFAULT_ROW_Y_TOLERANCE = 2.0
      DEFAULT_CLUSTER_SAME_ROW_DY = 4.0
      DEFAULT_CLUSTER_SAME_ROW_DX = 12.0
      DEFAULT_CLUSTER_ADJ_ROW_DY = 4.0
      DEFAULT_IGNORE_LABEL_PATTERN = /\A\d{1,3}\z|\A[IVX]{1,5}\z/.freeze
      DEFAULT_COLUMN_X_TOLERANCE = 3.0
      DEFAULT_MIN_COLUMN_SIZE = 3

      def initialize(col_max_dy: DEFAULT_COL_MAX_DY,
                     row_max_dx: DEFAULT_ROW_MAX_DX,
                     col_x_tolerance: DEFAULT_COL_X_TOLERANCE,
                     row_y_tolerance: DEFAULT_ROW_Y_TOLERANCE,
                     cluster_same_row_dy: DEFAULT_CLUSTER_SAME_ROW_DY,
                     cluster_same_row_dx: DEFAULT_CLUSTER_SAME_ROW_DX,
                     cluster_adj_row_dy: DEFAULT_CLUSTER_ADJ_ROW_DY,
                     ignore_label_pattern: DEFAULT_IGNORE_LABEL_PATTERN,
                     repeat_headers: true,
                     column_x_tolerance: DEFAULT_COLUMN_X_TOLERANCE,
                     min_column_size: DEFAULT_MIN_COLUMN_SIZE)
        @col_max_dy = col_max_dy
        @row_max_dx = row_max_dx
        @col_x_tolerance = col_x_tolerance
        @row_y_tolerance = row_y_tolerance
        @cluster_same_row_dy = cluster_same_row_dy
        @cluster_same_row_dx = cluster_same_row_dx
        @cluster_adj_row_dy = cluster_adj_row_dy
        @ignore_label_pattern = ignore_label_pattern
        @repeat_headers = repeat_headers
        @column_x_tolerance = column_x_tolerance
        @min_column_size = min_column_size
      end

      # Calcola le associazioni label → valore.
      def match(values, anchors)
        labels = cluster_anchors(anchors)

        prelim = values.map do |v|
          col = find_col_label(v, labels)
          row = find_row_label(v, labels)
          { value: v, col: col, row: row }
        end

        prelim = reassign_by_columns(prelim, labels, values) if @repeat_headers

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
        value_width = value[:x1] - value[:x0]
        anchor_point =
          if value_width > 60.0
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

      # Identifica colonne dati e propaga l'header canonico stampato in
      # cima alla colonna a TUTTI i valori della colonna.
      def reassign_by_columns(prelim, labels, values)
        # Identifica colonne sia per allineamento a SINISTRA (x0) che a
        # DESTRA (x1). I valori numerici nei moduli prestampati sono
        # right-aligned: importi come "499,81" (x0=250) e "1.227,70"
        # (x0=238) hanno x0 diversi ma x1 simile, sono nella stessa colonna.
        col_groups_x0 = cluster_columns_by(values, :x0)
        col_groups_x1 = cluster_columns_by(values, :x1)

        # Unisco le colonne assegnando ad ogni valore la "migliore" tra le
        # due (quella con più valori, perché più probabile sia colonna vera)
        all_columns = (col_groups_x0 + col_groups_x1)

        # Costruisco column_headers preferendo le colonne più larghe
        # (più valori = maggiore evidenza statistica)
        sorted_columns = all_columns.sort_by { |c| -c.size }

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
            # Non sovrascrivere assegnazioni già fatte (rispetto priorità
            # colonna più grande). Garantisce idempotenza.
            column_headers[v.object_id] ||= header
          end
        end

        prelim.map do |entry|
          v = entry[:value]
          new_col = column_headers[v.object_id]
          new_col ? entry.merge(col: new_col) : entry
        end
      end

      # Cluster di valori per coordinata (x0 = left-align, x1 = right-align).
      # Spezza colonne con gap verticali grandi (interruzioni di sezione).
      # Filtra colonne a bassa densità (probabilmente false colonne).
      def cluster_columns_by(values, coord)
        sorted = values.sort_by { |v| v[coord] }
        x_groups = []
        current = []
        sorted.each do |v|
          if current.empty? || (v[coord] - current.last[coord]).abs <= @column_x_tolerance
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
            columns << sorted_y if column_dense_enough?(sorted_y)
            next
          end
          median_gap = gaps.sort[gaps.size / 2]
          threshold = [median_gap * 3, 40.0].max

          sub = [sorted_y.first]
          sorted_y.each_cons(2) do |a, b|
            gap = b[:top] - a[:top]
            if gap > threshold
              columns << sub if column_dense_enough?(sub)
              sub = [b]
            else
              sub << b
            end
          end
          columns << sub if column_dense_enough?(sub)
        end
        columns
      end

      # Una "colonna vera" di tabella ripetitiva ha alta densità: i valori
      # sono regolarmente spaziati nel range verticale che coprono. Una
      # falsa colonna (es. 5 saldi di sezioni diverse del F24 allineati a
      # destra) ha bassa densità o spacing irregolare.
      #
      # Misura: la **deviazione standard** dei gap consecutivi deve essere
      # piccola rispetto alla media (coefficiente di variazione < 0.5).
      # Inoltre richiediamo min_column_size valori.
      def column_dense_enough?(col_values)
        return false if col_values.size < @min_column_size

        sorted_y = col_values.sort_by { |v| v[:top] }
        gaps = sorted_y.each_cons(2).map { |a, b| b[:top] - a[:top] }
        return true if gaps.size < 2  # troppo pochi per stimare CV

        mean = gaps.sum / gaps.size.to_f
        variance = gaps.map { |g| (g - mean)**2 }.sum / gaps.size
        std_dev = Math.sqrt(variance)
        cv = mean.zero? ? Float::INFINITY : std_dev / mean

        # CV bassa = spacing molto regolare = colonna vera ripetitiva.
        # Soglia stretta per evitare falsi positivi: 0.15 accetta solo
        # tabelle con righe quasi equispaziate.
        cv < 0.15
      end
    end
  end
end
