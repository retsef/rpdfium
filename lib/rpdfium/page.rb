# frozen_string_literal: true

module Rpdfium
  # Wrapper di pagina. Lazy-load di TextPage. Tutte le coordinate restituite
  # sono nello spazio "top-down" della pagina: (0,0) è in alto a sinistra,
  # x cresce verso destra, y verso il basso. PDFium usa "bottom-up" — la
  # conversione avviene qui una volta sola.
  class Page
    attr_reader :document, :index

    def initialize(document, index)
      @document = document
      @index    = index
      handle    = Raw.FPDF_LoadPage(document.handle, index)
      raise PageError, "Could not load page #{index}" if handle.null?

      @text_page = nil
      # Stato condiviso col finalizer: idempotenza su close, sopravvive al GC
      # senza fare doppia chiamata FPDF_ClosePage. Tenere un riferimento a
      # @document garantisce che il Document non venga raccolto prima della
      # Page (FPDF_ClosePage richiede Document ancora vivo).
      @state = { handle: handle, closed: false }
      ObjectSpace.define_finalizer(self, self.class.finalizer(@state))
    end

    def self.finalizer(state)
      proc do
        next if state[:closed]
        next if state[:handle].null?

        Raw.FPDF_ClosePage(state[:handle])
        state[:closed] = true
      end
    end

    def handle
      @state[:handle]
    end

    # ===== Geometria =====

    def width;    Raw.FPDF_GetPageWidthF(@state[:handle]); end
    def height;   Raw.FPDF_GetPageHeightF(@state[:handle]); end

    # Rotazione in gradi: 0/90/180/270
    def rotation
      [0, 90, 180, 270][Raw.FPDFPage_GetRotation(@state[:handle])] || 0
    end

    def has_transparency?
      Raw.FPDFPage_HasTransparency(@state[:handle]) == 1
    end

    BOX_FUNCTIONS = {
      media: :FPDFPage_GetMediaBox,
      crop:  :FPDFPage_GetCropBox,
      bleed: :FPDFPage_GetBleedBox,
      trim:  :FPDFPage_GetTrimBox,
      art:   :FPDFPage_GetArtBox
    }.freeze

    def box(kind = :crop)
      fn = BOX_FUNCTIONS[kind] or raise ArgumentError, "Unknown box: #{kind}"
      l = FFI::MemoryPointer.new(:float)
      b = FFI::MemoryPointer.new(:float)
      r = FFI::MemoryPointer.new(:float)
      t = FFI::MemoryPointer.new(:float)
      return nil if Raw.send(fn, @state[:handle], l, b, r, t) == 0

      { left: l.read_float, bottom: b.read_float,
        right: r.read_float, top: t.read_float }
    end

    # ===== Testo (versione "semplice") =====

    def text
      tp = text_page
      n = tp.char_count
      return "" if n.zero?

      buf = FFI::MemoryPointer.new(:ushort, n + 1)
      Raw.FPDFText_GetText(tp.handle, 0, n, buf)
      buf.read_bytes((n + 1) * 2).force_encoding("UTF-16LE")
        .encode("UTF-8", invalid: :replace, undef: :replace)
        .delete("\x00")
    end

    # Estrae il testo dentro una bbox arbitraria (top-down coords).
    # Utile per "leggi l'intestazione di questa cella".
    def text_in_bbox(left:, top:, right:, bottom:)
      tp = text_page
      h = height
      # Converti a bottom-up per PDFium
      pdf_top    = h - top
      pdf_bottom = h - bottom
      # PDFium vuole: left, top, right, bottom dove top > bottom (PDF coords)
      # Probe size:
      n = Raw.FPDFText_GetBoundedText(
        tp.handle, left, pdf_top, right, pdf_bottom, FFI::Pointer::NULL, 0
      )
      return "" if n <= 0

      buf = FFI::MemoryPointer.new(:ushort, n)
      Raw.FPDFText_GetBoundedText(
        tp.handle, left, pdf_top, right, pdf_bottom, buf, n
      )
      buf.read_bytes(n * 2).force_encoding("UTF-16LE")
        .encode("UTF-8", invalid: :replace, undef: :replace)
        .delete("\x00")
    end

    # ===== Caratteri (char-level) =====

    # Ritorna ogni char con metadata ricco:
    #   :char     stringa (1 codepoint)
    #   :x0,:x1   bbox orizzontale
    #   :top,:bottom  bbox verticale (top-down: top < bottom)
    #   :origin_x, :origin_y  punto di inserimento del glifo (top-down)
    #   :angle    angolo di rotazione del glifo (radianti)
    #   :fontsize taglia in punti
    #   :font     nome font (se disponibile)
    #   :weight   spessore (es. 400=regular, 700=bold)
    #   :render_mode  modalità rendering (fill/stroke/invisible). Letto via
    #                 il text object che contiene il char (PDFium non
    #                 espone più una API char-level dopo chromium/6611).
    #                 nil su build PDFium antichi che non supportano il
    #                 lookup char→object.
    #   :generated  true se inserito da PDFium (es. spazi sintetici)
    #   :hyphen   true se trattino di sillabazione
    #   :unicode_error  true se PDFium non ha potuto mapparlo
    #
    # `loose: true` (DEFAULT) usa FPDFText_GetLooseCharBox: tutti i char
    # della stessa linea logica condividono la stessa bbox verticale (top/
    # bottom), proporzionale alla font size invece che al singolo glifo. È
    # esattamente il comportamento di pdfminer.six/pdfplumber, e l'unico
    # che permette al midpoint-test in Table#extract di catturare anche i
    # char di punteggiatura (`.`, `,`) insieme ai numeri allineati alla
    # baseline. Con `loose: false` si ottengono le bbox "tight" del singolo
    # glifo, utili per misure di layout fine ma sbagliate per il filtro
    # cella tabellare.
    def chars(loose: true, inject_spaces: false)
      # Cache: chars() viene chiamato una volta da Table#extract e poi
      # nuovamente da WordExtractor (passando per Extractor#page_words se
      # vertical/horizontal_strategy è :text). Ogni chiamata costa O(n) FFI
      # roundtrip per char — costoso su pagine con migliaia di char.
      cache_key = [loose, inject_spaces]
      @chars_cache ||= {}
      return @chars_cache[cache_key] if @chars_cache.key?(cache_key)

      raw = compute_chars(loose: loose)
      result = inject_spaces ? inject_synthetic_spaces(raw) : raw
      @chars_cache[cache_key] = result
    end

    # Post-processing OPT-IN: inserisce char `:generated` di tipo spazio
    # dove ci sono gap orizzontali significativi tra char della stessa
    # riga, per avvicinare il comportamento di rpdfium a quello di
    # pdfminer.six (che pdfplumber usa internamente).
    #
    # PDFium NON inserisce spazi sintetici nei "salti" del content stream
    # (es. tra "NETTO" e "BUSTA" se sono nello stesso text show con un
    # piccolo offset). pdfminer.six lo fa invece tramite il parametro
    # `word_margin`. Senza questi spazi, il WordExtractor non ha modo di
    # capire che due gruppi di char vicini sono parole separate.
    #
    # ATTENZIONE: la soglia 0.85 × char_width è un compromesso. PDFium non
    # espone l'advance del font dal content stream (l'unica info davvero
    # affidabile per decidere "spazio o no"); con char condensati come
    # quelli dei cedolini TeamSystem, alcuni gap interni tra glifi sono
    # genuinamente al limite con i gap inter-parola. Il default 0.85
    # privilegia "non spezzare parole valide" rispetto a "catturare ogni
    # spazio mancante". Per text-extraction più pdfminer-like, l'utente
    # può chiamare chars(inject_spaces: true) e accettare qualche falso
    # positivo (es. "Sede pr inc ipale" invece di "Sede principale").
    def inject_synthetic_spaces(chars)
      # Cluster per riga PRIMA del sort. Char della stessa riga visiva
      # possono avere `top` leggermente diversi (es. 88.406 vs 88.428,
      # differenza tipografica tra glifi con/senza descender). Ordinare
      # solo per [top, x0] li intercala sbagliato (tutti 88.406 poi tutti
      # 88.428), creando gap fittizi che generano spazi spuria.
      sorted_top = chars.sort_by { |c| c[:top] }
      rows = []
      sorted_top.each do |c|
        if rows.last && (c[:top] - rows.last.last[:top]).abs <= 1.0
          rows.last << c
        else
          rows << [c]
        end
      end

      result = []
      rows.each do |row|
        row_sorted = row.sort_by { |c| c[:x0] }
        prev = nil
        row_sorted.each do |c|
          if prev &&
             c[:char] != " " && prev[:char] != " " &&
             !prev[:generated] && !c[:generated]
            gap = c[:x0] - prev[:x1]
            char_w = ((prev[:x1] - prev[:x0]) + (c[:x1] - c[:x0])) / 2.0
            threshold = char_w > 0 ? char_w * 0.85 : 1.5
            if gap > threshold
              result << {
                char: " ", codepoint: 32,
                x0: prev[:x1], x1: c[:x0],
                top: prev[:top], bottom: prev[:bottom],
                origin_x: prev[:x1], origin_y: prev[:origin_y],
                angle: 0.0, fontsize: prev[:fontsize], font: prev[:font],
                weight: prev[:weight], render_mode: nil,
                generated: true, hyphen: false, unicode_error: false
              }
            end
          end
          result << c
          prev = c
        end
      end
      result
    end

    def compute_chars(loose:)
      tp = text_page
      n = tp.char_count
      return [] if n.zero?

      h = height
      result = Array.new(n)
      l = FFI::MemoryPointer.new(:double)
      r = FFI::MemoryPointer.new(:double)
      b = FFI::MemoryPointer.new(:double)
      t = FFI::MemoryPointer.new(:double)
      ox = FFI::MemoryPointer.new(:double)
      oy = FFI::MemoryPointer.new(:double)
      rect = Raw::FS_RECTF.new
      font_buf = FFI::MemoryPointer.new(:uchar, 256)
      flags_buf = FFI::MemoryPointer.new(:int)

      # Cache: il render mode è una proprietà del TEXT OBJECT, non del char.
      # Tutti i char dello stesso text object hanno lo stesso render mode.
      # Convertiamo il pointer FFI in una chiave Integer (`address`) perché
      # FFI::Pointer non è una chiave Hash stabile (#hash differisce tra
      # istanze anche se address uguale).
      render_mode_cache = {}
      get_render_mode = lambda do |char_index|
        text_obj = Raw.FPDFText_GetTextObject(tp.handle, char_index)
        return -1 if text_obj.null?

        addr = text_obj.address
        render_mode_cache[addr] ||= Raw.FPDFTextObj_GetTextRenderMode(text_obj)
      end

      n.times do |i|
        if loose
          if Raw.FPDFText_GetLooseCharBox(tp.handle, i, rect) == 1
            x0 = rect[:left]; x1 = rect[:right]
            y_top = rect[:top]; y_bot = rect[:bottom]
          else
            x0 = x1 = y_top = y_bot = 0.0
          end
        else
          Raw.FPDFText_GetCharBox(tp.handle, i, l, r, b, t)
          x0 = l.read_double; x1 = r.read_double
          y_top = t.read_double; y_bot = b.read_double
        end
        Raw.FPDFText_GetCharOrigin(tp.handle, i, ox, oy)
        # Font name (best-effort): GetFontInfo è disponibile su tutte le
        # versioni di PDFium ed è il path più portabile a char-level.
        n_bytes = Raw.FPDFText_GetFontInfo(tp.handle, i, font_buf, 256, flags_buf)
        font_name = if n_bytes > 1
                      font_buf.read_bytes(n_bytes - 1).force_encoding("UTF-8")
                    end
        cp = Raw.FPDFText_GetUnicode(tp.handle, i)

        # render_mode via il path nuovo. Su PDFium che non espone più
        # FPDFText_GetTextRenderMode (chromium/6611+), questa è l'UNICA
        # strada. La cache rende l'overhead marginale anche con migliaia
        # di char (un solo Get/Lookup per text object).
        rm = begin
          get_render_mode.call(i)
        rescue Rpdfium::LoadError
          # FPDFText_GetTextObject non disponibile in build PDFium
          # antichi (< chromium/6611). In quel caso lasciamo nil:
          # gli utenti su build vecchi non hanno comunque mai avuto
          # render_mode affidabile per via di altri bug upstream.
          nil
        end

        result[i] = {
          char:     safe_codepoint(cp),
          codepoint: cp,
          x0:       x0,
          x1:       x1,
          top:      h - y_top,    # bottom-up → top-down
          bottom:   h - y_bot,
          origin_x: ox.read_double,
          origin_y: h - oy.read_double,
          angle:    Raw.FPDFText_GetCharAngle(tp.handle, i),
          fontsize: Raw.FPDFText_GetFontSize(tp.handle, i),
          font:     font_name,
          weight:   Raw.FPDFText_GetFontWeight(tp.handle, i),
          render_mode:   rm,
          generated:     Raw.FPDFText_IsGenerated(tp.handle, i) == 1,
          hyphen:        Raw.FPDFText_IsHyphen(tp.handle, i) == 1,
          unicode_error: Raw.FPDFText_HasUnicodeMapError(tp.handle, i) == 1
        }
      end
      result
    end

    # Aggrega i caratteri in "parole" via clustering layout-aware.
    # Le parole sono sequenze di char non-spazio adiacenti orizzontalmente.
    def words(x_tolerance: 3.0, y_tolerance: 3.0, **char_opts)
      cs = chars(**char_opts)
      return [] if cs.empty?

      # Raggruppa in righe per y
      rows = group_consecutive(cs.sort_by { |c| [c[:top], c[:x0]] }) do |a, b|
        (a[:top] - b[:top]).abs <= y_tolerance
      end

      rows.flat_map do |row|
        sorted = row.sort_by { |c| c[:x0] }
        # Spezza su gap > x_tolerance o spazio esplicito
        word_groups = []
        buf = []
        sorted.each do |c|
          gap = buf.empty? ? 0.0 : (c[:x0] - buf.last[:x1])
          space = c[:char].match?(/\s/) || c[:generated]
          if buf.empty?
            buf << c unless space
          elsif space || gap > x_tolerance
            word_groups << buf unless buf.empty?
            buf = space ? [] : [c]
          else
            buf << c
          end
        end
        word_groups << buf unless buf.empty?
        word_groups.map { |g| word_from_chars(g) }
      end
    end

    # ===== Linee vettoriali (path segments REALI) =====

    # Estrae tutti i segmenti di linea (LINETO) dei path objects.
    # Ritorna Array<Hash>:
    #   :x0,:y0,:x1,:y1  estremi (top-down)
    #   :stroke_width    spessore tratto
    #   :horizontal/:vertical  derivati per comodità
    #
    # Per le tabelle interessano principalmente i segmenti orizzontali e
    # verticali "puri". Beziers e segmenti obliqui vengono ignorati di default
    # (passa `include_curves: true` per averli come bbox dei loro punti).
    #
    # Discende ricorsivamente nei Form XObjects applicando la loro matrice
    # di trasformazione. Molti PDF (TeamSystem, Zucchetti, template Excel)
    # incapsulano l'intera pagina in un Form XObject — senza discesa, qui
    # vedremmo zero linee anche se visivamente la pagina è piena di
    # bordi/separatori. Comportamento allineato a pdfminer.six (e quindi a
    # pdfplumber).
    def line_segments(include_curves: false)
      out = []
      collect_line_segments(@state[:handle], identity_matrix, height,
                             include_curves, out, page_object: false)
      out
    end

    private

    # Matrice identità nello spazio PDF: [1, 0, 0, 1, 0, 0]
    # (a, b, c, d, e, f) → (x', y') = (a*x + c*y + e,  b*x + d*y + f)
    def identity_matrix
      { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0 }
    end

    # Compone due trasformazioni affini PDF: applica `child` PRIMA di `parent`
    # nello spazio PDF (notazione pdfminer.six "apply_matrix_norm").
    # Equivale a: result = parent * child  (col-major).
    def compose_matrix(parent, child)
      {
        a: parent[:a] * child[:a] + parent[:c] * child[:b],
        b: parent[:b] * child[:a] + parent[:d] * child[:b],
        c: parent[:a] * child[:c] + parent[:c] * child[:d],
        d: parent[:b] * child[:c] + parent[:d] * child[:d],
        e: parent[:a] * child[:e] + parent[:c] * child[:f] + parent[:e],
        f: parent[:b] * child[:e] + parent[:d] * child[:f] + parent[:f]
      }
    end

    def apply_matrix(m, x, y)
      [m[:a] * x + m[:c] * y + m[:e],
       m[:b] * x + m[:d] * y + m[:f]]
    end

    def read_object_matrix(obj)
      mat = Raw::FS_MATRIX.new
      return identity_matrix if Raw.FPDFPageObj_GetMatrix(obj, mat) == 0

      { a: mat[:a], b: mat[:b], c: mat[:c], d: mat[:d],
        e: mat[:e], f: mat[:f] }
    end

    # Itera oggetti di una page o di un Form XObject, applicando ricorsivamente
    # la matrice di trasformazione. `parent` = handle (FPDF_PAGE alla radice o
    # FPDF_PAGEOBJECT per i form xobjects). `page_object: true` se parent è un
    # form xobject.
    def collect_line_segments(parent, ctm, page_h, include_curves, out, page_object:)
      n = if page_object
            Raw.FPDFFormObj_CountObjects(parent)
          else
            Raw.FPDFPage_CountObjects(parent)
          end

      n.times do |i|
        obj = if page_object
                Raw.FPDFFormObj_GetObject(parent, i)
              else
                Raw.FPDFPage_GetObject(parent, i)
              end
        next if obj.null?

        type = Raw.FPDFPageObj_GetType(obj)
        case type
        when Raw::PAGEOBJ_PATH
          extract_path_segments(obj, ctm, page_h, include_curves, out)
        when Raw::PAGEOBJ_FORM
          # Discendi nel form xobject componendo la sua matrice col CTM
          child_ctm = compose_matrix(ctm, read_object_matrix(obj))
          collect_line_segments(obj, child_ctm, page_h, include_curves, out,
                                page_object: true)
        end
      end
    end

    def extract_path_segments(obj, ctm, page_h, include_curves, out)
      stroke_width = read_stroke_width(obj)
      # Comporre la matrice del path object stesso col CTM corrente.
      # I path objects HANNO una propria matrice (oltre a quella del
      # form parent), che pdfium applica automaticamente al rendering.
      path_ctm = compose_matrix(ctm, read_object_matrix(obj))

      seg_count = Raw.FPDFPath_CountSegments(obj)
      current = nil
      first_in_subpath = nil

      seg_count.times do |si|
        seg = Raw.FPDFPath_GetPathSegment(obj, si)
        next if seg.null?

        x_buf = FFI::MemoryPointer.new(:float)
        y_buf = FFI::MemoryPointer.new(:float)
        Raw.FPDFPathSegment_GetPoint(seg, x_buf, y_buf)
        # Coordinate nello spazio "del path", da trasformare al sistema-pagina
        local_x = x_buf.read_float
        local_y = y_buf.read_float
        x, y = apply_matrix(path_ctm, local_x, local_y)
        type = Raw.FPDFPathSegment_GetType(seg)
        closes = Raw.FPDFPathSegment_GetClose(seg) == 1

        case type
        when Raw::SEGMENT_MOVETO
          current = [x, y]
          first_in_subpath = current.dup
        when Raw::SEGMENT_LINETO
          out << build_segment(current[0], current[1], x, y, page_h, stroke_width) if current
          current = [x, y]
        when Raw::SEGMENT_BEZIERTO
          if include_curves && current
            out << build_segment(current[0], current[1], x, y, page_h, stroke_width)
                    .merge(curve: true)
          end
          current = [x, y]
        end

        if closes && current && first_in_subpath
          out << build_segment(current[0], current[1],
                                first_in_subpath[0], first_in_subpath[1],
                                page_h, stroke_width)
          current = first_in_subpath.dup
        end
      end
    end

    public

    # Linee orizzontali: dy ~ 0 entro tolleranza
    def horizontal_lines(tolerance: 0.5)
      line_segments.select { |s| (s[:y0] - s[:y1]).abs <= tolerance }
                   .map { |s| { y: (s[:y0] + s[:y1]) / 2.0,
                                x0: [s[:x0], s[:x1]].min,
                                x1: [s[:x0], s[:x1]].max,
                                stroke_width: s[:stroke_width] } }
    end

    # Linee verticali: dx ~ 0 entro tolleranza
    def vertical_lines(tolerance: 0.5)
      line_segments.select { |s| (s[:x0] - s[:x1]).abs <= tolerance }
                   .map { |s| { x: (s[:x0] + s[:x1]) / 2.0,
                                top: [s[:y0], s[:y1]].min,
                                bottom: [s[:y0], s[:y1]].max,
                                stroke_width: s[:stroke_width] } }
    end

    # Compat con la prima versione: bbox dei path objects (utile per
    # rectangles disegnati come bordi sottili).
    def vector_rects
      n = Raw.FPDFPage_CountObjects(@state[:handle])
      h = height
      out = []

      l = FFI::MemoryPointer.new(:float)
      r = FFI::MemoryPointer.new(:float)
      b = FFI::MemoryPointer.new(:float)
      t = FFI::MemoryPointer.new(:float)

      n.times do |i|
        obj = Raw.FPDFPage_GetObject(@state[:handle], i)
        next if obj.null?
        next unless Raw.FPDFPageObj_GetType(obj) == Raw::PAGEOBJ_PATH
        next unless Raw.FPDFPageObj_GetBounds(obj, l, r, b, t) == 1

        out << { x0: l.read_float, x1: r.read_float,
                 top: h - t.read_float, bottom: h - b.read_float }
      end
      out
    end

    # ===== Immagini =====

    def images
      n = Raw.FPDFPage_CountObjects(@state[:handle])
      out = []
      n.times do |i|
        obj = Raw.FPDFPage_GetObject(@state[:handle], i)
        next if obj.null?
        next unless Raw.FPDFPageObj_GetType(obj) == Raw::PAGEOBJ_IMAGE

        out << Image::Embedded.new(self, obj)
      end
      out
    end

    # ===== Annotazioni =====

    def annotations
      n = Raw.FPDFPage_GetAnnotCount(@state[:handle])
      Array.new(n) { |i| Annotation.new(self, i) }
    end

    # Solo annotazioni link (cliccabili, esterne o interne)
    def links
      annotations.select { |a| a.subtype == :link }
    end

    # Solo widget di form
    def form_fields
      return [] unless @document.has_forms?

      annotations.select { |a| a.subtype == :widget }
                 .map    { |a| Form::Field.new(@document.form_env, a) }
    end

    # ===== Rendering =====

    # Render a bitmap. `output` può essere :rgba (default), :bgra, :gray.
    # Ritorna [w, h, bytes] dove bytes è una stringa binaria.
    # Se include_forms è true e il documento ha forms, sovrappone i widget.
    def render(scale: 2.0, rotate: 0, output: :rgba,
               include_annotations: false, include_forms: false,
               background: 0xFFFFFFFF)
      w = (width  * scale).round
      h = (height * scale).round
      flags = 0
      flags |= Raw::FPDF_ANNOT if include_annotations
      flags |= Raw::FPDF_REVERSE_BYTE_ORDER if output == :rgba
      format = output == :gray ? Raw::FPDFBitmap_Gray : Raw::FPDFBitmap_BGRA

      bitmap = Raw.FPDFBitmap_CreateEx(w, h, format, FFI::Pointer::NULL, 0)
      raise Error, "Bitmap allocation failed" if bitmap.null?

      begin
        Raw.FPDFBitmap_FillRect(bitmap, 0, 0, w, h, background)
        Raw.FPDF_RenderPageBitmap(bitmap, @state[:handle], 0, 0, w, h,
                                  rotation_index(rotate), flags)
        if include_forms && @document.form_env
          Raw.FPDF_FFLDraw(@document.form_env.handle, bitmap, @state[:handle],
                           0, 0, w, h, rotation_index(rotate), flags)
        end
        stride = Raw.FPDFBitmap_GetStride(bitmap)
        buf    = Raw.FPDFBitmap_GetBuffer(bitmap)
        # Lo stride può eccedere w*bpp per padding di allineamento.
        # In BGRA è quasi sempre w*4, ma rispettiamolo per sicurezza.
        bytes  = buf.read_bytes(stride * h)
        [w, h, bytes, stride]
      ensure
        Raw.FPDFBitmap_Destroy(bitmap)
      end
    end

    # Rendering diretto a PNG file. Usa Rpdfium::IO::PNG (puro Ruby, zero dep).
    def render_to_png(path, **opts)
      w, h, bytes, stride = render(output: :rgba, **opts)
      Rpdfium::IO::PNG.write(path, w, h, bytes, stride: stride)
      path
    end

    # ===== Search =====

    def search(query, **opts)
      Search.new(self, query, **opts)
    end

    # ===== Internals =====

    def text_page
      @text_page ||= TextPage.new(self)
    end

    def close
      return if @state[:closed]

      @text_page&.close
      Raw.FPDF_ClosePage(@state[:handle]) unless @state[:handle].null?
      @state[:handle] = FFI::Pointer::NULL
      @state[:closed] = true
      ObjectSpace.undefine_finalizer(self)
    end

    private

    def safe_codepoint(cp)
      return "" if cp.zero?
      return "" if cp > 0x10FFFF || (0xD800..0xDFFF).cover?(cp)

      [cp].pack("U")
    rescue RangeError, ArgumentError
      ""
    end

    def read_stroke_width(obj)
      buf = FFI::MemoryPointer.new(:float)
      return 1.0 if Raw.FPDFPageObj_GetStrokeWidth(obj, buf) == 0

      buf.read_float
    end

    def build_segment(x0, y0, x1, y1, page_h, stroke_width)
      {
        x0: x0, y0: page_h - y0,
        x1: x1, y1: page_h - y1,
        stroke_width: stroke_width
      }
    end

    # Raggruppa elementi consecutivi se un blocco li considera equivalenti.
    def group_consecutive(arr)
      groups = []
      current = []
      arr.each do |elem|
        if current.empty? || yield(current.last, elem)
          current << elem
        else
          groups << current
          current = [elem]
        end
      end
      groups << current unless current.empty?
      groups
    end

    def word_from_chars(chars)
      {
        text:   chars.map { |c| c[:char] }.join,
        x0:     chars.first[:x0],
        x1:     chars.last[:x1],
        top:    chars.map { |c| c[:top] }.min,
        bottom: chars.map { |c| c[:bottom] }.max,
        fontsize: chars.first[:fontsize],
        font:   chars.first[:font],
        chars:  chars
      }
    end

    def rotation_index(rotate)
      case rotate
      when 0   then 0
      when 90  then 1
      when 180 then 2
      when 270 then 3
      else (rotate / 90) % 4
      end
    end
  end

  # Wrapper per FPDF_TEXTPAGE
  class TextPage
    def initialize(page)
      handle = Raw.FPDFText_LoadPage(page.handle)
      raise PageError, "Could not load text page" if handle.null?

      @state = { handle: handle, closed: false }
      ObjectSpace.define_finalizer(self, self.class.finalizer(@state))
    end

    def self.finalizer(state)
      proc do
        next if state[:closed]
        next if state[:handle].null?

        Raw.FPDFText_ClosePage(state[:handle])
        state[:closed] = true
      end
    end

    def handle
      @state[:handle]
    end

    def char_count
      Raw.FPDFText_CountChars(@state[:handle])
    end

    def close
      return if @state[:closed]

      Raw.FPDFText_ClosePage(@state[:handle]) unless @state[:handle].null?
      @state[:handle] = FFI::Pointer::NULL
      @state[:closed] = true
      ObjectSpace.undefine_finalizer(self)
    end
  end
end
