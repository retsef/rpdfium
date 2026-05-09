# frozen_string_literal: true

module Rpdfium
  # Wrapper di pagina. Lazy-load di TextPage. Tutte le coordinate restituite
  # sono nello spazio "top-down" della pagina: (0,0) è in alto a sinistra,
  # x cresce verso destra, y verso il basso. PDFium usa "bottom-up" — la
  # conversione avviene qui una volta sola.
  class Page
    attr_reader :document, :index, :handle

    def initialize(document, index)
      @document = document
      @index    = index
      @handle   = Raw.FPDF_LoadPage(document.handle, index)
      raise PageError, "Could not load page #{index}" if @handle.null?

      @text_page = nil
      @closed = false
      ObjectSpace.define_finalizer(self, self.class.finalizer(@handle))
    end

    def self.finalizer(handle)
      proc { Raw.FPDF_ClosePage(handle) unless handle.null? }
    end

    # ===== Geometria =====

    def width;    Raw.FPDF_GetPageWidthF(@handle); end
    def height;   Raw.FPDF_GetPageHeightF(@handle); end

    # Rotazione in gradi: 0/90/180/270
    def rotation
      [0, 90, 180, 270][Raw.FPDFPage_GetRotation(@handle)] || 0
    end

    def has_transparency?
      Raw.FPDFPage_HasTransparency(@handle) == 1
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
      return nil if Raw.send(fn, @handle, l, b, r, t) == 0

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
    # `loose: true` usa FPDFText_GetLooseCharBox che dà bbox proporzionali
    # alla font size: più stabili per algoritmi di layout (raccomandato).
    def chars(loose: false)
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
    def line_segments(include_curves: false)
      n = Raw.FPDFPage_CountObjects(@handle)
      h = height
      out = []

      n.times do |i|
        obj = Raw.FPDFPage_GetObject(@handle, i)
        next if obj.null?
        next unless Raw.FPDFPageObj_GetType(obj) == Raw::PAGEOBJ_PATH

        stroke_width = read_stroke_width(obj)
        # Iteriamo i segmenti accumulando current_point (PDF è state machine)
        seg_count = Raw.FPDFPath_CountSegments(obj)
        current = nil
        first_in_subpath = nil

        seg_count.times do |si|
          seg = Raw.FPDFPath_GetPathSegment(obj, si)
          next if seg.null?

          x_buf = FFI::MemoryPointer.new(:float)
          y_buf = FFI::MemoryPointer.new(:float)
          Raw.FPDFPathSegment_GetPoint(seg, x_buf, y_buf)
          x = x_buf.read_float
          y = y_buf.read_float
          type = Raw.FPDFPathSegment_GetType(seg)
          closes = Raw.FPDFPathSegment_GetClose(seg) == 1

          case type
          when Raw::SEGMENT_MOVETO
            current = [x, y]
            first_in_subpath = current.dup
          when Raw::SEGMENT_LINETO
            if current
              out << build_segment(current[0], current[1], x, y, h, stroke_width)
            end
            current = [x, y]
          when Raw::SEGMENT_BEZIERTO
            # Bezier: tre punti consecutivi (control1, control2, end). PDFium
            # ritorna ogni segmento con coords del SUO endpoint, non dei
            # control points — quindi tre BEZIERTO consecutivi sono il
            # comando completo. Per i nostri scopi (linee tabella) interessa
            # solo il punto finale.
            if include_curves && current
              out << build_segment(current[0], current[1], x, y, h, stroke_width).merge(curve: true)
            end
            current = [x, y]
          end

          # PDF "closepath": linea da current → first_in_subpath
          if closes && current && first_in_subpath
            out << build_segment(current[0], current[1],
                                  first_in_subpath[0], first_in_subpath[1],
                                  h, stroke_width)
            current = first_in_subpath.dup
          end
        end
      end

      out
    end

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
      n = Raw.FPDFPage_CountObjects(@handle)
      h = height
      out = []

      l = FFI::MemoryPointer.new(:float)
      r = FFI::MemoryPointer.new(:float)
      b = FFI::MemoryPointer.new(:float)
      t = FFI::MemoryPointer.new(:float)

      n.times do |i|
        obj = Raw.FPDFPage_GetObject(@handle, i)
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
      n = Raw.FPDFPage_CountObjects(@handle)
      out = []
      n.times do |i|
        obj = Raw.FPDFPage_GetObject(@handle, i)
        next if obj.null?
        next unless Raw.FPDFPageObj_GetType(obj) == Raw::PAGEOBJ_IMAGE

        out << Image::Embedded.new(self, obj)
      end
      out
    end

    # ===== Annotazioni =====

    def annotations
      n = Raw.FPDFPage_GetAnnotCount(@handle)
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
        Raw.FPDF_RenderPageBitmap(bitmap, @handle, 0, 0, w, h,
                                  rotation_index(rotate), flags)
        if include_forms && @document.form_env
          Raw.FPDF_FFLDraw(@document.form_env.handle, bitmap, @handle,
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
      return if @closed

      @text_page&.close
      Raw.FPDF_ClosePage(@handle) unless @handle.null?
      @handle = FFI::Pointer::NULL
      @closed = true
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
    attr_reader :handle

    def initialize(page)
      @handle = Raw.FPDFText_LoadPage(page.handle)
      raise PageError, "Could not load text page" if @handle.null?

      @closed = false
      ObjectSpace.define_finalizer(self, self.class.finalizer(@handle))
    end

    def self.finalizer(handle)
      proc { Raw.FPDFText_ClosePage(handle) unless handle.null? }
    end

    def char_count
      Raw.FPDFText_CountChars(@handle)
    end

    def close
      return if @closed

      Raw.FPDFText_ClosePage(@handle) unless @handle.null?
      @handle = FFI::Pointer::NULL
      @closed = true
    end
  end
end
