# frozen_string_literal: true

module Rpdfium
  module Structure
    # Element di un PDF tagged StructTree.
    #
    # Un Element rappresenta un nodo della struttura logica del documento:
    # `Document`, `P` (paragrafo), `H1`..`H6` (headings), `Table`, `TR`,
    # `TH`, `TD`, `Figure`, `Span`, `Lbl`, `LI`, `Caption`, ecc. Vedi
    # PDF spec §14.8 per la tassonomia completa.
    #
    # Gli element non hanno una vita autonoma: appartengono al Tree che li
    # ha generati. Quando il Tree viene chiuso, gli element diventano
    # invalidi. Non chiamare metodi su un element dopo `tree.close`.
    #
    # Tutti i metodi sono read-only: PDFium non espone API per modificare
    # il StructTree (è una struttura "di sola lettura" anche nel suo C API
    # pubblico).
    class Element
      attr_reader :handle, :tree

      def initialize(tree, handle)
        @tree = tree
        @handle = handle
      end

      # Tipo strutturale dell'element (es. "P", "H1", "Table", "TR", "TD").
      # Nil se PDFium non riesce a leggerlo (element placeholder).
      def type
        read_utf16_string(:FPDF_StructElement_GetType)
      end

      # Tipo dell'oggetto PDF sottostante: di solito "StructElem", ma può
      # essere "MCR" (Marked Content Reference) o "OBJR" (Object Reference)
      # per nodi specializzati. La maggior parte degli utenti usa `type`.
      def obj_type
        read_utf16_string(:FPDF_StructElement_GetObjType)
      end

      # Title attribute (raro, usato in alcuni documenti per dare un nome
      # parlante all'element, es. "Capitolo 1").
      def title
        read_utf16_string(:FPDF_StructElement_GetTitle)
      end

      # ID univoco dell'element (se dichiarato nel /ID dictionary del
      # StructTreeRoot). Permette riferimenti cross-element (es. Headers
      # attribute di una cella TD che punta a un TH per id).
      def id
        read_utf16_string(:FPDF_StructElement_GetID)
      end

      # Lingua dichiarata sull'element (es. "it-IT", "en-US"). Ereditata
      # dal parent se non sovrascritta. Utile per pipeline language-aware.
      def lang
        read_utf16_string(:FPDF_StructElement_GetLang)
      end

      # ActualText: override del testo "logico" per l'element. Risolve
      # legature (PDF mostra `ﬁ` ma actual_text dice "fi"), simboli math
      # ("∫" → "integral"), abbreviazioni. Se presente, ha priorità sul
      # testo grafico per accessibility e ricerca.
      def actual_text
        read_utf16_string(:FPDF_StructElement_GetActualText)
      end

      # AltText: testo alternativo per Figure / Formula / immagini. PDF/UA
      # richiede che ogni Figure abbia un alt_text non vuoto.
      def alt_text
        read_utf16_string(:FPDF_StructElement_GetAltText)
      end

      # Expansion text per abbreviazioni (es. element type "Span" con
      # contenuto "Dr." e expansion "Doctor"). Usato per text-to-speech.
      def expansion
        read_utf16_string(:FPDF_StructElement_GetExpansion)
      end

      # Marked Content IDs collegati a questo element. Un element ha tipicamente
      # 1 MCID (es. una `<P>` ha tutto il testo del paragrafo dentro un BDC con
      # mcid=N) oppure 0 (element strutturale puro: `<Document>`, `<Table>`,
      # `<TR>` — i loro MCID stanno nei figli foglia).
      #
      # Per collegare un MCID al testo della pagina: leggi i page object e
      # raggruppa per `FPDFPageObj_GetMarkedContentID`. Vedi `Element#text`.
      def marked_content_ids
        first = Raw.FPDF_StructElement_GetMarkedContentID(@handle)
        count = Raw.FPDF_StructElement_GetMarkedContentIdCount(@handle)
        # Casi: GetMarkedContentIdCount ritorna -1 quando non ci sono MCID
        # diretti (element strutturale). GetMarkedContentID ritorna -1
        # nello stesso caso.
        return [] if count <= 0 && first < 0

        # Quando esiste un solo MCID, GetMarkedContentIdCount può ritornare
        # 0 o -1 mentre GetMarkedContentID dà il valore. Coalescenza:
        if count <= 0
          first >= 0 ? [first] : []
        else
          (0...count).filter_map do |i|
            mcid = Raw.FPDF_StructElement_GetMarkedContentIdAtIndex(@handle, i)
            mcid >= 0 ? mcid : nil
          end
        end
      end

      # Figli diretti dell'element. Ordinati come dichiarati nel PDF
      # (top-to-bottom, left-to-right per reading order).
      def children
        n = Raw.FPDF_StructElement_CountChildren(@handle)
        return [] if n <= 0

        (0...n).filter_map do |i|
          child_handle = Raw.FPDF_StructElement_GetChildAtIndex(@handle, i)
          child_handle.null? ? nil : Element.new(@tree, child_handle)
        end
      end

      # Parent. Nil per gli element root (figli diretti del StructTree).
      def parent
        h = Raw.FPDF_StructElement_GetParent(@handle)
        return nil if h.null?

        Element.new(@tree, h)
      end

      # Walk depth-first dell'intero sub-tree a partire da questo element.
      # Visita prima self, poi ricorsivamente i figli.
      # Senza block ritorna un Enumerator.
      def walk(&block)
        return enum_for(:walk) unless block

        yield self
        children.each { |c| c.walk(&block) }
      end

      # Foglie del sub-tree (element senza figli). Sono i nodi che
      # tipicamente hanno il MCID diretto.
      def leaves
        return [self] if children.empty?

        children.flat_map(&:leaves)
      end

      # Testo dell'element, ricostruito dalla pagina via MCID. Risoluzione:
      # 1. Se `actual_text` è presente, lo usa (gestisce legature/abbreviazioni).
      # 2. Altrimenti raccoglie tutti gli MCID del sub-tree (questo element
      #    + ricorsivamente i figli) e concatena il testo dei page objects
      #    con quei MCID, in document order.
      #
      # Per element strutturali puri (`Table`, `TR`) il testo è la
      # concatenazione di tutti i discendenti — utile come "summary".
      def text
        return actual_text if actual_text && !actual_text.empty?

        # Raccoglie MCID di tutto il sub-tree depth-first
        all_mcids = []
        walk { |el| all_mcids.concat(el.marked_content_ids) }
        return "" if all_mcids.empty?

        mcid_map = @tree.send(:mcid_text_map)
        all_mcids.filter_map { |id| mcid_map[id] }.join
      end

      # Attributi PDF strutturali. Ritorna un Hash { name => value } con
      # tutti gli attributi dichiarati su questo element (RowSpan, ColSpan,
      # Scope, Headers, BBox, ecc.). I valori sono Ruby-native: Integer,
      # Float, String, true/false, o Array per attributi "Headers" che
      # contengono liste di ID.
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

      # Helper UTF-16 string read con probe-then-fetch corretto. PDFium
      # restituisce il numero di byte necessari (incluso null terminator),
      # anche se il buffer è troppo piccolo.
      def read_utf16_string(fn_name)
        needed = Raw.send(fn_name, @handle, FFI::Pointer::NULL, 0)
        return nil if needed < 2

        buf = FFI::MemoryPointer.new(:uint8, needed)
        written = Raw.send(fn_name, @handle, buf, needed)
        return nil if written < 2

        # Clamp: leggi al massimo il buffer allocato meno il null terminator.
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

        # GetName ritorna ASCII (latin-1), non UTF-16
        name_buf.read_bytes(n).force_encoding("UTF-8").delete("\u0000")
      end

      def read_attr_value(attr, name)
        val_handle = Raw.FPDF_StructElement_Attr_GetValue(attr, name)
        return nil if val_handle.null?

        type = Raw.FPDF_StructElement_Attr_GetType(val_handle)
        # Type codes da fpdf_structtree.h:
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
        when 6 # Array → ricorsivamente raccolgo i figli
          n = Raw.FPDF_StructElement_Attr_CountChildren(val_handle)
          (0...n).filter_map do |i|
            child = Raw.FPDF_StructElement_Attr_GetChildAtIndex(val_handle, i)
            next nil if child.null?

            # Per ogni child applico la stessa lettura via type. Ma non ho
            # un "name" per accedere a Attr_GetValue su un child; il child
            # È già una FPDF_STRUCTELEMENT_ATTR_VALUE. Leggi direttamente.
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
        # Probe size
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
