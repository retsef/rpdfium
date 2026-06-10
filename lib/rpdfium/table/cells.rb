# frozen_string_literal: true

module Rpdfium
  module Table
    # Builds cells from intersections and tables from cells.
    # Algorithms 1:1 with pdfplumber.intersections_to_cells and
    # pdfplumber.cells_to_tables.
    module Cells
      module_function

      # "Smallest cell" search for each intersection: given a point
      # `pt = (x, y)`, find the minimal rectangle whose 4 corners are
      # intersections and whose 4 sides have edges connecting them.
      #
      # The "edge connect" constraint is crucial: two intersections with
      # the same x are not enough — they must SHARE at least one vertical
      # edge (i.e. belong to the same continuous segment). Likewise
      # horizontally. This avoids false positives such as "two distant
      # columns accidentally aligned".
      #
      # `intersections` is the Hash produced by
      # Edges.edges_to_intersections, with keys `[x, y]` and values
      # `{ v: [edges...], h: [edges...] }`.
      def intersections_to_cells(intersections)
        return [] if intersections.empty?

        # Adjacency indices: for each edge (a Hash object, ruby
        # identity), which intersection points does it contain?
        # Pdfplumber does this by comparing the bbox of the edges — we
        # have direct access to the edge objects inside
        # `intersections[pt]`, so it suffices to use identity. For "same
        # edge" we use `equal?` (object identity).
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

        # Spatial indices: precompute points by column (same x) and by
        # row (same y), already ordered because `points` is sorted.
        # Allows O(log n) lookup via bsearch instead of O(n) via select.
        by_x = Hash.new { |h, k| h[k] = [] }
        by_y = Hash.new { |h, k| h[k] = [] }
        points.each { |p| by_x[p[0]] << p; by_y[p[1]] << p }

        cells = []
        points.each_with_index do |pt, i|
          next if i == npoints - 1

          # Points directly below `pt` (same x, greater y)
          col = by_x[pt[0]]
          below_start = col.bsearch_index { |q| q[1] > pt[1] } || col.size
          below = col[below_start..]

          # Points directly to the right of `pt` (same y, greater x)
          row_pts = by_y[pt[1]]
          right_start = row_pts.bsearch_index { |q| q[0] > pt[0] } || row_pts.size
          right = row_pts[right_start..]

          # Find the FIRST (== smallest, due to ordering) bottom-right
          # whose 4 corners are present and whose edges connect.
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

      # Groups cells into tables based on shared corners.
      #
      # Algorithm: Union-Find (disjoint set) on the corners — O(n α(n))
      # instead of pdfplumber's greedy fixed-point O(n²). The result is
      # identical: two cells end up in the same group if they share at
      # least one corner.
      #
      # Final filter: discard tables with a SINGLE cell (noise).
      def cells_to_tables(cells)
        return [] if cells.empty?

        n = cells.size
        parent = Array.new(n) { |i| i }

        find = lambda do |i|
          i = parent[i] = parent[parent[i]] while parent[i] != i
          i
        end
        union = ->(a, b) { parent[find.call(a)] = find.call(b) }

        # For each corner, collect the indices of the cells that share it
        # and union them into the same component.
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

        # Group by the Union-Find root
        groups = Hash.new { |h, k| h[k] = [] }
        cells.each_with_index { |cell, i| groups[find.call(i)] << cell }

        # Sort top-to-bottom, left-to-right; filter out single-cell.
        groups.values
              .sort_by { |t| t.map { |c| [c[1], c[0]] }.min }
              .reject  { |t| t.size <= 1 }
      end
    end
  end
end
