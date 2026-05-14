# frozen_string_literal: true

module Rpdfium
  module Table
    # Rappresenta una tabella trovata su una pagina. Espone celle, righe,
    # colonne, bbox, e il metodo `extract` che ritorna i dati testuali.
    #
    # Ogni cella è una bbox `[x0, top, x1, bottom]` (top-down).
    # Una "row" è il gruppo di celle che condividono la stessa `top`.
    # Una "column" è il gruppo che condivide la stessa `x0`.
    class Table
      attr_reader :page, :cells

      def initialize(page, cells)
        @page = page
        @cells = cells
      end

      def bbox
        @cells.each_with_object(
          [Float::INFINITY, Float::INFINITY, -Float::INFINITY, -Float::INFINITY]
        ) do |c, acc|
          acc[0] = c[0] if c[0] < acc[0]
          acc[1] = c[1] if c[1] < acc[1]
          acc[2] = c[2] if c[2] > acc[2]
          acc[3] = c[3] if c[3] > acc[3]
        end
      end

      # Restituisce le righe come Array<Array<bbox|nil>>. Le celle "mancanti"
      # in una riga (es. perché la tabella ha una topologia irregolare) sono
      # rappresentate come nil — coerente con pdfplumber.
      def rows
        rows_or_columns(:row)
      end

      def columns
        rows_or_columns(:col)
      end

      # Estrai dati: Array<Array<String>>. Per ogni riga, per ogni cella,
      # filtra i char della pagina il cui MIDPOINT è nella bbox della cella,
      # poi ricostruisce il testo via Util::TextExtraction (che a sua volta
      # passa da WordExtractor).
      #
      # Questo è il path di pdfplumber.Table.extract — per ogni riga prima
      # filtra i char della riga (ottimizzazione: quasi tutti i char delle
      # altre righe vengono scartati subito), poi per ogni cella filtra
      # ancora dentro la sub-bbox.
      #
      # Ottimizzazione rispetto al path naïve: i char vengono ordinati per
      # midpoint verticale una sola volta; per ogni riga si usa bsearch per
      # trovare in O(log n) i char candidati invece di scansionare tutto
      # l'array O(n) per ogni riga.
      #
      # NOTA su strategia :text: `words_to_edges_h` emette per design DUE
      # edges per riga (top e bottom della bbox del cluster). Significa che
      # una tabella detectata da text-strategy avrà righe "vere" intervallate
      # da righe "vuote" tra il bottom-edge della riga N e il top-edge della
      # riga N+1. Questo è identico al comportamento di pdfplumber. Il
      # caller può filtrare via `result.reject { |row| row.all?(&:empty?) }`
      # se vuole eliminarle.
      # `cell_padding`: estende il bbox di ogni cella verso sinistra e verso
      # l'alto di N punti. Default 0 (= comportamento pdfplumber identico).
      # Utile per PDF dove i char sporgono leggermente dal bordo della cella
      # (es. la "I" maiuscola della cella "Intermediario" in CR Banca d'Italia
      # ha x0=24.0 ma il bordo della cella è a x=25.6 — viene scartata dal
      # filtro midpoint, output "ntermediario:"). Con `cell_padding: 2.0` la
      # cella diventa [23.6, ..., 100, ...] e la "I" viene catturata.
      #
      # Padding solo sui bordi "interno-sinistro" e "interno-alto" per
      # evitare di duplicare char condivisi tra celle adiacenti (un char tra
      # cella A e cella B finirebbe in entrambe se entrambe paddassero su
      # tutti i lati).
      def extract(x_tolerance: Util::WordExtractor::DEFAULT_X_TOLERANCE,
                  y_tolerance: Util::WordExtractor::DEFAULT_Y_TOLERANCE,
                  keep_blank_chars: false,
                  cell_padding: 0.0)
        # `lean: true`: salta 5 chiamate FFI per char (font name, weight,
        # angle, hyphen flag, unicode error) che non servono al pipeline
        # di estrazione tabelle. Su tabelle con migliaia di char riduce
        # il tempo di compute_chars del ~30%.
        chars = @page.chars(lean: true)

        # Ordina per midpoint verticale una volta sola; costruisce un array
        # parallelo di vmid per bsearch. Costo: O(n log n) una tantum.
        sorted_chars = chars.sort_by { |c| (c[:top] + c[:bottom]) / 2.0 }
        vmids = sorted_chars.map { |c| (c[:top] + c[:bottom]) / 2.0 }

        # Istanzia WordExtractor UNA volta sola e riusalo per tutte le celle
        # (può esserci una tabella con decine di celle, evitiamo allocazioni).
        word_extractor = Util::WordExtractor.new(
          x_tolerance: x_tolerance,
          y_tolerance: y_tolerance,
          keep_blank_chars: keep_blank_chars
        )

        all_rows = rows
        all_rows.map do |row|
          row_bbox = row_bounding_box(row)
          lo = vmids.bsearch_index { |v| v >= row_bbox[1] - cell_padding } || sorted_chars.size
          hi = vmids.bsearch_index { |v| v >= row_bbox[3] } || sorted_chars.size
          row_chars = sorted_chars[lo...hi]

          row.map do |cell|
            next nil if cell.nil?

            padded = cell_padding.zero? ? cell : pad_cell_bbox(cell, cell_padding)
            cell_chars = row_chars.select { |c| char_in_bbox?(c, padded) }
            if cell_chars.empty?
              ""
            else
              extract_text_with(cell_chars, word_extractor, y_tolerance)
            end
          end
        end
      end

      private

      # Versione "inlined" di Util::TextExtraction.extract_text che riusa
      # un WordExtractor preesistente invece di crearlo ogni volta.
      def extract_text_with(chars, word_extractor, y_tolerance)
        words = word_extractor.extract_words(chars)
        return "" if words.empty?

        line_clusters = Util::Cluster.cluster_objects(words, :top, tolerance: y_tolerance)
        line_clusters.map do |line_words|
          line_words.sort_by { |w| w[:x0] }.map { |w| w[:text] }.join(" ")
        end.join("\n")
      end

      def pad_cell_bbox(bbox, padding)
        x0, top, x1, bottom = bbox
        # Estendi solo i bordi "interno-sinistro" e "interno-alto" per evitare
        # di catturare char della cella adiacente destra/sotto.
        [x0 - padding, top - padding, x1, bottom]
      end

      # Test "char midpoint dentro bbox" — esattamente come pdfplumber.
      # Il midpoint del char (non gli estremi della bbox) è il criterio:
      # un char a cavallo del bordo viene assegnato alla cella in cui ha
      # più "peso visivo".
      def char_in_bbox?(char, bbox)
        x0, top, x1, bottom = bbox
        h_mid = (char[:x0] + char[:x1]) / 2.0
        v_mid = (char[:top] + char[:bottom]) / 2.0
        h_mid >= x0 && h_mid < x1 && v_mid >= top && v_mid < bottom
      end

      def row_bounding_box(row)
        row.compact.each_with_object(
          [Float::INFINITY, Float::INFINITY, -Float::INFINITY, -Float::INFINITY]
        ) do |c, acc|
          acc[0] = c[0] if c[0] < acc[0]
          acc[1] = c[1] if c[1] < acc[1]
          acc[2] = c[2] if c[2] > acc[2]
          acc[3] = c[3] if c[3] > acc[3]
        end
      end

      # Ricostruisce righe o colonne. axis 0 = x (per row clustering antiaxis=top),
      # axis 1 = top (per column clustering antiaxis=x0). Usa il key invariante
      # come "anchor" e il key variabile come ordering interno.
      def rows_or_columns(kind)
        # Per row: sortBy = top, antiaxis = x0
        # Per col: sortBy = x0, antiaxis = top
        sort_idx, group_idx = kind == :row ? [1, 0] : [0, 1]

        # Tutti gli x0 (per row) o top (per col) distinti, sortati
        all_keys = @cells.map { |c| c[group_idx] }.uniq.sort

        # Group by sort_idx
        sorted_cells = @cells.sort_by { |c| [c[sort_idx], c[group_idx]] }
        grouped = sorted_cells.chunk_while { |a, b| a[sort_idx] == b[sort_idx] }.to_a

        grouped.map do |group_cells|
          by_anchor = group_cells.to_h { |c| [c[group_idx], c] }
          all_keys.map { |k| by_anchor[k] }
        end
      end
    end
  end
end
