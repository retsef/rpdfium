# frozen_string_literal: true

module Rpdfium
  module Structure
    # StructTree di una pagina PDF tagged.
    #
    # Per PDF tagged (PDF/UA, esport accessibility-friendly da
    # Word/LibreOffice/InDesign), espone la struttura logica del documento:
    # Document → P, H1, Table, TR, TH, TD, Figure, ecc.
    #
    # Per PDF NON tagged, `Page#struct_tree` ritorna nil. Per PDF "tagged
    # ma vuoti" (es. CR Banca d'Italia, StructTreeRoot presente ma con
    # element placeholder senza type/MCID), `Tree#empty?` ritorna true.
    #
    # Lifecycle: il Tree mantiene un handle PDFium che è "owning" — chiamare
    # `FPDF_StructTree_Close` lo dealloca. PDFium dealloca automaticamente
    # lo struct tree alla chiusura del documento, quindi in pratica:
    #
    #   - se non chiudi mai il tree esplicitamente, PDFium lo libera con
    #     `FPDF_CloseDocument` (zero perdita persistente, ma il tree resta
    #     in memoria fino alla chiusura del doc — può essere ~MB)
    #   - per controllo deterministico (rilascia subito), usa il blocco:
    #
    #       page.struct_tree do |tree|
    #         tree.walk { |el| ... }
    #       end
    #     all'uscita dal blocco il tree viene chiuso, anche su eccezione.
    #
    # Per scelta progettuale NON usiamo `ObjectSpace.define_finalizer`: se
    # il GC chiamasse `FPDF_StructTree_Close` dopo che il documento è già
    # stato chiuso, si avrebbe un use-after-free → segfault. La chiusura
    # via Document è sempre sicura; la chiusura via Tree.close (esplicita
    # o tramite blocco) richiede che il documento sia ancora vivo.
    class Tree
      attr_reader :handle, :page

      # Ritorna nil se la pagina non è tagged. Altrimenti un Tree.
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

        # NOTA: niente finalizer. FPDF_StructTree_Close è "owning": chiama
        # ~CPDF_StructTree() che libera l'oggetto. Se il documento PDF
        # viene chiuso prima del tree, il finalizer GC chiamerebbe Close
        # su memoria già liberata → segfault. Lifetime sicuro:
        #   - close esplicito via `tree.close` o via blocco
        #     `page.struct_tree { |tree| ... }`
        #   - se nessuno chiude esplicitamente, PDFium libera il tree
        #     insieme al documento al `FPDF_CloseDocument` (no leak
        #     persistent, solo riserva memoria fino a chiusura doc)
      end

      def closed?
        @closed
      end

      # Chiusura esplicita (idempotente). Dopo close, non chiamare metodi
      # su questo Tree né sugli Element che ha generato.
      def close
        return if @closed

        Raw.FPDF_StructTree_Close(@handle)
        @closed = true
        @mcid_text_cache = nil
      end

      # Numero di element root (figli diretti del StructTreeRoot per
      # questa pagina). Tipicamente 1 (`<Document>`), ma può essere
      # arbitrariamente alto su PDF strani (es. cu.pdf: 717 placeholder).
      def root_count
        n = Raw.FPDF_StructTree_CountChildren(@handle)
        [n, 0].max
      end

      # Element root (figli diretti del StructTreeRoot). Tipicamente 1
      # (`<Document>`).
      def roots
        (0...root_count).filter_map do |i|
          h = Raw.FPDF_StructTree_GetChildAtIndex(@handle, i)
          h.null? ? nil : Element.new(self, h)
        end
      end

      # True se il tree è strutturalmente vuoto (nessun element con type
      # leggibile dai root). Caso comune per PDF "fintamente tagged" come
      # CR Banca d'Italia: il StructTreeRoot esiste ma gli element sono
      # placeholder vuoti.
      def empty?
        return true if root_count.zero?

        roots.none? { |r| r.type || r.children.any? }
      end

      # Walk depth-first di TUTTI gli element del tree. Equivalente a
      # `roots.flat_map(&:walk)`. Senza block ritorna Enumerator.
      def walk(&block)
        return enum_for(:walk) unless block

        roots.each { |r| r.walk(&block) }
      end

      # Trova tutti gli element del tipo specificato (es. "Table", "P",
      # "Figure"). Confronto case-sensitive (i tipi PDF sono "Table",
      # "P", "H1", ecc.).
      def find_all(type:)
        walk.select { |el| el.type == type }
      end

      # Restituisce tutti gli element di tipo "Table". Conveniente per
      # estrazione tabelle semantica.
      def tables
        find_all(type: "Table")
      end

      # Page objects raggruppati per Marked Content ID, per consentire a
      # Element#text di risolvere il testo dei suoi MCID. La mappa è
      # costruita una sola volta per Tree e cached.
      #
      # Pubblico ma destinato a uso interno; non parte dell'API stabile.
      def mcid_text_map
        @mcid_text_cache ||= build_mcid_text_map
      end

      def to_s
        "#<Rpdfium::Structure::Tree roots=#{root_count}#{empty? ? ' empty' : ''}>"
      end
      alias inspect to_s

      private

      # Itera tutti i page objects (incl. Form XObject) e raggruppa il loro
      # testo per MCID. Il pattern probe-then-fetch su FPDFTextObj_GetText
      # è già rodato (vedi Page#read_text_obj_text_fast).
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
        # Probe con buffer 1024 byte (sufficiente per il 99% dei marked
        # content runs, che tipicamente sono parole singole o frasi brevi).
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
