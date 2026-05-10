# frozen_string_literal: true

module Rpdfium
  module Util
    # Estrazione testo "lineare" da una collezione di char, layout=False.
    # Equivalente di pdfplumber.utils.text.chars_to_textmap nella variante
    # senza preservazione del layout grafico.
    #
    # Algoritmo:
    #   1. Estrai words con WordExtractor (gli stessi tolerance).
    #   2. Cluster di words per `top` con y_tolerance → righe logiche.
    #   3. Per ogni riga, ordina per x0 e joina con singolo spazio.
    #   4. Joina le righe con "\n".
    #
    # NOTA su una sottigliezza: pdfplumber permette di usare x_tolerance
    # diverso da y_tolerance sia per word-extraction che per line-clustering.
    # Replichiamo questa flessibilità.
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

        # Cluster delle WORDS per top: righe di output finali.
        # Usa y_tolerance "di linea" — pdfplumber qui usa la stessa y_tolerance
        # passata, ed è coerente con come si comporta extract_text.
        line_clusters = Cluster.cluster_objects(words, :top, tolerance: y_tolerance)

        # Per ogni riga di output joina con spazio singolo.
        line_clusters.map do |line_words|
          line_words.sort_by { |w| w[:x0] }.map { |w| w[:text] }.join(" ")
        end.join("\n")
      end
    end
  end
end
