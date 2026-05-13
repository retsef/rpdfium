# frozen_string_literal: true

module Rpdfium
  module Table
    # Costruisce celle da intersezioni e tabelle da celle.
    # Algoritmi 1:1 con pdfplumber.intersections_to_cells e
    # pdfplumber.cells_to_tables.
    module Cells
      module_function

      # Ricerca della "smallest cell" per ogni intersezione: dato un punto
      # `pt = (x, y)`, cerca il rettangolo minimo i cui 4 corner sono
      # intersezioni e i cui 4 lati hanno edge che le connettono.
      #
      # Il vincolo "edge connect" è cruciale: due intersezioni con stessa
      # x non bastano — devono CONDIVIDERE almeno un edge verticale (cioè
      # appartenere a uno stesso segmento continuo). Idem orizzontale.
      # Questo evita falsi positivi tipo "due colonne lontane allineate
      # accidentalmente".
      #
      # `intersections` è il Hash prodotto da Edges.edges_to_intersections,
      # con chiavi `[x, y]` e valori `{ v: [edges...], h: [edges...] }`.
      def intersections_to_cells(intersections)
        return [] if intersections.empty?

        # Indici di adiacenza: per ogni edge (oggetto Hash, identità di
        # ruby), quali intersection points contiene? Pdfplumber lo fa
        # confrontando bbox degli edge — noi abbiamo accesso diretto agli
        # oggetti edge dentro `intersections[pt]`, basta usare l'identity.
        # Per "stesso edge" usiamo `equal?` (identità d'oggetto).
        edge_ids = intersections.transform_values do |val|
          { v: val[:v].map(&:object_id).to_set,
            h: val[:h].map(&:object_id).to_set }
        end

        edge_connects = lambda do |p1, p2|
          if p1[0] == p2[0]
            return !(edge_ids[p1][:v] & edge_ids[p2][:v]).empty?
          end
          if p1[1] == p2[1]
            return !(edge_ids[p1][:h] & edge_ids[p2][:h]).empty?
          end
          false
        end

        points = intersections.keys.sort
        npoints = points.size

        # Indici spaziali: precomputa punti per colonna (stessa x) e per riga
        # (stessa y), già ordinati perché `points` è sorted.
        # Permette lookup O(log n) via bsearch invece di O(n) via select.
        by_x = Hash.new { |h, k| h[k] = [] }
        by_y = Hash.new { |h, k| h[k] = [] }
        points.each { |p| by_x[p[0]] << p; by_y[p[1]] << p }

        cells = []
        points.each_with_index do |pt, i|
          next if i == npoints - 1

          # Punti direttamente sotto `pt` (stessa x, y maggiore)
          col = by_x[pt[0]]
          below_start = col.bsearch_index { |q| q[1] > pt[1] } || col.size
          below = col[below_start..]

          # Punti direttamente a destra di `pt` (stessa y, x maggiore)
          row_pts = by_y[pt[1]]
          right_start = row_pts.bsearch_index { |q| q[0] > pt[0] } || row_pts.size
          right = row_pts[right_start..]

          # Cerca il PRIMO (== più piccolo per via dell'ordinamento) bottom-right
          # i cui 4 corner sono presenti e gli edge connettono.
          found = nil
          below.each do |b|
            next unless edge_connects.call(pt, b)

            right.each do |r|
              next unless edge_connects.call(pt, r)

              br = [r[0], b[1]]
              next unless intersections.key?(br)
              next unless edge_connects.call(br, r)
              next unless edge_connects.call(br, b)

              found = [pt[0], pt[1], br[0], br[1]]
              break
            end
            break if found
          end
          cells << found if found
        end
        cells
      end

      # Raggruppa celle in tabelle in base ai corner condivisi.
      #
      # Algoritmo: Union-Find (disjoint set) sui corner — O(n α(n)) invece
      # del greedy fixed-point O(n²) di pdfplumber. Il risultato è identico:
      # due celle finiscono nello stesso gruppo se condividono almeno un corner.
      #
      # Filtro finale: scarta tabelle con UNA SOLA cella (rumore).
      def cells_to_tables(cells)
        return [] if cells.empty?

        n = cells.size
        parent = Array.new(n) { |i| i }

        find = lambda do |i|
          i = parent[i] = parent[parent[i]] while parent[i] != i
          i
        end
        union = ->(a, b) { parent[find.call(a)] = find.call(b) }

        # Per ogni corner, raccoglie gli indici delle celle che lo condividono
        # e le unisce nel medesimo componente.
        corner_to_cells = Hash.new { |h, k| h[k] = [] }
        cells.each_with_index do |cell, idx|
          x0, top, x1, bottom = cell
          [[x0, top], [x0, bottom], [x1, top], [x1, bottom]].each do |corner|
            corner_to_cells[corner] << idx
          end
        end
        corner_to_cells.each_value do |idxs|
          idxs.each_cons(2) { |a, b| union.call(a, b) }
        end

        # Raggruppa per root del Union-Find
        groups = Hash.new { |h, k| h[k] = [] }
        cells.each_with_index { |cell, i| groups[find.call(i)] << cell }

        # Sort top-to-bottom, left-to-right; filtra single-cell.
        groups.values
              .sort_by { |t| t.map { |c| [c[1], c[0]] }.min }
              .reject  { |t| t.size <= 1 }
      end
    end
  end
end
