# frozen_string_literal: true

module Rpdfium
  module Table
    # Costruisce celle e tabelle dalle intersezioni di edges.
    # Algoritmo:
    #   1. Indicizza intersezioni in una griglia (x_set, y_set sorted).
    #   2. Per ogni coppia (xi, xi+1) × (yj, yj+1) controlla se TUTTI E 4
    #      gli angoli hanno un'intersezione → cella valida.
    #   3. Aggrega celle adiacenti (condividono un edge) in tabelle.
    module Cells
      module_function

      def from_intersections(intersections)
        return [] if intersections.empty?

        # Set ordinati delle x e y di intersezione
        xs = intersections.map { |i| i[:x] }.uniq.sort
        ys = intersections.map { |i| i[:y] }.uniq.sort

        # Lookup veloce
        present = intersections.each_with_object({}) do |i, h|
          h[[i[:x], i[:y]]] = true
        end

        cells = []
        xs.each_cons(2) do |x_left, x_right|
          ys.each_cons(2) do |y_top, y_bot|
            # Tutti e 4 gli angoli devono esistere
            corners = [
              [x_left, y_top], [x_right, y_top],
              [x_left, y_bot], [x_right, y_bot]
            ]
            next unless corners.all? { |k| present[k] }

            cells << {
              x0: x_left, x1: x_right,
              top: y_top,  bottom: y_bot
            }
          end
        end
        cells
      end

      # Aggrega celle in tabelle. Due celle sono "adiacenti" se condividono
      # uno spigolo. Usa union-find per raggruppare i componenti connessi.
      def group_into_tables(cells)
        return [] if cells.empty?

        parent = (0...cells.size).to_a
        find = lambda do |i|
          i = parent[i] while parent[i] != i
          i
        end
        union = lambda do |a, b|
          ra = find.call(a); rb = find.call(b)
          parent[ra] = rb if ra != rb
        end

        cells.each_with_index do |c1, i|
          cells.each_with_index do |c2, j|
            next if i >= j
            union.call(i, j) if adjacent?(c1, c2)
          end
        end

        groups = Hash.new { |h, k| h[k] = [] }
        cells.each_with_index { |c, i| groups[find.call(i)] << c }

        groups.values.map { |g| build_table(g) }
              .reject { |t| t[:rows] < 2 || t[:cols] < 2 }
      end

      EPS = 0.5

      def adjacent?(a, b)
        # Condividono lato verticale (a a destra di b o viceversa, y overlapping)
        share_v = (close?(a[:x0], b[:x1]) || close?(a[:x1], b[:x0])) &&
                  ranges_overlap(a[:top], a[:bottom], b[:top], b[:bottom])
        # Condividono lato orizzontale
        share_h = (close?(a[:top], b[:bottom]) || close?(a[:bottom], b[:top])) &&
                  ranges_overlap(a[:x0], a[:x1], b[:x0], b[:x1])
        share_v || share_h
      end

      def close?(a, b); (a - b).abs < EPS; end

      def ranges_overlap(a0, a1, b0, b1)
        a0 < b1 - EPS && b0 < a1 - EPS
      end

      # Da gruppo di celle → tabella strutturata (righe × colonne).
      def build_table(cells)
        xs = cells.flat_map { |c| [c[:x0], c[:x1]] }.uniq.sort
        ys = cells.flat_map { |c| [c[:top], c[:bottom]] }.uniq.sort
        n_cols = xs.size - 1
        n_rows = ys.size - 1

        # Mappa indice cella in (row, col)
        grid = Array.new(n_rows) { Array.new(n_cols) }
        cells.each do |c|
          row = ys.index(c[:top])
          col = xs.index(c[:x0])
          # In tabelle "ben formate", larghezza in colonne e altezza in righe
          col_span = xs.index(c[:x1]) - col
          row_span = ys.index(c[:bottom]) - row
          row_span.times do |dr|
            col_span.times do |dc|
              grid[row + dr][col + dc] = c
            end
          end
        end

        {
          rows: n_rows, cols: n_cols,
          x_edges: xs, y_edges: ys,
          grid: grid,
          bbox: { x0: xs.first, x1: xs.last,
                  top: ys.first, bottom: ys.last }
        }
      end
    end
  end
end
