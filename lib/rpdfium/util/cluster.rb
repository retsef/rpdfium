# frozen_string_literal: true

module Rpdfium
  module Util
    # 1D clustering primitives used throughout the table pipeline.
    # Direct mapping onto `pdfplumber.utils.clustering` (cluster_list,
    # cluster_objects, make_cluster_dict).
    #
    # KEY PROPERTY: these clusters are "1D agglomerative single-linkage":
    # two values end up in the same cluster if they are within
    # `tolerance` of any value in the cluster. NOT only of the
    # center/mean. As a result, chains of close values can extend the
    # cluster well beyond `tolerance` (this is exactly pdfplumber's
    # behavior, on which its edge/intersection heuristics rely).
    module Cluster
      module_function

      # Groups scalar values into clusters. The values within the same
      # cluster are within `tolerance` of at least one other value of
      # the cluster.
      #
      # Example:
      #   cluster_list([1.0, 1.5, 2.0, 5.0], tolerance: 1.0)
      #   #=> [[1.0, 1.5, 2.0], [5.0]]
      #
      # NOTE: "Stepping stone" chains: [1, 2, 3, 4] with tol=1 form a
      # SINGLE cluster, even though 1 and 4 are 3 apart. This is
      # pdfplumber's behavior, documented in its issues as potentially
      # surprising but intentional. We keep it identical.
      def cluster_list(values, tolerance: 0)
        return [] if values.empty?

        sorted = values.sort
        clusters = [[sorted.first]]
        sorted[1..].each do |v|
          if (v - clusters.last.last).abs <= tolerance
            clusters.last << v
          else
            clusters << [v]
          end
        end
        clusters
      end

      # Groups objects (Hash) into clusters based on an extraction
      # function `key_fn` (or a Hash key symbol) and a tolerance.
      #
      # Example:
      #   cluster_objects(words, ->(w) { w[:top] }, tolerance: 1)
      #   cluster_objects(words, :top, tolerance: 1)   # syntactic sugar
      def cluster_objects(objects, key_fn, tolerance: 0, presorted: false)
        return [] if objects.empty?

        # Fast path for the most common Symbol case (:top, :x0, :bottom):
        # direct Hash[symbol] access is ~2x faster than the lambda call.
        if key_fn.is_a?(Symbol)
          # If the caller guarantees that the input is already sorted by
          # key_fn (e.g. because it comes from a lexicographic sort
          # [key_fn, ...]) the internal sort can be skipped. A significant
          # saving when cluster_objects is called in a loop over many
          # small rows.
          sorted = presorted ? objects : objects.sort_by { |o| o[key_fn] }
          first = sorted.first
          last_key = first[key_fn]
          clusters = [[first]]
          tol = tolerance.to_f
          i = 1
          n = sorted.size
          while i < n
            obj = sorted[i]
            curr_key = obj[key_fn]
            if (curr_key - last_key).abs <= tol
              clusters.last << obj
            else
              clusters << [obj]
            end
            last_key = curr_key
            i += 1
          end
          return clusters
        end

        # Generic path with a callable accessor
        accessor = key_fn
        sorted = presorted ? objects : objects.sort_by { |o| accessor.call(o) }
        last_key = accessor.call(sorted.first)
        clusters = [[sorted.first]]

        sorted[1..].each do |obj|
          curr_key = accessor.call(obj)
          if (curr_key - last_key).abs <= tolerance
            clusters.last << obj
          else
            clusters << [obj]
          end
          last_key = curr_key
        end
        clusters
      end

      # bbox = [x0, top, x1, bottom] (top-down). Returns the bbox that
      # encloses all the passed objects. Uses min/max of x0/top/x1/bottom.
      def objects_to_bbox(objects)
        objects.each_with_object(
          [Float::INFINITY, Float::INFINITY, -Float::INFINITY, -Float::INFINITY]
        ) do |o, acc|
          acc[0] = o[:x0]     if o[:x0]     < acc[0]
          acc[1] = o[:top]    if o[:top]    < acc[1]
          acc[2] = o[:x1]     if o[:x1]     > acc[2]
          acc[3] = o[:bottom] if o[:bottom] > acc[3]
        end
      end

      # Variant that returns a Hash instead of a tuple — handy in the
      # edge context where we need to mix bbox+orientation.
      def objects_to_rect(objects)
        x0, top, x1, bottom = objects_to_bbox(objects)
        { x0: x0, top: top, x1: x1, bottom: bottom,
          width: x1 - x0, height: bottom - top }
      end

      # Overlapping bbox. No overlap => nil. Matches pdfplumber's
      # get_bbox_overlap: returns the intersection bbox, or nil.
      def bbox_overlap(a, b)
        ax0, atop, ax1, abot = a
        bx0, btop, bx1, bbot = b
        x0 = [ax0, bx0].max
        x1 = [ax1, bx1].min
        return nil if x0 >= x1

        top = [atop, btop].max
        bot = [abot, bbot].min
        return nil if top >= bot

        [x0, top, x1, bot]
      end

      # True if two bbox overlap (even just at a point is no; there must
      # be positive area).
      def bbox_overlaps?(a, b)
        !bbox_overlap(a, b).nil?
      end
    end
  end
end
