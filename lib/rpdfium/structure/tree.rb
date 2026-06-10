# frozen_string_literal: true

module Rpdfium
  module Structure
    # StructTree of a tagged PDF page.
    #
    # For tagged PDFs (PDF/UA, accessibility-friendly exports from
    # Word/LibreOffice/InDesign), it exposes the logical structure of the
    # document: Document → P, H1, Table, TR, TH, TD, Figure, etc.
    #
    # For NON-tagged PDFs, `Page#struct_tree` returns nil. For "tagged but
    # empty" PDFs (e.g. CR Banca d'Italia, StructTreeRoot present but with
    # placeholder elements without type/MCID), `Tree#empty?` returns true.
    #
    # Lifecycle: the Tree holds a PDFium handle that is "owning" — calling
    # `FPDF_StructTree_Close` deallocates it. PDFium automatically
    # deallocates the struct tree when the document is closed, so in
    # practice:
    #
    #   - if you never close the tree explicitly, PDFium frees it with
    #     `FPDF_CloseDocument` (zero persistent leak, but the tree stays
    #     in memory until the doc is closed — it may be ~MB)
    #   - for deterministic control (release immediately), use the block:
    #
    #       page.struct_tree do |tree|
    #         tree.walk { |el| ... }
    #       end
    #     on exit from the block the tree is closed, even on exception.
    #
    # As a design choice we do NOT use `ObjectSpace.define_finalizer`: if
    # the GC were to call `FPDF_StructTree_Close` after the document had
    # already been closed, this would cause a use-after-free → segfault.
    # Closing via Document is always safe; closing via Tree.close (explicit
    # or through a block) requires the document to still be alive.
    class Tree
      attr_reader :handle, :page

      # Returns nil if the page is not tagged. Otherwise a Tree.
      def self.for_page(page)
        h = Raw.FPDF_StructTree_GetForPage(page.handle)
        return nil if h.null?

        new(page, h)
      end

      def initialize(page, handle)
        @page = page
        @handle = handle
        @closed = false
        @mcid_text_cache = nil

        # NOTE: no finalizer. FPDF_StructTree_Close is "owning": it calls
        # ~CPDF_StructTree() which frees the object. If the PDF document
        # is closed before the tree, the GC finalizer would call Close on
        # already-freed memory → segfault. Safe lifetime:
        #   - explicit close via `tree.close` or via the block
        #     `page.struct_tree { |tree| ... }`
        #   - if nobody closes it explicitly, PDFium frees the tree
        #     together with the document at `FPDF_CloseDocument` (no
        #     persistent leak, only memory held until the doc is closed)
      end

      def closed?
        @closed
      end

      # Explicit close (idempotent). After close, do not call methods on
      # this Tree nor on the Elements it generated.
      def close
        return if @closed

        Raw.FPDF_StructTree_Close(@handle)
        @closed = true
        @mcid_text_cache = nil
      end

      # Number of root elements (direct children of the StructTreeRoot for
      # this page). Typically 1 (`<Document>`), but it can be arbitrarily
      # high on odd PDFs (e.g. cu.pdf: 717 placeholders).
      def root_count
        n = Raw.FPDF_StructTree_CountChildren(@handle)
        [n, 0].max
      end

      # Root elements (direct children of the StructTreeRoot). Typically 1
      # (`<Document>`).
      def roots
        (0...root_count).filter_map do |i|
          h = Raw.FPDF_StructTree_GetChildAtIndex(@handle, i)
          h.null? ? nil : Element.new(self, h)
        end
      end

      # True if the tree is structurally empty (no element with a readable
      # type among the roots). A common case for "fake-tagged" PDFs such as
      # CR Banca d'Italia: the StructTreeRoot exists but the elements are
      # empty placeholders.
      def empty?
        return true if root_count.zero?

        roots.none? { |r| r.type || r.children.any? }
      end

      # Depth-first walk of ALL the elements of the tree. Equivalent to
      # `roots.flat_map(&:walk)`. Without a block it returns an Enumerator.
      def walk(&block)
        return enum_for(:walk) unless block

        roots.each { |r| r.walk(&block) }
      end

      # Finds all the elements of the specified type (e.g. "Table", "P",
      # "Figure"). Case-sensitive comparison (PDF types are "Table",
      # "P", "H1", etc.).
      def find_all(type:)
        walk.select { |el| el.type == type }
      end

      # Returns all the elements of type "Table". Convenient for semantic
      # table extraction.
      def tables
        find_all(type: "Table")
      end

      # Page objects grouped by Marked Content ID, to allow Element#text
      # to resolve the text of its MCIDs. The map is built only once per
      # Tree and cached.
      #
      # Public but intended for internal use; not part of the stable API.
      def mcid_text_map
        @mcid_text_cache ||= build_mcid_text_map
      end

      def to_s
        "#<Rpdfium::Structure::Tree roots=#{root_count}#{empty? ? ' empty' : ''}>"
      end
      alias inspect to_s

      private

      # Iterates all the page objects (incl. Form XObject) and groups their
      # text by MCID. The probe-then-fetch pattern on FPDFTextObj_GetText
      # is well-established (see Page#read_text_obj_text_fast).
      def build_mcid_text_map
        map = Hash.new { |h, k| h[k] = +"" }
        tp = @page.text_page
        page_handle = @page.handle
        buf = FFI::MemoryPointer.new(:uint8, 1024)

        walk_objects = lambda do |handle, is_form|
          n = is_form ? Raw.FPDFFormObj_CountObjects(handle) : Raw.FPDFPage_CountObjects(handle)
          n.times do |i|
            obj = is_form ? Raw.FPDFFormObj_GetObject(handle, i) : Raw.FPDFPage_GetObject(handle, i)
            next if obj.null?

            obj_type = Raw.FPDFPageObj_GetType(obj)
            if obj_type == Raw::PAGEOBJ_TEXT
              mcid = Raw.FPDFPageObj_GetMarkedContentID(obj)
              if mcid >= 0
                text = read_text_obj_text(obj, tp, buf)
                map[mcid] << text if text
              end
            elsif obj_type == Raw::PAGEOBJ_FORM
              walk_objects.call(obj, true)
            end
          end
        end

        walk_objects.call(page_handle, false)
        map
      end

      def read_text_obj_text(obj, tp, buf)
        # Probe with a 1024-byte buffer (sufficient for 99% of marked
        # content runs, which are typically single words or short phrases).
        needed = Raw.FPDFTextObj_GetText(obj, tp.handle, buf, 1024)
        return nil if needed < 2

        if needed > 1024
          big = FFI::MemoryPointer.new(:uint8, needed)
          needed = Raw.FPDFTextObj_GetText(obj, tp.handle, big, needed)
          return nil if needed < 2

          payload = needed - 2
          return nil if payload <= 0

          return big.read_bytes(payload)
                    .force_encoding("UTF-16LE")
                    .encode("UTF-8", invalid: :replace, undef: :replace)
                    .delete("\u0000")
        end

        payload = needed - 2
        return nil if payload <= 0

        buf.read_bytes(payload)
           .force_encoding("UTF-16LE")
           .encode("UTF-8", invalid: :replace, undef: :replace)
           .delete("\u0000")
      end
    end
  end
end
