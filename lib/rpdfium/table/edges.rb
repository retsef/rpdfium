# frozen_string_literal: true

module Rpdfium
  module Table
    # Utility per manipolare collezioni di "edges" (segmenti orizzontali o
    # verticali). Algoritmi mutuati da pdfplumber/table.py.
    #
    # Convenzioni interne:
    # - edge orizzontale: { y:, x0:, x1:, ... } con x0 <= x1
    # - edge verticale:   { x:, top:, bottom:, ... } con top <= bottom
    #
    # `top` < `bottom` perché siamo in coordinate top-down (origine in alto).
    module Edges
      module_function

      # Snap: edges quasi-collineari → stessa coordinata trasversale.
      # Per orizzontali snappa la y, per verticali snappa la x.
      def snap_horizontal(edges, tol)
        snap_by(edges, :y, tol)
      end

      def snap_vertical(edges, tol)
        snap_by(edges, :x, tol)
      end

      def snap_by(edges, key, tol)
        return [] if edges.empty?

        sorted = edges.sort_by { |e| e[key] }
        # Cluster per chiave entro tolleranza
        clusters = [[sorted.first]]
        sorted[1..].each do |e|
          if (e[key] - clusters.last.last[key]).abs <= tol
            clusters.last << e
          else
            clusters << [e]
          end
        end
        clusters.flat_map do |cluster|
          mean = cluster.sum { |e| e[key] } / cluster.size.to_f
          cluster.map { |e| e.merge(key => mean) }
        end
      end

      # Join: edges collineari (stessa y/x) i cui estremi sono entro tolleranza
      # vengono fusi in un edge unico.
      def join_horizontal(edges, tol)
        join_by(edges, :y, :x0, :x1, tol)
      end

      def join_vertical(edges, tol)
        join_by(edges, :x, :top, :bottom, tol)
      end

      def join_by(edges, axis_key, lo_key, hi_key, tol)
        # Raggruppa per axis (assunto già snappato)
        by_axis = edges.group_by { |e| e[axis_key] }
        result = []
        by_axis.each do |_axis, group|
          # Ordina per lo_key e fondi sovrapposti/contigui
          sorted = group.sort_by { |e| e[lo_key] }
          current = sorted.first.dup
          sorted[1..].each do |e|
            if e[lo_key] <= current[hi_key] + tol
              current[hi_key] = [current[hi_key], e[hi_key]].max
            else
              result << current
              current = e.dup
            end
          end
          result << current
        end
        result
      end

      # Filter: rimuovi edges troppo corti (rumore: piccoli underline,
      # punti di tab leader, separatori di paragrafo).
      def filter_short_horizontal(edges, min_length)
        edges.reject { |e| (e[:x1] - e[:x0]) < min_length }
      end

      def filter_short_vertical(edges, min_length)
        edges.reject { |e| (e[:bottom] - e[:top]) < min_length }
      end

      # Pipeline standard: snap → join → filter
      def normalize_horizontal(edges, snap_tol:, join_tol:, min_length:)
        e = snap_horizontal(edges, snap_tol)
        e = join_horizontal(e, join_tol)
        filter_short_horizontal(e, min_length)
      end

      def normalize_vertical(edges, snap_tol:, join_tol:, min_length:)
        e = snap_vertical(edges, snap_tol)
        e = join_vertical(e, join_tol)
        filter_short_vertical(e, min_length)
      end

      # Intersezioni tra edges H e V. Un'intersezione esiste quando:
      #   abs(h.y - in_range(v.top..v.bottom)) <= tol  AND
      #   abs(v.x - in_range(h.x0..h.x1)) <= tol
      # Ritorna: { x:, y:, h: <horizontal_edge>, v: <vertical_edge> }
      def intersections(h_edges, v_edges, x_tol:, y_tol:)
        out = []
        h_edges.each do |h|
          v_edges.each do |v|
            next unless v[:x].between?(h[:x0] - x_tol, h[:x1] + x_tol)
            next unless h[:y].between?(v[:top] - y_tol, v[:bottom] + y_tol)

            out << { x: v[:x], y: h[:y], h: h, v: v }
          end
        end
        out
      end
    end
  end
end
