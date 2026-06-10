# frozen_string_literal: true

module Rpdfium
  module Structure
    # Element of a tagged PDF StructTree.
    #
    # An Element represents a node of the document's logical structure:
    # `Document`, `P` (paragraph), `H1`..`H6` (headings), `Table`, `TR`,
    # `TH`, `TD`, `Figure`, `Span`, `Lbl`, `LI`, `Caption`, etc. See
    # PDF spec §14.8 for the complete taxonomy.
    #
    # Elements have no independent lifetime: they belong to the Tree that
    # produced them. When the Tree is closed, the elements become
    # invalid. Do not call methods on an element after `tree.close`.
    #
    # All methods are read-only: PDFium exposes no API to modify the
    # StructTree (it is a "read-only" structure even in its public C
    # API).
    class Element
      attr_reader :handle, :tree

      def initialize(tree, handle)
        @tree = tree
        @handle = handle
      end

      # Structural type of the element (e.g. "P", "H1", "Table", "TR", "TD").
      # Nil if PDFium cannot read it (placeholder element).
      def type
        read_utf16_string(:FPDF_StructElement_GetType)
      end

      # Type of the underlying PDF object: usually "StructElem", but may
      # be "MCR" (Marked Content Reference) or "OBJR" (Object Reference)
      # for specialized nodes. Most users use `type`.
      def obj_type
        read_utf16_string(:FPDF_StructElement_GetObjType)
      end

      # Title attribute (rare, used in some documents to give the element
      # a descriptive name, e.g. "Capitolo 1").
      def title
        read_utf16_string(:FPDF_StructElement_GetTitle)
      end

      # Unique ID of the element (if declared in the /ID dictionary of
      # the StructTreeRoot). Enables cross-element references (e.g. the
      # Headers attribute of a TD cell pointing to a TH by id).
      def id
        read_utf16_string(:FPDF_StructElement_GetID)
      end

      # Language declared on the element (e.g. "it-IT", "en-US"). Inherited
      # from the parent if not overridden. Useful for language-aware pipelines.
      def lang
        read_utf16_string(:FPDF_StructElement_GetLang)
      end

      # ActualText: override of the "logical" text for the element. Resolves
      # ligatures (the PDF shows `ﬁ` but actual_text says "fi"), math symbols
      # ("∫" → "integral"), abbreviations. When present, it takes precedence
      # over the graphical text for accessibility and search.
      def actual_text
        read_utf16_string(:FPDF_StructElement_GetActualText)
      end

      # AltText: alternative text for Figure / Formula / images. PDF/UA
      # requires every Figure to have a non-empty alt_text.
      def alt_text
        read_utf16_string(:FPDF_StructElement_GetAltText)
      end

      # Expansion text for abbreviations (e.g. an element of type "Span"
      # with content "Dr." and expansion "Doctor"). Used for text-to-speech.
      def expansion
        read_utf16_string(:FPDF_StructElement_GetExpansion)
      end

      # Marked Content IDs linked to this element. An element typically has
      # 1 MCID (e.g. a `<P>` holds all the paragraph text inside a BDC with
      # mcid=N) or 0 (a pure structural element: `<Document>`, `<Table>`,
      # `<TR>` — their MCIDs reside in the leaf children).
      #
      # To link an MCID to the page text: read the page objects and group
      # by `FPDFPageObj_GetMarkedContentID`. See `Element#text`.
      def marked_content_ids
        first = Raw.FPDF_StructElement_GetMarkedContentID(@handle)
        count = Raw.FPDF_StructElement_GetMarkedContentIdCount(@handle)
        # Cases: GetMarkedContentIdCount returns -1 when there are no direct
        # MCIDs (structural element). GetMarkedContentID returns -1 in the
        # same case.
        return [] if count <= 0 && first < 0

        # When a single MCID exists, GetMarkedContentIdCount may return
        # 0 or -1 while GetMarkedContentID provides the value. Coalesce:
        if count <= 0
          first >= 0 ? [first] : []
        else
          (0...count).filter_map do |i|
            mcid = Raw.FPDF_StructElement_GetMarkedContentIdAtIndex(@handle, i)
            mcid >= 0 ? mcid : nil
          end
        end
      end

      # Direct children of the element. Ordered as declared in the PDF
      # (top-to-bottom, left-to-right for reading order).
      def children
        n = Raw.FPDF_StructElement_CountChildren(@handle)
        return [] if n <= 0

        (0...n).filter_map do |i|
          child_handle = Raw.FPDF_StructElement_GetChildAtIndex(@handle, i)
          child_handle.null? ? nil : Element.new(@tree, child_handle)
        end
      end

      # Parent. Nil for root elements (direct children of the StructTree).
      def parent
        h = Raw.FPDF_StructElement_GetParent(@handle)
        return nil if h.null?

        Element.new(@tree, h)
      end

      # Depth-first walk of the entire sub-tree starting from this element.
      # Visits self first, then recursively the children.
      # Without a block returns an Enumerator.
      def walk(&block)
        return enum_for(:walk) unless block

        yield self
        children.each { |c| c.walk(&block) }
      end

      # Leaves of the sub-tree (elements without children). These are the
      # nodes that typically hold the direct MCID.
      def leaves
        return [self] if children.empty?

        children.flat_map(&:leaves)
      end

      # Text of the element, reconstructed from the page via MCID. Resolution:
      # 1. If `actual_text` is present, use it (handles ligatures/abbreviations).
      # 2. Otherwise collect all MCIDs of the sub-tree (this element
      #    + recursively the children) and concatenate the text of the page
      #    objects with those MCIDs, in document order.
      #
      # For pure structural elements (`Table`, `TR`) the text is the
      # concatenation of all descendants — useful as a "summary".
      def text
        return actual_text if actual_text && !actual_text.empty?

        # Collect MCIDs of the entire sub-tree depth-first
        all_mcids = []
        walk { |el| all_mcids.concat(el.marked_content_ids) }
        return "" if all_mcids.empty?

        mcid_map = @tree.send(:mcid_text_map)
        all_mcids.filter_map { |id| mcid_map[id] }.join
      end

      # Structural PDF attributes. Returns a Hash { name => value } with
      # all attributes declared on this element (RowSpan, ColSpan,
      # Scope, Headers, BBox, etc.). Values are Ruby-native: Integer,
      # Float, String, true/false, or Array for "Headers" attributes that
      # contain lists of IDs.
      def attributes
        result = {}
        attr_count = Raw.FPDF_StructElement_GetAttributeCount(@handle)
        return result if attr_count <= 0

        (0...attr_count).each do |ai|
          attr = Raw.FPDF_StructElement_GetAttributeAtIndex(@handle, ai)
          next if attr.null?

          key_count = Raw.FPDF_StructElement_Attr_GetCount(attr)
          (0...key_count).each do |ki|
            name = read_attr_name(attr, ki)
            next if name.nil? || name.empty?

            value = read_attr_value(attr, name)
            result[name] = value unless value.nil?
          end
        end
        result
      end

      def to_s
        parts = ["<#{type || obj_type || '?'}>"]
        mcids = marked_content_ids
        parts << "mcid=#{mcids.first}" if mcids.size == 1
        parts << "mcids=#{mcids.inspect}" if mcids.size > 1
        parts << "lang=#{lang.inspect}" if lang
        parts << "actual_text=#{actual_text.inspect[0, 30]}" if actual_text
        parts << "alt_text=#{alt_text.inspect[0, 30]}" if alt_text
        parts.join(" ")
      end

      def inspect
        "#<Rpdfium::Structure::Element #{self}>"
      end

      private

      # UTF-16 string read helper with proper probe-then-fetch. PDFium
      # returns the number of bytes required (including the null
      # terminator), even when the buffer is too small.
      def read_utf16_string(fn_name)
        needed = Raw.send(fn_name, @handle, FFI::Pointer::NULL, 0)
        return nil if needed < 2

        buf = FFI::MemoryPointer.new(:uint8, needed)
        written = Raw.send(fn_name, @handle, buf, needed)
        return nil if written < 2

        # Clamp: read at most the allocated buffer minus the null terminator.
        payload = [written - 2, needed - 2].min
        return nil if payload <= 0

        s = buf.read_bytes(payload)
               .force_encoding("UTF-16LE")
               .encode("UTF-8")
               .delete("\u0000")
        s.empty? ? nil : s
      end

      def read_attr_name(attr, index)
        len_buf = FFI::MemoryPointer.new(:ulong)
        name_buf = FFI::MemoryPointer.new(:uint8, 128)
        ok = Raw.FPDF_StructElement_Attr_GetName(attr, index, name_buf, 128, len_buf)
        return nil if ok == 0

        n = len_buf.read_ulong
        return nil if n.zero?

        # GetName returns ASCII (latin-1), not UTF-16
        name_buf.read_bytes(n).force_encoding("UTF-8").delete("\u0000")
      end

      def read_attr_value(attr, name)
        val_handle = Raw.FPDF_StructElement_Attr_GetValue(attr, name)
        return nil if val_handle.null?

        type = Raw.FPDF_StructElement_Attr_GetType(val_handle)
        # Type codes from fpdf_structtree.h:
        #   1 = Boolean, 2 = Number, 3 = String, 4 = Blob,
        #   5 = Name, 6 = Array, 7 = Dictionary
        case type
        when 1 # Boolean
          buf = FFI::MemoryPointer.new(:int)
          Raw.FPDF_StructElement_Attr_GetBooleanValue(val_handle, buf) == 1 ? buf.read_int != 0 : nil
        when 2 # Number
          buf = FFI::MemoryPointer.new(:float)
          Raw.FPDF_StructElement_Attr_GetNumberValue(val_handle, buf) == 1 ? buf.read_float : nil
        when 3, 5 # String / Name
          read_attr_string_value(val_handle)
        when 4 # Blob (raw bytes)
          read_attr_blob_value(val_handle)
        when 6 # Array → recursively collect the children
          n = Raw.FPDF_StructElement_Attr_CountChildren(val_handle)
          (0...n).filter_map do |i|
            child = Raw.FPDF_StructElement_Attr_GetChildAtIndex(val_handle, i)
            next nil if child.null?

            # For each child apply the same read via type. But there is no
            # "name" to access Attr_GetValue on a child; the child is
            # already an FPDF_STRUCTELEMENT_ATTR_VALUE. Read it directly.
            read_attr_value_handle(child)
          end
        else
          nil
        end
      end

      def read_attr_value_handle(val_handle)
        type = Raw.FPDF_StructElement_Attr_GetType(val_handle)
        case type
        when 1
          buf = FFI::MemoryPointer.new(:int)
          Raw.FPDF_StructElement_Attr_GetBooleanValue(val_handle, buf) == 1 ? buf.read_int != 0 : nil
        when 2
          buf = FFI::MemoryPointer.new(:float)
          Raw.FPDF_StructElement_Attr_GetNumberValue(val_handle, buf) == 1 ? buf.read_float : nil
        when 3, 5
          read_attr_string_value(val_handle)
        when 4
          read_attr_blob_value(val_handle)
        else
          nil
        end
      end

      def read_attr_string_value(val_handle)
        len_buf = FFI::MemoryPointer.new(:ulong)
        # Probe the size
        Raw.FPDF_StructElement_Attr_GetStringValue(val_handle,
                                                    FFI::Pointer::NULL, 0, len_buf)
        n = len_buf.read_ulong
        return nil if n < 2

        buf = FFI::MemoryPointer.new(:uint8, n)
        ok = Raw.FPDF_StructElement_Attr_GetStringValue(val_handle, buf, n, len_buf)
        return nil if ok == 0

        written = len_buf.read_ulong
        payload = [written - 2, n - 2].min
        return nil if payload <= 0

        buf.read_bytes(payload).force_encoding("UTF-16LE")
           .encode("UTF-8").delete("\u0000")
      end

      def read_attr_blob_value(val_handle)
        len_buf = FFI::MemoryPointer.new(:ulong)
        Raw.FPDF_StructElement_Attr_GetBlobValue(val_handle,
                                                  FFI::Pointer::NULL, 0, len_buf)
        n = len_buf.read_ulong
        return nil if n.zero?

        buf = FFI::MemoryPointer.new(:uint8, n)
        ok = Raw.FPDF_StructElement_Attr_GetBlobValue(val_handle, buf, n, len_buf)
        return nil if ok == 0

        buf.read_bytes(len_buf.read_ulong)
      end
    end
  end
end
