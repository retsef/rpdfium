# frozen_string_literal: true

module Rpdfium
  module Table
    # Operations on edges (horizontal/vertical segments) used by the
    # TableFinder. A direct mapping onto `pdfplumber/table.py`.
    #
    # Internal conventions (aligned with pdfplumber):
    #   - Each edge is a Hash with :orientation ("v" | "h"),
    #     :x0, :x1, :top, :bottom (in top-down coordinates).
    #   - Horizontal edge: top == bottom, x0 < x1.
    #   - Vertical edge:    x0 == x1, top < bottom.
    #
    # The edges can come from:
    #   - vector lines of the PDF (path segments)
    #   - rectangles (decomposed into 4 sides)
    #   - "implicit" lines inferred from word alignment (:text strategy)
    #   - lines specified by the user (:explicit strategy)
    module Edges
      module_function

      # Snap: cluster of near-collinear edges → common average coordinate.
      # For horizontals it snaps the `top` (== `bottom`); for verticals the
      # `x0`.
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

      # Join: given a group of edges on the same infinite line (same top
      # for horizontals, same x0 for verticals), merges those whose
      # endpoints are within `tolerance`.
      #
      # Exact match of pdfplumber.join_edge_group behavior: iterates sorted
      # by minprop, extends the "current" if overlap/contiguity is within
      # tolerance, otherwise opens a new current.
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

      # Complete pipeline: snap + join. Faithful to pdfplumber.merge_edges.
      def merge_edges(edges,
                      snap_x_tolerance: 3.0, snap_y_tolerance: 3.0,
                      join_x_tolerance: 3.0, join_y_tolerance: 3.0)
        if snap_x_tolerance.positive? || snap_y_tolerance.positive?
          edges = snap_edges(edges,
                              x_tolerance: snap_x_tolerance,
                              y_tolerance: snap_y_tolerance)
        end

        # Group by (orientation, "line value")
        # h → top, v → x0
        groups = edges.group_by do |e|
          e[:orientation] == "h" ? ["h", e[:top]] : ["v", e[:x0]]
        end
        groups.flat_map do |(orient, _key), group|
          tol = orient == "h" ? join_x_tolerance : join_y_tolerance
          join_edge_group(group, orient, tolerance: tol)
        end
      end

      # Filters out edges that are too short.
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

      # For each cluster of words aligned "at the top" (same top, within
      # tol=1) with at least `word_threshold` members, it emits TWO
      # horizontal edges (top and bottom of that cluster's bbox). Having
      # the bottom in addition to the top is critical: it guarantees that
      # the last row of each table has a closing horizontal edge.
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

      # Three clusters of words by x: x0, x1, centerpoint. Clusters with at
      # least `word_threshold` members are column candidates. The bboxes of
      # each cluster are "condensed": if a bbox overlaps another already
      # selected (more populated) one, it is discarded.
      #
      # For each condensed bbox I emit a vertical edge at its x0 (left of
      # the column). In addition, I emit a final "right" edge at the max x1
      # of all the bboxes: it visually closes the table on the right.
      def words_to_edges_v(words, word_threshold: DEFAULT_MIN_WORDS_VERTICAL)
        by_x0 = Util::Cluster.cluster_objects(words, :x0, tolerance: 1.0)
        by_x1 = Util::Cluster.cluster_objects(words, :x1, tolerance: 1.0)
        center_fn = ->(w) { (w[:x0] + w[:x1]) / 2.0 }
        by_center = Util::Cluster.cluster_objects(words, center_fn, tolerance: 1.0)

        clusters = by_x0 + by_x1 + by_center
        # More populated first
        sorted = clusters.sort_by { |c| -c.size }
        large = sorted.select { |c| c.size >= word_threshold }
        bboxes = large.map { |c| Util::Cluster.objects_to_bbox(c) }

        condensed_bboxes = bboxes.each_with_object([]) do |b, acc|
          acc << b unless acc.any? { |c| Util::Cluster.bbox_overlaps?(b, c) }
        end
        return [] if condensed_bboxes.empty?

        # Sort left-to-right to emit edges in geometric order.
        condensed_rects = condensed_bboxes.map do |b|
          { x0: b[0], top: b[1], x1: b[2], bottom: b[3] }
        end.sort_by { |r| r[:x0] }

        max_x1, min_top, max_bottom = condensed_rects.each_with_object(
          [-Float::INFINITY, Float::INFINITY, -Float::INFINITY]
        ) do |r, acc|
          acc[0] = r[:x1]     if r[:x1]     > acc[0]
          acc[1] = r[:top]    if r[:top]    < acc[1]
          acc[2] = r[:bottom] if r[:bottom] > acc[2]
        end

        # "left" edge of each column + a final "right" edge.
        left_edges = condensed_rects.map do |r|
          { x0: r[:x0], x1: r[:x0], top: min_top, bottom: max_bottom, orientation: "v" }
        end
        right_edge = { x0: max_x1, x1: max_x1, top: min_top, bottom: max_bottom, orientation: "v" }
        left_edges + [right_edge]
      end

      # ------------------------------------------------------------------
      # edge intersections
      # ------------------------------------------------------------------

      # For each (h, v) pair that intersects within tolerance, it records
      # an intersection `(v.x0, h.top)` with pointers to the source edges.
      # The value in `intersections[(x, y)] = { v: [...], h: [...] }` then
      # allows the cell-builder to verify "edge connect".
      #
      # Optimization over the naïve O(|v|×|h|) loop: sorted_h is ordered by
      # top; for each vertical edge a bsearch is used to find the first
      # candidate h and the loop exits as soon as h[:top] exceeds
      # v[:bottom] + y_tolerance, reducing the iterations to only the
      # vertically relevant subset.
      def edges_to_intersections(edges, x_tolerance: 1.0, y_tolerance: 1.0)
        v_edges, h_edges = edges.partition { |e| e[:orientation] == "v" }
        intersections = {}
        sorted_v = v_edges.sort_by { |v| [v[:x0], v[:top]] }
        sorted_h = h_edges.sort_by { |h| [h[:top], h[:x0]] }
        h_tops = sorted_h.map { |h| h[:top] }

        sorted_v.each do |v|
          v_top_min = v[:top]    - y_tolerance
          v_top_max = v[:bottom] + y_tolerance

          # Skip all the h whose top is still below the vertical window.
          start_idx = h_tops.bsearch_index { |t| t >= v_top_min } || sorted_h.size

          sorted_h[start_idx..].each do |h|
            # The remaining h are beyond the window: exit immediately.
            break if h[:top] > v_top_max

            next unless v[:x0] >= h[:x0] - x_tolerance
            next unless v[:x0] <= h[:x1] + x_tolerance

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
