# frozen_string_literal: true

module Rpdfium
  module Table
    # Estrattore di tabelle ispirato a pdfplumber.
    #
    # STRATEGIE (settabili indipendentemente per asse vertical/horizontal):
    #   :lines    — usa segmenti vettoriali della pagina
    #   :text     — deduce edges dall'allineamento delle parole
    #   :explicit — usa solo gli edges in `explicit_*` lines
    #   :lines_strict — solo lines, senza fallback
    #
    # PIPELINE:
    #   1. raccogli candidate edges (per ogni asse)
    #   2. snap (collineari → stessa coord)
    #   3. join (segmenti contigui sulla stessa retta → un solo segmento)
    #   4. filter per lunghezza minima
    #   5. trova intersezioni h × v entro tolleranza
    #   6. costruisci celle (4 angoli presenti)
    #   7. raggruppa celle adiacenti in tabelle
    #   8. estrai testo da ogni cella via FPDFText_GetBoundedText
    class Extractor
      DEFAULTS = {
        vertical_strategy:   :lines,
        horizontal_strategy: :lines,
        explicit_vertical_lines:   [],   # Array<Numeric> (x coord) o Array<Hash>
        explicit_horizontal_lines: [],
        snap_tolerance:           3.0,
        snap_x_tolerance:         nil,   # eredita snap_tolerance se nil
        snap_y_tolerance:         nil,
        join_tolerance:           3.0,
        join_x_tolerance:         nil,
        join_y_tolerance:         nil,
        edge_min_length:          3.0,
        min_words_vertical:       3,
        min_words_horizontal:     1,
        intersection_tolerance:   3.0,
        intersection_x_tolerance: nil,
        intersection_y_tolerance: nil,
        text_tolerance:           3.0,
        text_x_tolerance:         nil,
        text_y_tolerance:         nil,
        keep_blank_chars:         false,
        # Auto-fallback: se :lines non produce nulla, riprova con :text
        auto_fallback:            true
      }.freeze

      def initialize(page, **opts)
        @page = page
        @opts = DEFAULTS.merge(opts)
        # Risolvi i tolerance a-cascata
        @snap_x = @opts[:snap_x_tolerance] || @opts[:snap_tolerance]
        @snap_y = @opts[:snap_y_tolerance] || @opts[:snap_tolerance]
        @join_x = @opts[:join_x_tolerance] || @opts[:join_tolerance]
        @join_y = @opts[:join_y_tolerance] || @opts[:join_tolerance]
        @inter_x = @opts[:intersection_x_tolerance] || @opts[:intersection_tolerance]
        @inter_y = @opts[:intersection_y_tolerance] || @opts[:intersection_tolerance]
        @text_x  = @opts[:text_x_tolerance] || @opts[:text_tolerance]
        @text_y  = @opts[:text_y_tolerance] || @opts[:text_tolerance]
      end

      # Trova le tabelle ma NON estrae il testo. Utile per debug/visualizzazione.
      def find
        h_edges, v_edges = build_edges
        return [] if h_edges.empty? && v_edges.empty? && !@opts[:auto_fallback]

        if (h_edges.empty? || v_edges.empty?) && @opts[:auto_fallback]
          # Fallback: prova text strategy se lines ha fallito
          h_edges, v_edges = build_edges_with_strategy(:text, :text) \
            if @opts[:vertical_strategy] != :text
        end

        ints = Edges.intersections(h_edges, v_edges,
                                    x_tol: @inter_x, y_tol: @inter_y)
        cells = Cells.from_intersections(ints)
        Cells.group_into_tables(cells)
      end

      # Estrae direttamente i dati: Array<Array<Array<String>>>.
      def extract
        find.map { |table| extract_text_from_table(table) }
      end

      private

      def build_edges
        build_edges_with_strategy(@opts[:vertical_strategy],
                                   @opts[:horizontal_strategy])
      end

      def build_edges_with_strategy(vertical_strategy, horizontal_strategy)
        v_edges = vertical_edges(vertical_strategy) +
                  explicit_vertical_edges
        h_edges = horizontal_edges(horizontal_strategy) +
                  explicit_horizontal_edges

        h_norm = Edges.normalize_horizontal(h_edges,
          snap_tol: @snap_y, join_tol: @join_x,
          min_length: @opts[:edge_min_length])
        v_norm = Edges.normalize_vertical(v_edges,
          snap_tol: @snap_x, join_tol: @join_y,
          min_length: @opts[:edge_min_length])

        [h_norm, v_norm]
      end

      # ----- Sources di edges -----

      def vertical_edges(strategy)
        case strategy
        when :lines, :lines_strict then @page.vertical_lines
        when :text                 then text_vertical_edges
        when :explicit             then []
        else []
        end
      end

      def horizontal_edges(strategy)
        case strategy
        when :lines, :lines_strict then @page.horizontal_lines
        when :text                 then text_horizontal_edges
        when :explicit             then []
        else []
        end
      end

      def explicit_vertical_edges
        page_h = @page.height
        @opts[:explicit_vertical_lines].map do |item|
          case item
          when Numeric
            { x: item.to_f, top: 0.0, bottom: page_h }
          when Hash
            { x: item[:x], top: item.fetch(:top, 0.0),
              bottom: item.fetch(:bottom, page_h) }
          end
        end.compact
      end

      def explicit_horizontal_edges
        page_w = @page.width
        @opts[:explicit_horizontal_lines].map do |item|
          case item
          when Numeric
            { y: item.to_f, x0: 0.0, x1: page_w }
          when Hash
            { y: item[:y], x0: item.fetch(:x0, 0.0),
              x1: item.fetch(:x1, page_w) }
          end
        end.compact
      end

      # ----- Strategy :text -----
      #
      # L'idea: i confini di colonna sono dove molte parole iniziano alla
      # stessa x. I confini di riga sono dove molte parole hanno la stessa
      # top y. pdfplumber ha varianti più sofisticate (left/right/center),
      # qui usiamo "left" che è il più solido.

      def text_vertical_edges
        words = @page.words(x_tolerance: @text_x, y_tolerance: @text_y)
        return [] if words.empty?

        # Cluster di word.x0 (start)
        x_clusters = cluster_by(words.map { |w| w[:x0] }, @snap_x)
        # Solo cluster che contengono >= min_words_vertical
        page_h = @page.height
        x_clusters.select { |c| c.size >= @opts[:min_words_vertical] }
                  .map { |c| { x: c.sum / c.size.to_f, top: 0.0, bottom: page_h } }
      end

      def text_horizontal_edges
        words = @page.words(x_tolerance: @text_x, y_tolerance: @text_y)
        return [] if words.empty?

        page_w = @page.width
        y_clusters = cluster_by(words.map { |w| w[:top] }, @snap_y)
        y_clusters.select { |c| c.size >= @opts[:min_words_horizontal] }
                  .map { |c| { y: c.sum / c.size.to_f, x0: 0.0, x1: page_w } }
      end

      def cluster_by(values, tol)
        return [] if values.empty?

        sorted = values.sort
        clusters = [[sorted.first]]
        sorted[1..].each do |v|
          if (v - clusters.last.last).abs <= tol
            clusters.last << v
          else
            clusters << [v]
          end
        end
        clusters
      end

      # ----- Estrazione testo da una cella -----

      def extract_text_from_table(table)
        table[:grid].map do |row|
          row.map { |c| c.nil? ? "" : extract_cell_text(c) }
        end
      end

      def extract_cell_text(cell)
        # Niente padding: PDFium include i char il cui CENTRO cade dentro
        # la bbox, quindi un char esattamente sul bordo non viene tagliato.
        # Il padding di 0.5 era un over-engineering: causava taglio di
        # glifi che toccavano il bordo della cella e PDFium reinseriva
        # spazi sintetici per coprire i "buchi" risultanti.
        raw = @page.text_in_bbox(
          left:   cell[:x0],
          right:  cell[:x1],
          top:    cell[:top],
          bottom: cell[:bottom]
        )
        # Normalizza whitespace interno: PDFium può inserire \r, \n, o
        # multiple spazi tra char di una stessa parola se il layout è
        # complesso (multi-line cell).
        raw.gsub(/\s+/, " ").strip
      end
    end
  end
end
