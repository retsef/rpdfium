# frozen_string_literal: true

module Rpdfium
  module Util
    # Inferenza di colonne dati su PDF non-tabellari.
    #
    # Identifica gruppi di word che appartengono alla stessa "colonna"
    # verticale di un layout (es. una colonna di importi in un modulo
    # prestampato) anche quando non ci sono linee disegnate.
    #
    # L'algoritmo opera in tre passaggi:
    #
    # 1. **Cluster per coordinata X** — raggruppa le word con la stessa x0
    #    (left-aligned) o x1 (right-aligned, tipico dei numeri) entro la
    #    tolleranza configurabile.
    #
    # 2. **Spezza per gap verticali** — se due word consecutive in un
    #    gruppo hanno un gap verticale "anomalo" (> 3× la mediana, o
    #    > 40pt), le separa in colonne distinte. Risolve casi tipo "codice
    #    fiscale in alto + tabella sotto" che condividono la stessa X.
    #
    # 3. **Filtra per densità** — una colonna "vera" ha valori regolarmente
    #    equispaziati (coefficiente di variazione dei gap < soglia). Esclude
    #    falsi positivi come valori isolati che si trovano per caso allineati.
    #
    # @example
    #   inference = Rpdfium::Util::ColumnInference.new(
    #     x_tolerance: 3.0,
    #     min_size: 3,
    #     cv_threshold: 0.15
    #   )
    #   columns = inference.infer(words)
    #   # => [
    #   #   [word1, word2, ..., word12],   # 12 importi nella colonna 1
    #   #   [word1, word2, ..., word12]    # 12 codici nella colonna 2
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

      # Inferisce le colonne dai word forniti. Usa sia x0 (left-align) che
      # x1 (right-align) come criteri di allineamento, ritorna l'unione
      # delle colonne identificate.
      #
      # @param words [Array<Hash>] word con :x0, :x1, :top
      # @return [Array<Array<Hash>>] array di colonne, ognuna è un array
      #   di word ordinati per :top crescente
      def infer(words)
        return [] if words.empty?

        by_x0 = cluster_by(words, :x0)
        by_x1 = cluster_by(words, :x1)

        # Unione: una word può apparire in più colonne. È compito del
        # chiamante decidere come gestire (es. preferire la prima
        # colonna, o quella più grande). Qui ritorniamo tutte.
        (by_x0 + by_x1)
      end

      # Cluster di word per una specifica coordinata.
      # @param coord [Symbol] :x0 o :x1
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

      # Una colonna è "abbastanza densa" se ha almeno min_size valori e
      # il coefficiente di variazione (std_dev/mean) dei gap verticali è
      # sotto la soglia. CV bassa = spacing regolare = colonna ripetitiva
      # vera (vs. valori sparsi accidentalmente allineati).
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
