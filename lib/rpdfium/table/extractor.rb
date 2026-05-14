# frozen_string_literal: true

module Rpdfium
  module Table
    # Trova tabelle su una pagina, fedele al `pdfplumber.TableFinder`.
    #
    # Pipeline:
    #   1. raccogli edges candidati per ogni asse, secondo strategia
    #      (`:lines` / `:lines_strict` / `:text` / `:explicit`)
    #   2. merge_edges (snap collineari + join contigui)
    #   3. filter per lunghezza minima
    #   4. edges_to_intersections con tolerance
    #   5. intersections_to_cells (smallest cell per ogni punto)
    #   6. cells_to_tables (grouping per corner condivisi)
    #
    # API pubblica:
    #   ext = Rpdfium::Table::Extractor.new(page, **opts)
    #   ext.tables           # => [Table, ...]   (oggetti Rpdfium::Table::Table)
    #   ext.extract          # => [[[String]]]   (Array di tabelle, ogni tabella
    #                                              è Array di righe, ogni riga
    #                                              è Array di stringhe)
    #   ext.find             # alias di .tables (compat back con 0.2.x)
    #   ext.edges            # edges raffinati
    #   ext.intersections    # Hash {[x,y] => {v:[],h:[]}}
    #   ext.cells            # Array<bbox>
    class Extractor
      DEFAULTS = {
        vertical_strategy:   :lines,
        horizontal_strategy: :lines,
        explicit_vertical_lines:   [],
        explicit_horizontal_lines: [],

        # Tolleranze. I `_x_` / `_y_` ereditano dal valore non-suffisso.
        snap_tolerance:           3.0,
        snap_x_tolerance:         nil,
        snap_y_tolerance:         nil,
        join_tolerance:           3.0,
        join_x_tolerance:         nil,
        join_y_tolerance:         nil,

        edge_min_length:           3.0,
        edge_min_length_prefilter: 1.0,

        min_words_vertical:   Edges::DEFAULT_MIN_WORDS_VERTICAL,
        min_words_horizontal: Edges::DEFAULT_MIN_WORDS_HORIZONTAL,

        intersection_tolerance:   3.0,
        intersection_x_tolerance: nil,
        intersection_y_tolerance: nil,

        # Settings testo (passati a TextExtraction quando si chiama .extract).
        # I default 3.0 sono quelli di pdfplumber.
        text_x_tolerance: Util::WordExtractor::DEFAULT_X_TOLERANCE,
        text_y_tolerance: Util::WordExtractor::DEFAULT_Y_TOLERANCE,
        text_keep_blank_chars: false,

        # Auto-fallback: se :lines non produce edges, riprova con :text.
        # Manteniamo il flag (era già in 0.2.x) ma SOLO come fallback,
        # mai come "fix" su layout patologici — coerente con pdfplumber che
        # non lo ha (chi usa pdfplumber sa che deve scegliere la strategia).
        auto_fallback: true
      }.freeze

      VALID_STRATEGIES = %i[lines lines_strict text explicit].freeze

      attr_reader :page, :settings

      def initialize(page, **opts)
        @page = page
        @settings = resolve_settings(DEFAULTS.merge(opts))
        validate_strategies!
      end

      # Pipeline completa, costruisce gli edges raffinati.
      def edges
        @edges ||= build_edges(@settings[:vertical_strategy],
                               @settings[:horizontal_strategy]).then do |built|
          if built.empty? && @settings[:auto_fallback] &&
             (@settings[:vertical_strategy] != :text ||
              @settings[:horizontal_strategy] != :text)
            # Fallback: l'auto-fallback è LASCO, riprova tutto a :text.
            build_edges(:text, :text)
          else
            built
          end
        end
      end

      def intersections
        @intersections ||= Edges.edges_to_intersections(
          edges,
          x_tolerance: @settings[:intersection_x_tolerance],
          y_tolerance: @settings[:intersection_y_tolerance]
        )
      end

      def cells
        @cells ||= Cells.intersections_to_cells(intersections)
      end

      def tables
        @tables ||= Cells.cells_to_tables(cells).map { |group| Table.new(@page, group) }
      end
      alias find tables

      # Estrai i dati di tutte le tabelle: Array<Array<Array<String>>>.
      def extract(**text_opts)
        merged = {
          x_tolerance: @settings[:text_x_tolerance],
          y_tolerance: @settings[:text_y_tolerance],
          keep_blank_chars: @settings[:text_keep_blank_chars]
        }.merge(text_opts)

        tables.map { |t| t.extract(**merged) }
      end

      private

      def resolve_settings(s)
        # Cascata x/y dai non-suffissi
        s[:snap_x_tolerance] ||= s[:snap_tolerance]
        s[:snap_y_tolerance] ||= s[:snap_tolerance]
        s[:join_x_tolerance] ||= s[:join_tolerance]
        s[:join_y_tolerance] ||= s[:join_tolerance]
        s[:intersection_x_tolerance] ||= s[:intersection_tolerance]
        s[:intersection_y_tolerance] ||= s[:intersection_tolerance]
        s
      end

      def validate_strategies!
        %i[vertical_strategy horizontal_strategy].each do |k|
          unless VALID_STRATEGIES.include?(@settings[k])
            raise ArgumentError, "#{k} must be one of #{VALID_STRATEGIES}"
          end
          if @settings[k] == :explicit
            list = @settings[:"explicit_#{k.to_s.split('_').first}_lines"]
            if list.nil? || list.size < 2
              raise ArgumentError, "Strategy :explicit on #{k} requires " \
                                    "at least 2 explicit_*_lines"
            end
          end
        end
      end

      def build_edges(v_strat, h_strat)
        words = nil
        words = page_words if v_strat == :text || h_strat == :text

        v_base = edges_for_strategy(:v, v_strat, words)
        h_base = edges_for_strategy(:h, h_strat, words)

        v_explicit = explicit_v_edges
        h_explicit = explicit_h_edges

        all = v_base + v_explicit + h_base + h_explicit
        merged = Edges.merge_edges(
          all,
          snap_x_tolerance: @settings[:snap_x_tolerance],
          snap_y_tolerance: @settings[:snap_y_tolerance],
          join_x_tolerance: @settings[:join_x_tolerance],
          join_y_tolerance: @settings[:join_y_tolerance]
        )
        Edges.filter_edges(merged, min_length: @settings[:edge_min_length])
      end

      def page_words
        # Genera words usando il nostro WordExtractor (consistente con
        # quello usato in Table#extract, così i thresholds combaciano).
        # `lean: true`: vedi commento in Table#extract.
        chars = @page.chars(lean: true)
        Util::WordExtractor.new(
          x_tolerance: @settings[:text_x_tolerance],
          y_tolerance: @settings[:text_y_tolerance],
          keep_blank_chars: @settings[:text_keep_blank_chars]
        ).extract_words(chars)
      end

      def edges_for_strategy(axis, strat, words)
        case strat
        when :lines, :lines_strict
          axis == :v ? page_vertical_edges(strict: strat == :lines_strict)
            : page_horizontal_edges(strict: strat == :lines_strict)
        when :text
          axis == :v ? Edges.words_to_edges_v(words || [], word_threshold: @settings[:min_words_vertical])
            : Edges.words_to_edges_h(words || [], word_threshold: @settings[:min_words_horizontal])
        when :explicit then []
        end
      end

      # Converte i `vertical_lines` di Page (formato {x, top, bottom}) al
      # formato pdfplumber-style atteso dalle Edges.
      # Nota: in 0.3.0 NON includiamo i lati di rettangoli quando :strict
      # (ma al momento Page non li espone separatamente, è una semplificazione
      # che documenteremo).
      def page_vertical_edges(strict: false) # rubocop:disable Lint/UnusedMethodArgument
        prefilter = @settings[:edge_min_length_prefilter]
        @page.vertical_lines.filter_map do |s|
          length = s[:bottom] - s[:top]
          next if length < prefilter

          { x0: s[:x], x1: s[:x], top: s[:top], bottom: s[:bottom],
            orientation: "v" }
        end
      end

      def page_horizontal_edges(strict: false) # rubocop:disable Lint/UnusedMethodArgument
        prefilter = @settings[:edge_min_length_prefilter]
        @page.horizontal_lines.filter_map do |s|
          length = s[:x1] - s[:x0]
          next if length < prefilter

          { x0: s[:x0], x1: s[:x1], top: s[:y], bottom: s[:y],
            orientation: "h" }
        end
      end

      def explicit_v_edges
        page_h = @page.height
        @settings[:explicit_vertical_lines].map do |item|
          x, top, bottom = case item
                           when Numeric then [item.to_f, 0.0, page_h]
                           when Hash
                             [item[:x] || item.fetch("x"),
                              item[:top]    || item["top"]    || 0.0,
                              item[:bottom] || item["bottom"] || page_h]
                           end
          { x0: x, x1: x, top: top, bottom: bottom, orientation: "v" }
        end
      end

      def explicit_h_edges
        page_w = @page.width
        @settings[:explicit_horizontal_lines].map do |item|
          y, x0, x1 = case item
                      when Numeric then [item.to_f, 0.0, page_w]
                      when Hash
                        [item[:y]  || item.fetch("y"),
                         item[:x0] || item["x0"] || 0.0,
                         item[:x1] || item["x1"] || page_w]
                      end
          { x0: x0, x1: x1, top: y, bottom: y, orientation: "h" }
        end
      end
    end
  end
end
