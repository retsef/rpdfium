# frozen_string_literal: true

module Rpdfium
  module Table
    # Operazioni su edges (segmenti orizzontali/verticali) usate dal
    # TableFinder. Mappa diretta su `pdfplumber/table.py`.
    #
    # Convenzioni interne (allineate a pdfplumber):
    #   - Ogni edge è un Hash con :orientation ("v" | "h"),
    #     :x0, :x1, :top, :bottom (in coordinate top-down).
    #   - Edge orizzontale: top == bottom, x0 < x1.
    #   - Edge verticale:   x0 == x1, top < bottom.
    #
    # Le edges possono provenire da:
    #   - linee vettoriali del PDF (path segments)
    #   - rettangoli (decomposti in 4 lati)
    #   - line "implicite" dedotte dall'allineamento di words (strategia :text)
    #   - line specificate dall'utente (strategia :explicit)
    module Edges
      module_function

      # Snap: cluster di edges quasi-collineari → coordinata media comune.
      # Per orizzontali snappa la `top` (== `bottom`); per verticali la `x0`.
      def snap_edges(edges, x_tolerance: 3.0, y_tolerance: 3.0)
        v_edges, h_edges = edges.partition { |e| e[:orientation] == "v" }

        snapped_v = Util::Cluster.cluster_objects(v_edges, :x0, tolerance: x_tolerance)
                                 .flat_map { |g| move_to_avg(g, "v") }
        snapped_h = Util::Cluster.cluster_objects(h_edges, :top, tolerance: y_tolerance)
                                 .flat_map { |g| move_to_avg(g, "h") }
        snapped_v + snapped_h
      end

      def move_to_avg(cluster, orientation)
        case orientation
        when "h"
          mean = cluster.sum { |e| e[:top] } / cluster.size.to_f
          cluster.map { |e| e.merge(top: mean, bottom: mean) }
        when "v"
          mean = cluster.sum { |e| e[:x0] } / cluster.size.to_f
          cluster.map { |e| e.merge(x0: mean, x1: mean) }
        end
      end

      # Join: dato un gruppo di edges sulla stessa retta infinita (stessa top
      # per orizzontali, stessa x0 per verticali), fonde quelli i cui estremi
      # sono entro `tolerance`.
      #
      # Match esatto del comportamento di pdfplumber.join_edge_group: scorre
      # sorted per minprop, estende il "current" se overlap/contiguità entro
      # tolerance, altrimenti apre nuovo current.
      def join_edge_group(edges, orientation, tolerance: 3.0)
        return [] if edges.empty?

        min_prop, max_prop =
          orientation == "h" ? [:x0, :x1] : [:top, :bottom]

        sorted = edges.sort_by { |e| e[min_prop] }
        joined = [sorted.first.dup]
        sorted[1..].each do |e|
          last = joined.last
          if e[min_prop] <= last[max_prop] + tolerance
            last[max_prop] = e[max_prop] if e[max_prop] > last[max_prop]
          else
            joined << e.dup
          end
        end
        joined
      end

      # Pipeline completa: snap + join. Fedele a pdfplumber.merge_edges.
      def merge_edges(edges,
                      snap_x_tolerance: 3.0, snap_y_tolerance: 3.0,
                      join_x_tolerance: 3.0, join_y_tolerance: 3.0)
        if snap_x_tolerance.positive? || snap_y_tolerance.positive?
          edges = snap_edges(edges,
                              x_tolerance: snap_x_tolerance,
                              y_tolerance: snap_y_tolerance)
        end

        # Raggruppa per (orientation, "valore della retta")
        # h → top, v → x0
        groups = edges.group_by do |e|
          e[:orientation] == "h" ? ["h", e[:top]] : ["v", e[:x0]]
        end
        groups.flat_map do |(orient, _key), group|
          tol = orient == "h" ? join_x_tolerance : join_y_tolerance
          join_edge_group(group, orient, tolerance: tol)
        end
      end

      # Filtra edges troppo corti.
      def filter_edges(edges, orientation: nil, min_length: 1.0)
        edges.reject do |e|
          next true if orientation && e[:orientation] != orientation

          length = if e[:orientation] == "h"
                     e[:x1] - e[:x0]
                   else
                     e[:bottom] - e[:top]
                   end
          length < min_length
        end
      end

      # ------------------------------------------------------------------
      # words → edges (strategia :text)
      # ------------------------------------------------------------------

      DEFAULT_MIN_WORDS_VERTICAL = 3
      DEFAULT_MIN_WORDS_HORIZONTAL = 1

      # Per ogni cluster di word allineate "in alto" (stessa top, entro tol=1)
      # con almeno `word_threshold` membri, emette DUE edges orizzontali (top
      # e bottom della bbox di quel cluster). Avere il bottom oltre al top è
      # critico: garantisce che l'ultima riga di ogni tabella abbia un edge
      # orizzontale di chiusura.
      def words_to_edges_h(words, word_threshold: DEFAULT_MIN_WORDS_HORIZONTAL)
        by_top = Util::Cluster.cluster_objects(words, :top, tolerance: 1.0)
        large = by_top.select { |g| g.size >= word_threshold }
        rects = large.map { |g| Util::Cluster.objects_to_rect(g) }
        return [] if rects.empty?

        min_x0 = rects.map { |r| r[:x0] }.min
        max_x1 = rects.map { |r| r[:x1] }.max

        rects.flat_map do |r|
          [
            { x0: min_x0, x1: max_x1, top: r[:top],    bottom: r[:top],    orientation: "h" },
            { x0: min_x0, x1: max_x1, top: r[:bottom], bottom: r[:bottom], orientation: "h" }
          ]
        end
      end

      # Tre cluster di word per x: x0, x1, centerpoint. Cluster con almeno
      # `word_threshold` membri sono candidati colonna. Le bbox di ciascun
      # cluster vengono "condensate": se una bbox si sovrappone a un'altra
      # già selezionata (più popolata), viene scartata.
      #
      # Per ogni bbox condensata emetto un edge verticale al suo x0 (left
      # della colonna). In aggiunta, emetto un edge "right" finale al max
      # x1 di tutte le bbox: chiude visivamente la tabella sulla destra.
      def words_to_edges_v(words, word_threshold: DEFAULT_MIN_WORDS_VERTICAL)
        by_x0 = Util::Cluster.cluster_objects(words, :x0, tolerance: 1.0)
        by_x1 = Util::Cluster.cluster_objects(words, :x1, tolerance: 1.0)
        center_fn = ->(w) { (w[:x0] + w[:x1]) / 2.0 }
        by_center = Util::Cluster.cluster_objects(words, center_fn, tolerance: 1.0)

        clusters = by_x0 + by_x1 + by_center
        # Più popolati prima
        sorted = clusters.sort_by { |c| -c.size }
        large = sorted.select { |c| c.size >= word_threshold }
        bboxes = large.map { |c| Util::Cluster.objects_to_bbox(c) }

        condensed_bboxes = []
        bboxes.each do |b|
          overlap = condensed_bboxes.any? { |c| Util::Cluster.bbox_overlaps?(b, c) }
          condensed_bboxes << b unless overlap
        end
        return [] if condensed_bboxes.empty?

        # Sort left-to-right per emettere edges in ordine geometrico.
        condensed_rects = condensed_bboxes.map do |b|
          { x0: b[0], top: b[1], x1: b[2], bottom: b[3] }
        end.sort_by { |r| r[:x0] }

        max_x1 = condensed_rects.map { |r| r[:x1] }.max
        min_top = condensed_rects.map { |r| r[:top] }.min
        max_bottom = condensed_rects.map { |r| r[:bottom] }.max

        # Edge "left" di ogni colonna + un edge finale "right".
        left_edges = condensed_rects.map do |r|
          { x0: r[:x0], x1: r[:x0], top: min_top, bottom: max_bottom, orientation: "v" }
        end
        right_edge = { x0: max_x1, x1: max_x1, top: min_top, bottom: max_bottom, orientation: "v" }
        left_edges + [right_edge]
      end

      # ------------------------------------------------------------------
      # intersezioni edges
      # ------------------------------------------------------------------

      # Per ogni coppia (h, v) che si interseca entro tolerance, registra
      # un'intersezione `(v.x0, h.top)` con i puntatori agli edge sorgenti.
      # Il valore in `intersections[(x, y)] = { v: [...], h: [...] }` permette
      # poi al cell-builder di verificare "edge connect".
      def edges_to_intersections(edges, x_tolerance: 1.0, y_tolerance: 1.0)
        v_edges, h_edges = edges.partition { |e| e[:orientation] == "v" }
        intersections = {}

        v_edges.sort_by { |v| [v[:x0], v[:top]] }.each do |v|
          h_edges.sort_by { |h| [h[:top], h[:x0]] }.each do |h|
            next unless v[:top]    <= h[:top] + y_tolerance
            next unless v[:bottom] >= h[:top] - y_tolerance
            next unless v[:x0]     >= h[:x0]  - x_tolerance
            next unless v[:x0]     <= h[:x1]  + x_tolerance

            key = [v[:x0], h[:top]]
            entry = intersections[key] ||= { v: [], h: [] }
            entry[:v] << v
            entry[:h] << h
          end
        end
        intersections
      end
    end
  end
end
