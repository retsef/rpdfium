# frozen_string_literal: true

module Rpdfium
  module Util
    # Primitive di clustering 1D usate da tutto il pipeline tabellare.
    # Mappa diretta su `pdfplumber.utils.clustering` (cluster_list,
    # cluster_objects, make_cluster_dict).
    #
    # PROPRIETÀ CHIAVE: questi cluster sono "1D agglomerative single-linkage":
    # due valori finiscono nello stesso cluster se sono entro `tolerance` da
    # un valore qualsiasi del cluster. NON solo dal centro/media. Ne consegue
    # che catene di valori ravvicinati possono estendere il cluster ben oltre
    # `tolerance` (questo è esattamente il comportamento di pdfplumber, e su
    # cui si appoggiano le sue euristiche edge/intersection).
    module Cluster
      module_function

      # Raggruppa valori scalari in cluster. I valori dentro lo stesso cluster
      # sono entro `tolerance` da almeno un altro valore del cluster.
      #
      # Esempio:
      #   cluster_list([1.0, 1.5, 2.0, 5.0], tolerance: 1.0)
      #   #=> [[1.0, 1.5, 2.0], [5.0]]
      #
      # NOTA: Catene "stepping stone": [1, 2, 3, 4] con tol=1 fanno UN cluster
      # solo, anche se 1 e 4 distano 3. Questo è il comportamento di
      # pdfplumber, è documentato nei suoi issue come potenzialmente
      # sorprendente ma intenzionale. Lo manteniamo identico.
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

      # Raggruppa oggetti (Hash) in cluster basandosi su una funzione di
      # estrazione `key_fn` (oppure simbolo Hash key) e tolleranza.
      #
      # Esempio:
      #   cluster_objects(words, ->(w) { w[:top] }, tolerance: 1)
      #   cluster_objects(words, :top, tolerance: 1)   # syntactic sugar
      def cluster_objects(objects, key_fn, tolerance: 0)
        return [] if objects.empty?

        accessor = key_fn.is_a?(Symbol) ? ->(o) { o[key_fn] } : key_fn

        # Raccolgo (valore, oggetto), ordino per valore, raggruppo come in cluster_list
        pairs = objects.map { |o| [accessor.call(o), o] }
        sorted = pairs.sort_by(&:first)

        clusters = [[sorted.first]]
        sorted[1..].each do |pair|
          if (pair.first - clusters.last.last.first).abs <= tolerance
            clusters.last << pair
          else
            clusters << [pair]
          end
        end
        clusters.map { |group| group.map(&:last) }
      end

      # bbox = [x0, top, x1, bottom] (top-down). Ritorna la bbox che racchiude
      # tutti gli oggetti passati. Usa min/max di x0/top/x1/bottom.
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

      # Variante che ritorna un Hash invece di tuple — comoda nel contesto
      # edge dove ci serve mescolare bbox+orientation.
      def objects_to_rect(objects)
        x0, top, x1, bottom = objects_to_bbox(objects)
        { x0: x0, top: top, x1: x1, bottom: bottom,
          width: x1 - x0, height: bottom - top }
      end

      # bbox sovrapposti. None overlap => nil. Match pdfplumber's
      # get_bbox_overlap: ritorna la bbox di intersezione, oppure nil.
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

      # True se due bbox si sovrappongono (anche solo a un punto è no, deve
      # esserci area positiva).
      def bbox_overlaps?(a, b)
        !bbox_overlap(a, b).nil?
      end
    end
  end
end
