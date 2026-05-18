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

    # Accessor pdfplumber-compatibili. Restituiscono il box come tuple
    # [x0, top, x1, bottom] in coordinate top-down (lo stesso sistema
    # usato da chars, edges, table cells). Ritornano nil se il box non
    # è definito nel PDF (es. ArtBox o BleedBox sono spesso assenti).
    #
    # Esempio d'uso:
    #   crop = page.cropbox        # → [0.0, 0.0, 595.28, 841.88] o nil
    #   crop != [0, 0, page.width, page.height]  # PDF ha un crop esplicito
    def mediabox; box_to_topdown(box(:media)); end

    # PDF spec 14.11.2: se CropBox è assente, default è MediaBox. La cropbox è
    # l'area "visibile" della pagina; per PDF da gestionali coincide spesso
    # con la MediaBox. Pdfplumber fa il fallback automatico.
    def cropbox
      box_to_topdown(box(:crop)) || mediabox
    end

    def bleedbox; box_to_topdown(box(:bleed)); end
    def trimbox;  box_to_topdown(box(:trim));  end
    def artbox;   box_to_topdown(box(:art));   end

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
    def chars(loose: true, inject_spaces: true, lean: false)
      # Cache: chars() viene chiamato una volta da Table#extract e poi
      # nuovamente da WordExtractor (passando per Extractor#page_words se
      # vertical/horizontal_strategy è :text). Ogni chiamata costa O(n) FFI
      # roundtrip per char — costoso su pagine con migliaia di char.
      cache_key = [loose, inject_spaces, lean]
      @chars_cache ||= {}
      return @chars_cache[cache_key] if @chars_cache.key?(cache_key)

      raw = compute_chars(loose: loose, lean: lean)
      result = inject_spaces ? rebuild_word_separators(raw) : raw
      @chars_cache[cache_key] = result
    end

    # Ricostruisce gli spazi che separano le parole basandosi sulla
    # GEOMETRIA dei char "veri", scartando completamente gli spazi
    # sintetici di PDFium (che sono inaffidabili: PDFium li emette in
    # modo aggressivo anche tra cifre di numeri come "2.895,26").
    #
    # Algoritmo:
    #   1. Filtra via tutti i char :generated (tipicamente spazi sintetici
    #      con bbox degenere).
    #   2. Cluster i char rimasti per riga (top tolerance 1pt).
    #   3. Dentro ogni riga, sort per x0 e per ogni coppia consecutiva
    #      calcola gap = next.x0 - prev.x1 e char_w = (prev.w + next.w) / 2.
    #      Se gap > 0.275 × char_w → inserisci spazio sintetico nuovo
    #      (bbox normalizzata al top/bottom dei char).
    #
    # Soglia 0.275: tarata empiricamente su PDF TeamSystem reale.
    # Distribuzione misurata: gap intra-parola max ratio 0.24, gap
    # inter-parola min ratio 0.31. Classificazione 100% corretta sul
    # dataset di training (1400 intra + 663 inter casi). Pdfminer.six
    # usa internamente 0.1 (`word_margin`) ma con info aggiuntive
    # dall'advance del font, non disponibile da PDFium.
    def rebuild_word_separators(chars)
      reals = chars.reject { |c| c[:generated] }
      return chars if reals.empty?

      # Cluster per riga, mantenendo l'ordine di top
      sorted_top = reals.sort_by { |c| c[:top] }
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
          if prev
            gap = c[:x0] - prev[:x1]

            # Segnale dal content stream PDF: prev.text_obj_ends_with_space.
            # Se prev NON termina un token (false), il gap è kerning interno
            # → mai inserire spazio.
            #
            # Se prev termina un token (true), può essere:
            #   - vera fine parola (gap geometrico relativamente grande)
            #   - fine token sintattico (es. tra cifre e punteggiatura di
            #     un numero "2", "."), con gap piccolo.
            #
            # Discrimino con la soglia geometrica abbinata al "contesto"
            # tipografico: se la coppia (prev_char, curr_char) sembra un
            # contesto numerico (cifre + punteggiatura), uso soglia più
            # alta; altrimenti soglia normale.
            obj_signal_present = prev.key?(:text_obj_ends_with_space)
            obj_says_continues = obj_signal_present && !prev[:text_obj_ends_with_space]

            unless obj_says_continues
              ref_w = best_reference_width(prev, c)
              threshold_ratio = numeric_context?(prev[:char], c[:char]) ? 0.7 : 0.3
              threshold = ref_w > 0 ? ref_w * threshold_ratio : 0.5
              result << build_synthetic_space(prev, c) if gap > threshold
            end
          end
          result << c
          prev = c
        end
      end
      result
    end

    # True se la coppia (prev_char, curr_char) è un contesto "numerico":
    # cifra-punteggiatura, punteggiatura-cifra, o cifra-cifra. In questi
    # casi un gap modesto è probabilmente kerning interno al numero, non
    # confine di parola. Soglia più alta per evitare di spezzare numeri
    # come "2.895,26" in "2 . 895 , 26".
    NUMERIC_PUNCT = %w[. , ].freeze

    def numeric_context?(prev_char, curr_char)
      return false if prev_char.nil? || curr_char.nil?

      prev_num = prev_char.match?(/\d/) || NUMERIC_PUNCT.include?(prev_char)
      curr_num = curr_char.match?(/\d/) || NUMERIC_PUNCT.include?(curr_char)
      prev_num && curr_num
    end

    # Ritorna la larghezza "di riferimento" per il calcolo del ratio
    # gap/width. Preferisce l'advance (più stabile di bbox per char con
    # kerning post-applied). Se uno dei due char non ha advance, fallback
    # su max delle bbox-width.
    def best_reference_width(a, b)
      a_adv = a[:advance]
      b_adv = b[:advance]
      if a_adv && b_adv
        [a_adv, b_adv].max
      else
        [(a[:x1] - a[:x0]), (b[:x1] - b[:x0])].max
      end
    end

    def build_synthetic_space(prev, c)
      {
        char: " ", codepoint: 32,
        x0: prev[:x1], x1: c[:x0],
        top: prev[:top], bottom: prev[:bottom],
        origin_x: prev[:x1], origin_y: prev[:origin_y],
        angle: 0.0, fontsize: prev[:fontsize], font: prev[:font],
        weight: prev[:weight], render_mode: nil,
        generated: true, hyphen: false, unicode_error: false,
        advance: nil, text_obj_id: nil, text_obj_ends_with_space: nil
      }
    end


    def compute_chars(loose:, lean: false)
      tp = text_page
      n = tp.char_count
      return [] if n.zero?

      # Geometria della pagina dopo l'applicazione della rotazione PDF.
      h = height
      w = width
      page_rotation = rotation

      raw_w, raw_h = case page_rotation
                     when 90, 270 then [h, w]
                     else [w, h]
                     end

      result = Array.new(n)

      # Buffer FFI riusati tra tutte le iterazioni del loop.
      # MemoryPointer.new è non-banale (~µs ciascuna), allocarne O(n) per
      # char è il principale costo di compute_chars dopo le chiamate FFI.
      l = FFI::MemoryPointer.new(:double)
      r = FFI::MemoryPointer.new(:double)
      b = FFI::MemoryPointer.new(:double)
      t = FFI::MemoryPointer.new(:double)
      ox = FFI::MemoryPointer.new(:double)
      oy = FFI::MemoryPointer.new(:double)
      rect = Raw::FS_RECTF.new
      font_buf = FFI::MemoryPointer.new(:uchar, 256) unless lean
      flags_buf = FFI::MemoryPointer.new(:int) unless lean
      fs_buf = FFI::MemoryPointer.new(:float)
      gw_buf = FFI::MemoryPointer.new(:float)
      matrix = Raw::FS_MATRIX.new
      text_obj_text_buf = FFI::MemoryPointer.new(:uint8, TEXT_OBJ_INITIAL_BUF_BYTES)

      text_obj_cache = {}
      tp_handle = tp.handle

      n.times do |i|
        x0, x1, y_top, y_bot = read_char_bbox(tp, i, loose, l, r, b, t, rect)
        Raw.FPDFText_GetCharOrigin(tp_handle, i, ox, oy)
        origin_x_raw = ox.read_double
        origin_y_raw = oy.read_double

        # Font name: skippato in lean (1 FFI risparmiata per char).
        font_name = nil
        unless lean
          n_bytes = Raw.FPDFText_GetFontInfo(tp_handle, i, font_buf, 256, flags_buf)
          font_name = font_buf.read_bytes(n_bytes - 1).force_encoding("UTF-8") if n_bytes > 1
        end

        cp = Raw.FPDFText_GetUnicode(tp_handle, i)

        text_obj = begin
          Raw.FPDFText_GetTextObject(tp_handle, i)
        rescue Rpdfium::LoadError
          nil
        end

        rm, font_handle, font_size_for_obj, ends_with_space =
          fetch_text_obj_info(text_obj, tp, text_obj_cache,
                              fs_buf: fs_buf, text_buf: text_obj_text_buf)

        # Advance: 2 FFI per char (GetGlyphWidth + GetMatrix). In lean
        # mode skippiamo — best_reference_width fa fallback su bbox-width
        # che funziona altrettanto bene per il discriminante word-boundary.
        advance = if lean
                    nil
                  else
                    compute_glyph_advance_fast(font_handle, cp, font_size_for_obj,
                                                tp_handle, i, gw_buf, matrix)
                  end

        td_x0, td_x1, td_top, td_bottom, td_ox, td_oy =
          apply_page_rotation_to_char(page_rotation, raw_w, raw_h,
                                       x0, x1, y_top, y_bot,
                                       origin_x_raw, origin_y_raw)

        # In lean mode skippiamo 5 chiamate FFI per char:
        # GetCharAngle, GetFontWeight, IsHyphen, HasUnicodeMapError,
        # (e GetFontSize fallback se font_size_for_obj è nil).
        # Su pagine con migliaia di char il risparmio è significativo
        # (decine di ms). I metadata risultano nil/false, che è il valore
        # neutro per il pipeline text/tables/words interno.
        result[i] =
          if lean
            {
              char:     safe_codepoint(cp),
              codepoint: cp,
              x0:       td_x0,
              x1:       td_x1,
              top:      td_top,
              bottom:   td_bottom,
              origin_x: td_ox,
              origin_y: td_oy,
              angle:    nil,
              fontsize: font_size_for_obj,
              font:     nil,
              weight:   nil,
              render_mode:   rm,
              generated:     Raw.FPDFText_IsGenerated(tp_handle, i) == 1,
              hyphen:        false,
              unicode_error: false,
              advance: advance,
              text_obj_id: text_obj && !text_obj.null? ? text_obj.address : nil,
              text_obj_ends_with_space: ends_with_space
            }
          else
            {
              char:     safe_codepoint(cp),
              codepoint: cp,
              x0:       td_x0,
              x1:       td_x1,
              top:      td_top,
              bottom:   td_bottom,
              origin_x: td_ox,
              origin_y: td_oy,
              angle:    Raw.FPDFText_GetCharAngle(tp_handle, i),
              fontsize: font_size_for_obj || Raw.FPDFText_GetFontSize(tp_handle, i),
              font:     font_name,
              weight:   Raw.FPDFText_GetFontWeight(tp_handle, i),
              render_mode:   rm,
              generated:     Raw.FPDFText_IsGenerated(tp_handle, i) == 1,
              hyphen:        Raw.FPDFText_IsHyphen(tp_handle, i) == 1,
              unicode_error: Raw.FPDFText_HasUnicodeMapError(tp_handle, i) == 1,
              advance: advance,
              text_obj_id: text_obj && !text_obj.null? ? text_obj.address : nil,
              text_obj_ends_with_space: ends_with_space
            }
          end
      end
      result
    end

    # Applica la rotazione della pagina alle coordinate di un char.
    #
    # Input: coord PDFium raw (bottom-up, pre-rotazione) di un bbox
    # `[x0, x1, y_top, y_bot]` (con y_top > y_bot perché bottom-up) e
    # di un origin point.
    #
    # Output: coord top-down nel sistema della pagina post-rotazione,
    # nella convenzione standard di rpdfium: `[x0, x1, top, bottom]`
    # con `top < bottom`. Coerente con pdfplumber.
    #
    # Convenzione PDFium: GetRotation = N significa che la pagina visualizzata
    # è ruotata di N*90° in senso orario rispetto al sistema raw del content
    # stream. PDFium restituisce le coord nel sistema raw; applichiamo la
    # rotazione per allineare al rendering.
    #
    # Caso 0°: identità + bottom-up→top-down.
    # Caso 90° CW: bbox larga in x diventa alta in y. La x_min (sinistra) raw
    #   coincide con il top (alto) del sistema post-rotazione.
    # Caso 180°: ribalta entrambi gli assi.
    # Caso 270° CW: bbox larga in x diventa alta in y, ma invertita verticalmente.
    def apply_page_rotation_to_char(rotation, raw_w, raw_h,
                                     x0, x1, y_top, y_bot,
                                     origin_x, origin_y)
      case rotation
      when 0, nil
        # Nessuna rotazione. Bottom-up → top-down standard.
        # page_h_post == raw_h.
        [x0, x1, raw_h - y_top, raw_h - y_bot,
         origin_x, raw_h - origin_y]

      when 90
        # 90° CW. Dimensioni post-rotation: w=raw_h, h=raw_w.
        # Trasformazione: x_post = y_raw, y_post = raw_w - x_raw (bottom-up).
        # In top-down: top = x_min_raw, bottom = x_max_raw.
        new_x0 = y_bot   # piccolo y_raw → piccolo x_post
        new_x1 = y_top   # grande y_raw → grande x_post
        new_top    = x0  # piccolo x_raw → top piccolo (alto)
        new_bottom = x1  # grande x_raw → bottom grande (basso)
        new_ox = origin_y
        new_oy = origin_x       # top-down origin_y = x_raw
        [new_x0, new_x1, new_top, new_bottom, new_ox, new_oy]

      when 180
        # 180°. Dimensioni post-rotation: invariate (raw_w × raw_h).
        # Trasformazione: x_post = raw_w - x_raw, y_post = raw_h - y_raw.
        # In top-down: top = y_bot_raw, bottom = y_top_raw.
        new_x0 = raw_w - x1
        new_x1 = raw_w - x0
        new_top    = y_bot   # bottom raw → top td (alto)
        new_bottom = y_top   # top raw → bottom td (basso)
        new_ox = raw_w - origin_x
        new_oy = y_top.zero? ? raw_h - origin_y : raw_h - origin_y
        # nota: origin in top-down post-180 = y_origin_raw
        new_oy = origin_y
        [new_x0, new_x1, new_top, new_bottom, new_ox, new_oy]

      when 270
        # 270° CW (= 90° CCW). Dimensioni post-rotation: w=raw_h, h=raw_w.
        # Trasformazione: x_post = raw_h - y_raw, y_post = x_raw (bottom-up).
        # In top-down: top = raw_w - x_max_raw, bottom = raw_w - x_min_raw.
        new_x0 = raw_h - y_top  # grande y → piccolo x_post
        new_x1 = raw_h - y_bot
        new_top    = raw_w - x1
        new_bottom = raw_w - x0
        new_ox = raw_h - origin_y
        new_oy = raw_w - origin_x
        [new_x0, new_x1, new_top, new_bottom, new_ox, new_oy]

      else
        # Rotazione non standard (non multipla di 90°): fallback al
        # comportamento pre-rotazione. Non dovrebbe mai succedere per
        # PDF ben formati.
        [x0, x1, raw_h - y_top, raw_h - y_bot,
         origin_x, raw_h - origin_y]
      end
    end

    # Cache lookup per text object. Restituisce tupla:
    #   [render_mode, font_handle, font_size, ends_with_space]
    #
    # `ends_with_space` indica se il testo dell'intero text object termina
    # con uno spazio (segnale "fine token" dichiarato dal PDF). È una
    # proprietà dell'oggetto, non del singolo char, quindi può essere
    # calcolata una volta sola e cachata insieme agli altri campi — evita
    # una chiamata FPDFTextObj_GetText per ogni char che condivide l'obj.
    def fetch_text_obj_info(text_obj, tp, cache, fs_buf:, text_buf:)
      return [nil, nil, nil, nil] if text_obj.nil? || text_obj.null?

      addr = text_obj.address
      return cache[addr] if cache.key?(addr)

      rm = Raw.FPDFTextObj_GetTextRenderMode(text_obj)
      font = Raw.FPDFTextObj_GetFont(text_obj)
      font_handle = font.null? ? nil : font

      font_size = if Raw.FPDFTextObj_GetFontSize(text_obj, fs_buf) == 1
                    fs_buf.read_float
                  end

      obj_text = read_text_obj_text_fast(text_obj, tp, text_buf)
      ends_with_space = obj_text&.end_with?(" ")

      tuple = [rm, font_handle, font_size, ends_with_space]
      cache[addr] = tuple
      tuple
    end

    # Versione "fast" di read_text_obj_text_from: riusa il buffer passato
    # invece di allocarlo. Per il 99% dei text obj il buffer iniziale da
    # 256 byte basta; nel caso raro che PDFium richieda più spazio, alloca
    # un buffer più grande on-demand (questa è una path rara, OK
    # allocare).
    def read_text_obj_text_fast(text_obj, tp, buf)
      return nil if text_obj.nil? || text_obj.null?

      needed = Raw.FPDFTextObj_GetText(text_obj, tp.handle, buf,
                                        TEXT_OBJ_INITIAL_BUF_BYTES)
      return nil if needed < 2

      if needed > TEXT_OBJ_INITIAL_BUF_BYTES
        # Path raro: text obj con > 128 char. Alloco buffer dedicato.
        big_buf = FFI::MemoryPointer.new(:uint8, needed)
        needed = Raw.FPDFTextObj_GetText(text_obj, tp.handle, big_buf, needed)
        return nil if needed < 2

        payload_bytes = needed - 2
        return nil if payload_bytes <= 0

        return big_buf.read_bytes(payload_bytes)
                      .force_encoding("UTF-16LE")
                      .encode("UTF-8")
                      .delete("\u0000")
      end

      payload_bytes = needed - 2
      return nil if payload_bytes <= 0

      buf.read_bytes(payload_bytes)
         .force_encoding("UTF-16LE")
         .encode("UTF-8")
         .delete("\u0000")
    end

    # Versione "fast" di compute_glyph_advance: riusa gw_buf e matrix
    # invece di allocarli per char. Stesso comportamento funzionale.
    def compute_glyph_advance_fast(font, codepoint, font_size, tp_handle,
                                    char_index, gw_buf, matrix)
      return nil if font.nil? || font_size.nil?

      ok = begin
        Raw.FPDFFont_GetGlyphWidth(font, codepoint, font_size, gw_buf)
      rescue Rpdfium::LoadError
        return nil
      end
      return nil if ok == 0

      glyph_w_font_units = gw_buf.read_float

      # CTM scale: riuso la matrix in-place.
      scale = if Raw.FPDFText_GetMatrix(tp_handle, char_index, matrix) == 1
                matrix[:a].abs
              else
                1.0
              end
      glyph_w_font_units * scale
    end

    # Buffer size iniziale per FPDFTextObj_GetText: 256 byte = 128 char UTF-16.
    # Empiricamente sufficiente per ~99% dei text object reali (parole singole
    # o frasi brevi). Quando un text obj è più grande, ricadiamo nel probe-then-
    # fetch corretto.
    TEXT_OBJ_INITIAL_BUF_BYTES = 256

    # Legge il testo di un text object PDF.
    #
    # Firma C: `unsigned long FPDFTextObj_GetText(FPDF_PAGEOBJECT, FPDF_TEXTPAGE,
    # FPDF_WCHAR* buffer, unsigned long length)` — length in BYTE, return è
    # il numero di byte totali necessari (incluso null terminator), anche se
    # il buffer è troppo piccolo. Pattern: prova con buffer stack-friendly,
    # se PDFium ne richiede di più rialloca.
    def read_text_obj_text_from(text_obj, tp, _char_index_unused = nil)
      return nil if text_obj.nil? || text_obj.null?

      # Prima tentativo: buffer fisso da 256 byte. Risolve il 99% dei casi.
      buf = FFI::MemoryPointer.new(:uint8, TEXT_OBJ_INITIAL_BUF_BYTES)
      needed = Raw.FPDFTextObj_GetText(text_obj, tp.handle, buf,
                                        TEXT_OBJ_INITIAL_BUF_BYTES)
      return nil if needed < 2

      # Se PDFium ne vuole più di quanto allocato, rialloca esatto.
      if needed > TEXT_OBJ_INITIAL_BUF_BYTES
        buf = FFI::MemoryPointer.new(:uint8, needed)
        needed = Raw.FPDFTextObj_GetText(text_obj, tp.handle, buf, needed)
        return nil if needed < 2
      end

      # Clamp difensivo: non leggo mai più di quanto allocato.
      buf_capacity = buf.size
      payload_bytes = [needed - 2, buf_capacity - 2].min
      return nil if payload_bytes <= 0

      buf.read_bytes(payload_bytes)
         .force_encoding("UTF-16LE")
         .encode("UTF-8")
         .delete("\u0000")
    end

    # Calcola l'advance del glifo in coordinate pagina, per un char
    # specifico identificato da (text_page, char_index).
    # Formula: glyph_width(font, codepoint, font_size) × |CTM.a|.
    # Ritorna nil se l'advance non è calcolabile (font non disponibile,
    # PDFium che non supporta l'API).
    def compute_glyph_advance(font, codepoint, font_size, tp, char_index)
      return nil if font.nil? || font_size.nil?

      gw_buf = FFI::MemoryPointer.new(:float)
      ok = begin
        Raw.FPDFFont_GetGlyphWidth(font, codepoint, font_size, gw_buf)
      rescue Rpdfium::LoadError
        return nil  # FPDFFont_GetGlyphWidth non disponibile in build vecchi
      end
      return nil if ok == 0

      glyph_w_font_units = gw_buf.read_float
      scale = char_ctm_scale_x(tp, char_index) || 1.0
      glyph_w_font_units * scale
    end

    # Calcola la scala orizzontale del CTM per un char specifico.
    def char_ctm_scale_x(tp, char_index)
      mat = Raw::FS_MATRIX.new
      return nil if Raw.FPDFText_GetMatrix(tp.handle, char_index, mat) == 0

      mat[:a].abs
    end

    # ===== Form-aware extraction =====
    #
    # PDF di "moduli compilati" (F24, Comunicazione IVA, 770, ecc.) sono PDF
    # di output dove il modello prestampato e i valori inseriti coesistono
    # come testo grafico — nessun AcroForm, nessun tag PDF/UA. Il pipeline
    # geometrico di estrazione tabelle vede il modulo intero e produce
    # rumore (etichette del template mescolate ai dati).
    #
    # La strategia robusta su questi PDF è separare i char per "ruolo"
    # usando font/altezza, che tipicamente differiscono tra il template
    # (font proporzionali, dimensioni varie) e i dati inseriti dal
    # gestionale (un singolo font, tipicamente Courier o Helvetica,
    # una sola size).
    #
    # Esempio classico F24:
    #   Template: Futura-Light, Futura-Bold, Futura-Heavy, Times-Bold
    #   Dati:     Courier 10.0
    #
    #   page.font_inventory          # → vede tutti i (font, height)
    #   page.chars_where(font: /Courier/i)
    #     # → solo i char dei dati inseriti
    #   page.lines(font: /Courier/i) # → testo dei dati riga per riga

    # Distribuzione dei char per (font, altezza visiva, weight).
    #
    # Ritorna un Array di Hash ordinato per count decrescente:
    #   [{ font:, height:, weight:, count:, sample: }, ...]
    #
    # `height` è l'altezza visiva del char in punti (bottom - top), più
    # affidabile di `fontsize` che PDFium normalizza a 1.0 quando la
    # dimensione reale è nella matrice CTM (caso comune sui moduli
    # generati con scaling).
    #
    # `sample` sono i primi 40 char di quel gruppo, per ispezione.
    #
    # Usalo per scegliere il filtro `chars_where`: tipicamente il font
    # con più char è il template, e i font minoritari (1 solo size,
    # spesso monospace) sono i dati.
    def font_inventory
      groups = chars.reject { |c| c[:generated] }.group_by do |c|
        h = (c[:bottom] - c[:top]).round(1)
        [c[:font], h, c[:weight]]
      end
      groups.map do |(font, height, weight), cs|
        {
          font: font,
          height: height,
          weight: weight,
          count: cs.size,
          sample: cs.first(40).map { |c| c[:char] }.join
        }
      end.sort_by { |g| -g[:count] }
    end

    # Filtro char generico. Ritorna i char che matchano TUTTI i predicati
    # specificati (intersezione, non unione).
    #
    # Argomenti supportati:
    #   font:   String esatto, Array<String>, o Regexp
    #   height: Float (singolo valore), Range, Array<Float>
    #   weight: Integer o Range
    #   bbox:   [left, top, right, bottom] in coord top-down della pagina
    #   where:  block che riceve l'hash char, deve ritornare truthy
    #
    # Tutti i parametri sono opzionali; quelli passati vengono combinati
    # in AND.
    #
    # Tipicamente combinato con WordExtractor per estrarre testo "pulito":
    #
    #   data_chars = page.chars_where(font: /Courier/i)
    #   words = Rpdfium::Util::WordExtractor.new.extract_words(data_chars)
    #
    # oppure usato come building block per pipeline custom.
    def chars_where(font: nil, height: nil, weight: nil, bbox: nil, where: nil, **char_opts)
      cs = chars(**char_opts)

      cs.select do |c|
        next false if font && !font_matches?(c[:font], font)
        next false if height && !range_matches?((c[:bottom] - c[:top]), height)
        next false if weight && !range_matches?(c[:weight], weight)
        if bbox
          left, top, right, bottom = bbox
          hm = (c[:x0] + c[:x1]) / 2.0
          vm = (c[:top] + c[:bottom]) / 2.0
          next false unless hm >= left && hm < right && vm >= top && vm < bottom
        end
        next false if where && !where.call(c)
        true
      end
    end

    # Raggruppa i char filtrati in righe logiche e ritorna un Array di
    # stringhe (una per riga, top-to-bottom, char dentro la riga
    # left-to-right). Conveniente quando il PDF è un modulo compilato
    # e vuoi solo i valori inseriti come righe pulite.
    #
    # Esempio F24:
    #
    #   page.lines(font: /Courier/i)
    #   # => ["Soggetto:  Azienda  S.R.L.  ( 01234567890 )",
    #   #     "0  1  2  3  4  5  6  7  8  9  0",
    #   #     "Azienda  S.R.L.",
    #   #     "CITTA  XX  VIA  ESEMPIO
    #   #     "1001  11  2021  499,81  0,00",
    #   #     "1712  12  2021  32,46  0,00",
    #   #     "1701  11  2021  0,00  295,89",
    #   #     "532,27  295,89  236,38",
    #   #     ...]
    #
    # I parametri di filtro sono gli stessi di `chars_where`. I parametri
    # `x_tolerance` e `y_tolerance` controllano il WordExtractor.
    #
    # Il separatore inter-word è due spazi (per leggibilità su moduli con
    # campi spaziati); cambialo con `separator:`.
    def lines(x_tolerance: 3.0, y_tolerance: 3.0, separator: "  ",
              font: nil, height: nil, weight: nil, bbox: nil, where: nil,
              **char_opts)
      cs = chars_where(font: font, height: height, weight: weight,
                       bbox: bbox, where: where, **char_opts)
      return [] if cs.empty?

      we = Util::WordExtractor.new(x_tolerance: x_tolerance,
                                    y_tolerance: y_tolerance)
      words = we.extract_words(cs)
      return [] if words.empty?

      # Cluster per top (con tolleranza), poi ordina per x0 dentro la riga
      rows = Util::Cluster.cluster_objects(words, :top, tolerance: y_tolerance)
      rows.map do |row_words|
        row_words.sort_by { |w| w[:x0] }.map { |w| w[:text] }.join(separator)
      end
    end

    # Associa label semantiche del template ai valori inseriti sulla pagina.
    # Per moduli compilati (F24, Comunicazione IVA, 770, ecc.) dove il
    # template e i dati sono entrambi testo statico ma in font diversi.
    #
    # @param data_font [String, Regexp, Array] font del layer "dati" inseriti.
    #   Tipicamente Courier (F24, 770) o Helvetica (Comunicazione IVA).
    #   Vedi `Page#font_inventory` per identificarlo.
    # @param template_font [String, Regexp, Array, nil] font del layer
    #   "template". Se nil, usa tutti i char che NON sono in `data_font`.
    # @param data_filter [Proc, nil] filtro aggiuntivo opzionale sul testo
    #   dei valori (es. `->(t) { t.match?(/^[\d.,]+$/) }` per soli numeri).
    # @param merge_adjacent [Boolean, Symbol] strategia di unione word
    #   adiacenti sulla stessa riga:
    #   - false (default): no merge
    #   - true o :by_label: fonde SOLO word con stessa label col (conserva
    #     i checkbox sotto label distinte). Usa per moduli con flag/checkbox
    #     come 770 quadri compilati ST/SV/SX.
    #   - :by_proximity: fonde tutte le word adiacenti indipendentemente
    #     dalla label. Usa per header con testo libero (es. "Soggetto:
    #     AAA BBB CCC ( 12345 )" come single value).
    #   - :smart: combina i due — by_label per word con label, by_proximity
    #     per word orfane senza label. Raccomandato per moduli complessi
    #     come 770 che mescolano header testuali e tabelle con flag.
    # @param merge_x_gap [Float] gap massimo in punti tra word adiacenti per
    #   essere unite (default 20.0).
    # @param as_hash [Boolean] se true ritorna `{ "label" => value, ... }`
    #   invece di Array<Hash>. La label è scelta tra `col` e `row`
    #   preferendo quella esplicita: row se la label `col` è già di colonna
    #   ovvia, altrimenti col. In caso di label duplicate, le entries
    #   vengono raggruppate in Array. Default false.
    # @param matcher [LabelMatcher, nil] istanza preconfigurata. Se nil,
    #   ne crea una con i default.
    # @param x_tolerance, y_tolerance [Float] tolleranze per il word extractor.
    #
    # @return [Array<Hash>, Hash] per default Array<Hash>:
    #   ```
    #   { value: "499,81",
    #     labels: { col: "importi a debito versati", row: "TOTALE A" },
    #     geometry: { x0:, x1:, top:, bottom: } }
    #   ```
    #   Con `as_hash: true` ritorna `{ "label" => value }` o
    #   `{ "label" => [value, value, ...] }` se duplicate.
    def label_value_pairs(data_font:, template_font: nil,
                          data_filter: nil, matcher: nil,
                          merge_adjacent: false, merge_x_gap: 20.0,
                          as_hash: false,
                          x_tolerance: 3.0, y_tolerance: 3.0)
      data_chars = chars_where(font: data_font)
      anchor_chars =
        if template_font
          chars_where(font: template_font)
        else
          # Default: tutto ciò che NON è data_font
          chars.reject { |c| c[:generated] }.reject do |c|
            send(:font_matches?, c[:font], data_font)
          end
        end

      we = Util::WordExtractor.new(x_tolerance: x_tolerance, y_tolerance: y_tolerance)
      data_words = we.extract_words(data_chars)
      data_words = data_words.select { |w| data_filter.call(w[:text]) } if data_filter
      anchor_words = we.extract_words(anchor_chars)

      m = matcher || Util::LabelMatcher.new

      case merge_adjacent
      when true, :by_label
        prelim = m.match(data_words, anchor_words)
        data_words = merge_adjacent_words_by_label(data_words, prelim,
                                                    x_gap: merge_x_gap,
                                                    y_tol: y_tolerance)
      when :by_proximity, :aggressive
        data_words = merge_adjacent_words(data_words, x_gap: merge_x_gap,
                                                      y_tol: y_tolerance)
      when :smart
        # 1° pass by_label: protegge i checkbox e word con label distinte
        prelim = m.match(data_words, anchor_words)
        data_words = merge_adjacent_words_by_label(data_words, prelim,
                                                    x_gap: merge_x_gap,
                                                    y_tol: y_tolerance)
        # 2° pass: re-match e fonde solo word ORFANE (no col label) adiacenti
        prelim2 = m.match(data_words, anchor_words)
        data_words = merge_adjacent_unlabeled(data_words, prelim2,
                                               x_gap: merge_x_gap,
                                               y_tol: y_tolerance)
      end

      pairs = m.match(data_words, anchor_words)

      as_hash ? pairs_to_hash(pairs) : pairs
    end

    private

    # Unisce word adiacenti SOLO se hanno la stessa label col (o entrambe
    # senza label). Evita di fondere checkbox sotto label distinte.
    def merge_adjacent_words_by_label(words, prelim_pairs, x_gap:, y_tol:)
      return [] if words.empty?

      # Word indicizzata per text+geometria → label col (può essere nil)
      label_of = {}
      prelim_pairs.each do |p|
        key = [p[:value], p[:geometry][:x0].round(1), p[:geometry][:top].round(1)]
        label_of[key] = p[:labels][:col]
      end
      get_label = lambda do |w|
        label_of[[w[:text], w[:x0].round(1), w[:top].round(1)]]
      end

      sorted = words.sort_by { |w| [w[:top].round(1), w[:x0]] }
      groups = []
      current = [sorted.first]
      sorted.drop(1).each do |w|
        prev = current.last
        on_same_row = (w[:top] - prev[:top]).abs <= y_tol
        adjacent = w[:x0] - prev[:x1] <= x_gap && w[:x0] >= prev[:x0]
        same_label = get_label.call(w) == get_label.call(prev)
        if on_same_row && adjacent && same_label
          current << w
        else
          groups << current
          current = [w]
        end
      end
      groups << current

      groups.map { |g| merge_word_group(g) }
    end

    def merge_word_group(group)
      return group.first if group.size == 1

      {
        text: group.map { |w| w[:text] }.join(" "),
        x0: group.map { |w| w[:x0] }.min,
        x1: group.map { |w| w[:x1] }.max,
        top: group.map { |w| w[:top] }.min,
        bottom: group.map { |w| w[:bottom] }.max
      }
    end

    # Fonde solo le word che non hanno una col label (orfane), lasciando
    # intatte quelle con label distinte. Per la strategia :smart.
    def merge_adjacent_unlabeled(words, prelim_pairs, x_gap:, y_tol:)
      return [] if words.empty?

      label_of = {}
      prelim_pairs.each do |p|
        key = [p[:value], p[:geometry][:x0].round(1), p[:geometry][:top].round(1)]
        label_of[key] = p[:labels][:col]
      end
      unlabeled = lambda do |w|
        label_of[[w[:text], w[:x0].round(1), w[:top].round(1)]].nil?
      end

      sorted = words.sort_by { |w| [w[:top].round(1), w[:x0]] }
      groups = []
      current = [sorted.first]
      sorted.drop(1).each do |w|
        prev = current.last
        on_same_row = (w[:top] - prev[:top]).abs <= y_tol
        adjacent = w[:x0] - prev[:x1] <= x_gap && w[:x0] >= prev[:x0]
        both_unlabeled = unlabeled.call(prev) && unlabeled.call(w)
        if on_same_row && adjacent && both_unlabeled
          current << w
        else
          groups << current
          current = [w]
        end
      end
      groups << current

      groups.map { |g| merge_word_group(g) }
    end

    # (legacy, unused after the label-aware merge; kept for reference)
    def merge_adjacent_words(words, x_gap:, y_tol:)
      return [] if words.empty?

      sorted = words.sort_by { |w| [w[:top].round(1), w[:x0]] }
      groups = []
      current = [sorted.first]
      sorted.drop(1).each do |w|
        prev = current.last
        on_same_row = (w[:top] - prev[:top]).abs <= y_tol
        adjacent = w[:x0] - prev[:x1] <= x_gap && w[:x0] >= prev[:x0]
        if on_same_row && adjacent
          current << w
        else
          groups << current
          current = [w]
        end
      end
      groups << current

      groups.map { |g| merge_word_group(g) }
    end

    # Converte pairs (Array<Hash>) in Hash { label => value } scegliendo
    # automaticamente la label più informativa tra col e row.
    # Le entry senza label confluiscono sotto la chiave "_unlabeled".
    def pairs_to_hash(pairs)
      result = {}
      unlabeled = []
      pairs.each do |p|
        label = best_label_for(p[:labels])
        if label.nil? || label.empty?
          unlabeled << p[:value]
          next
        end

        if result.key?(label)
          existing = result[label]
          result[label] = existing.is_a?(Array) ? existing + [p[:value]] : [existing, p[:value]]
        else
          result[label] = p[:value]
        end
      end
      result["_unlabeled"] = unlabeled if unlabeled.any?
      result
    end

    # Heuristica per scegliere la label "principale" tra col e row.
    # - Se entrambe presenti: preferisce row se la row è breve (è un
    #   identificatore univoco di riga), altrimenti col.
    # - Se una sola presente, la usa.
    def best_label_for(labels)
      col = labels[:col]
      row = labels[:row]
      return row if col.nil? && row
      return col if row.nil? && col
      return nil if col.nil? && row.nil?

      # Entrambe presenti: preferisci la più informativa.
      # Heuristica: row di solito è una label breve identificatrice
      # (es. "Codice fiscale", "Codice attività", "ST", "Dipendente").
      # col tipicamente è più lunga e descrittiva.
      # In caso di ambiguità preferisco quella che NON è già contenuta
      # nell'altra (sotto-stringa).
      return row if col.include?(row) || row.length > col.length / 2
      col
    end

    public

    # ===== Words =====


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
    # `include_curves` true: include i Bezier come segmenti (con flag :curve).
    # `include_dashed` true: include le linee tratteggiate (con flag :dashed).
    #   Default: false. Le tratteggiate spesso sono "guide" non-visive nei
    #   template di stampa e confondono la detection cellule tabella. Chi
    #   le vuole esplicitamente (es. drawing extraction completo) passa true.
    def line_segments(include_curves: false, include_dashed: false)
      # Cache per parametri: line_segments viene tipicamente chiamato 2 volte
      # per pagina (da horizontal_lines E da vertical_lines), e itera tutti
      # i path objects della pagina via FFI — costoso su PDF con grafica
      # ricca (es. CR Banca d'Italia: ~500-1000 path obj per pagina).
      cache_key = [include_curves, include_dashed]
      @line_segments_cache ||= {}
      return @line_segments_cache[cache_key] if @line_segments_cache.key?(cache_key)

      out = []
      page_rotation = rotation
      raw_w, raw_h = case page_rotation
                     when 90, 270 then [height, width]
                     else [width, height]
                     end
      ctx = { rotation: page_rotation, raw_w: raw_w, raw_h: raw_h }
      collect_line_segments(@state[:handle], identity_matrix, ctx,
                             include_curves, out, page_object: false)
      result = include_dashed ? out : out.reject { |s| s[:dashed] }
      @line_segments_cache[cache_key] = result
    end

    private

    def read_char_bbox(tp, i, loose, l, r, b, t, rect)
      if loose
        if Raw.FPDFText_GetLooseCharBox(tp.handle, i, rect) == 1
          [rect[:left], rect[:right], rect[:top], rect[:bottom]]
        else
          [0.0, 0.0, 0.0, 0.0]
        end
      else
        Raw.FPDFText_GetCharBox(tp.handle, i, l, r, b, t)
        [l.read_double, r.read_double, t.read_double, b.read_double]
      end
    end

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
    def collect_line_segments(parent, ctm, rotation_ctx, include_curves, out, page_object:)
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
          extract_path_segments(obj, ctm, rotation_ctx, include_curves, out)
        when Raw::PAGEOBJ_FORM
          # Discendi nel form xobject componendo la sua matrice col CTM
          child_ctm = compose_matrix(ctm, read_object_matrix(obj))
          collect_line_segments(obj, child_ctm, rotation_ctx, include_curves, out,
                                page_object: true)
        end
      end
    end

    def extract_path_segments(obj, ctm, rotation_ctx, include_curves, out)
      return unless object_active?(obj)

      stroke_width = read_stroke_width(obj)
      dash_count = read_dash_count(obj)
      dashed = dash_count > 0

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
          out << build_segment(current[0], current[1], x, y, rotation_ctx,
                                stroke_width, dashed: dashed) if current
          current = [x, y]
        when Raw::SEGMENT_BEZIERTO
          if include_curves && current
            out << build_segment(current[0], current[1], x, y, rotation_ctx,
                                  stroke_width, dashed: dashed)
                    .merge(curve: true)
          end
          current = [x, y]
        end

        if closes && current && first_in_subpath
          out << build_segment(current[0], current[1],
                                first_in_subpath[0], first_in_subpath[1],
                                rotation_ctx, stroke_width, dashed: dashed)
          current = first_in_subpath.dup
        end
      end
    end

    # FPDFPageObj_GetIsActive: ritorna true se il page object è marcato
    # attivo (visibile). Su PDF senza Optional Content, è always-true; su
    # PDF con layer disabilitati, alcuni obj possono essere inactive.
    # Fallback: se la binding non c'è o fallisce, consideriamo attivo
    # (comportamento equivalente alla versione pre-0.3.6).
    def object_active?(obj)
      active_buf = FFI::MemoryPointer.new(:int)
      return true if Raw.FPDFPageObj_GetIsActive(obj, active_buf) == 0

      active_buf.read_int != 0
    rescue Rpdfium::LoadError
      true
    end

    # FPDFPageObj_GetDashCount: numero di elementi del dash array. 0 =
    # linea continua, > 0 = linea tratteggiata (con N elementi
    # alternati on/off).
    def read_dash_count(obj)
      Raw.FPDFPageObj_GetDashCount(obj)
    rescue Rpdfium::LoadError
      0
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

    # ===== Marked Content (PDF tagged) =====

    # Itera tutti i marked content del page (operatori BDC/BMC del content
    # stream PDF) raggruppando i page object per il loro mcid (Marked
    # Content ID). Utile per PDF "tagged" (PDF/UA, esport da Word/InDesign):
    # un mcid ≥ 0 identifica un'unità semantica (paragrafo, span, figura),
    # e tutti gli oggetti con lo stesso mcid appartengono allo stesso
    # tag struttura.
    #
    # Ritorna un Hash { mcid (Integer) => Array<page_object_handle> }.
    # mcid -1 (i page object senza marked content) viene OMESSO.
    #
    # Su PDF non tagged (es. la maggior parte dei PDF da gestionali
    # italiani) l'Hash è vuoto. Su PDF tagged è la fonte di verità per
    # raggruppare semanticamente char/parole — più affidabile di qualsiasi
    # euristica geometrica.
    def marked_content_regions
      out = Hash.new { |h, k| h[k] = [] }
      walk_page_objects do |obj, _ctm|
        mcid = read_marked_content_id(obj)
        out[mcid] << obj if mcid >= 0
      end
      out
    end

    # Itera tutti i marks (BMC/BDC operators) con i loro nomi e parametri.
    # Ritorna Array<Hash> con { obj_handle, mark_name, params }.
    # Per PDF tagged, i mark_name comuni sono: "P" (paragraph),
    # "Span", "Artifact", "Figure", "TR" (table row), "TD" (table cell).
    def marked_content_inventory
      out = []
      walk_page_objects do |obj, _ctm|
        mark_count = safely_count_marks(obj)
        mark_count.times do |mi|
          mark = Raw.FPDFPageObj_GetMark(obj, mi)
          next if mark.null?

          out << {
            obj: obj,
            mark_name: read_mark_name(mark),
            params: read_mark_params(mark)
          }
        end
      end
      out
    end

    # ===== Links (annotation links + hit-test posizionale) =====

    # Hit-test: ritorna il link annotation che contiene il punto (x, y)
    # in coordinate top-down della pagina. Restituisce un'istanza di
    # Annotation o nil.
    #
    # Più efficiente di iterare `links` quando si parte da una coordinata
    # (es. mapping click sul rendering → URL del link). Pdfplumber non
    # ha equivalente diretto.
    def link_at(x, y)
      # PDFium usa coord bottom-up; converto
      pdf_y = height - y
      link_handle = Raw.FPDFLink_GetLinkAtPoint(@state[:handle],
                                                 x.to_f, pdf_y.to_f)
      return nil if link_handle.null?

      annot_handle = Raw.FPDFLink_GetAnnot(@state[:handle], link_handle)
      return nil if annot_handle.null?

      # Annotation richiede un index nel page; non lo abbiamo direttamente
      # qui. Iteriamo le annotation della pagina e troviamo quella col
      # rect più vicino. Per la maggior parte dei PDF è O(piccolo).
      annotations.find { |a| a.subtype == :link && annotation_contains?(a, x, y) }
    end



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

    # ===== Struct Tree (PDF tagged) =====

    # Struct tree della pagina (PDF/UA / Tagged PDF). Ritorna nil se la
    # pagina non è tagged. Per PDF da Word/LibreOffice/InDesign export
    # con accessibility tags attivati, espone la struttura logica
    # (Document → P, H1, Table, TR, TH, TD, Figure, ecc.).
    #
    # Modalità d'uso:
    #
    #   # Lifecycle automatico (RAII via finalizer):
    #   tree = page.struct_tree
    #   tree&.walk { |el| puts el.type }
    #
    #   # Lifecycle deterministico (close al fine blocco):
    #   page.struct_tree do |tree|
    #     tree.tables.each { |t| ... }
    #   end
    #
    # Su PDF non tagged ritorna nil. Su PDF "tagged ma vuoto" (es. CR
    # Banca d'Italia, StructTreeRoot presente ma con element placeholder),
    # ritorna un Tree con `Tree#empty? == true`.
    def struct_tree
      tree = Structure::Tree.for_page(self)
      if block_given?
        begin
          yield tree
        ensure
          tree&.close
        end
      else
        tree
      end
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

    # Match helper per il parametro `font:` di chars_where/lines.
    def font_matches?(actual_font, pattern)
      return false if actual_font.nil?

      case pattern
      when String  then actual_font == pattern
      when Regexp  then actual_font.match?(pattern)
      when Array   then pattern.any? { |p| font_matches?(actual_font, p) }
      else false
      end
    end

    # Match helper per parametri numerici (`height:`, `weight:`).
    # Accetta singolo valore, Range, o Array<Numeric>. Per singolo valore
    # numeric usa tolleranza 0.05 (utile per height in punti).
    def range_matches?(actual, spec)
      return false if actual.nil?

      case spec
      when Range    then spec.cover?(actual)
      when Array    then spec.any? { |s| range_matches?(actual, s) }
      when Numeric  then (actual - spec).abs < 0.1
      else false
      end
    end

    # Converte un box PDFium {left, bottom, right, top} in coord bottom-up
    # alla tuple top-down [x0, top, x1, bottom] usata dal resto della
    # libreria. Ritorna nil se il box è nil (box assente sul PDF).
    # Itera tutti i page object della pagina ricorsivamente (discendendo
    # nei Form XObjects), passando al block ogni (obj, ctm_corrente).
    # Stessa logica di walk di collect_line_segments ma astratta — utile
    # per altre operazioni a livello di obj (marked content, etc).
    def walk_page_objects(handle = @state[:handle], ctm = identity_matrix,
                          is_form: false, &block)
      n = is_form ? Raw.FPDFFormObj_CountObjects(handle) : Raw.FPDFPage_CountObjects(handle)
      n.times do |i|
        obj = is_form ? Raw.FPDFFormObj_GetObject(handle, i) : Raw.FPDFPage_GetObject(handle, i)
        next if obj.null?

        block.call(obj, ctm)

        if Raw.FPDFPageObj_GetType(obj) == Raw::PAGEOBJ_FORM
          child_ctm = compose_matrix(ctm, read_object_matrix(obj))
          walk_page_objects(obj, child_ctm, is_form: true, &block)
        end
      end
    end

    def read_marked_content_id(obj)
      Raw.FPDFPageObj_GetMarkedContentID(obj)
    rescue Rpdfium::LoadError
      -1
    end

    def safely_count_marks(obj)
      Raw.FPDFPageObj_CountMarks(obj)
    rescue Rpdfium::LoadError
      0
    end

    def read_mark_name(mark)
      out_len = FFI::MemoryPointer.new(:ulong)
      buf_bytes = 256
      name_buf = FFI::MemoryPointer.new(:uint8, buf_bytes)
      return nil if Raw.FPDFPageObjMark_GetName(mark, name_buf, buf_bytes,
                                                  out_len) == 0

      needed = out_len.read_ulong
      return nil if needed < 2

      # Clamp: se needed eccede il buffer, leggo solo quanto allocato (e
      # mi pace che la stringa sia troncata: il caso è patologico). Senza
      # clamp → IndexError su mark name eccezionalmente lunghi.
      payload_bytes = [needed - 2, buf_bytes - 2].min
      return nil if payload_bytes <= 0

      name_buf.read_bytes(payload_bytes)
              .force_encoding("UTF-16LE")
              .encode("UTF-8")
              .delete("\u0000")
    end

    def read_mark_params(mark)
      params = {}
      count = Raw.FPDFPageObjMark_CountParams(mark)
      count.times do |pi|
        key = read_mark_param_key(mark, pi)
        next if key.nil? || key.empty?

        # Tipo del valore: 0=Null, 1=Int, 2=String, 3=Blob, 4=Dict (ignorato)
        type = Raw.FPDFPageObjMark_GetParamValueType(mark, key)
        params[key] = case type
                       when 1 then read_mark_param_int(mark, key)
                       when 2, 3 then read_mark_param_string(mark, key)
                       end
      end
      params
    end

    def read_mark_param_key(mark, index)
      out_len = FFI::MemoryPointer.new(:ulong)
      buf_bytes = 128
      key_buf = FFI::MemoryPointer.new(:uint8, buf_bytes)
      return nil if Raw.FPDFPageObjMark_GetParamKey(mark, index,
                                                      key_buf, buf_bytes,
                                                      out_len) == 0

      needed = out_len.read_ulong
      return nil if needed < 2

      payload_bytes = [needed - 2, buf_bytes - 2].min
      return nil if payload_bytes <= 0

      key_buf.read_bytes(payload_bytes)
             .force_encoding("UTF-16LE")
             .encode("UTF-8")
             .delete("\u0000")
    end

    def read_mark_param_int(mark, key)
      buf = FFI::MemoryPointer.new(:int)
      return nil if Raw.FPDFPageObjMark_GetParamIntValue(mark, key, buf) == 0

      buf.read_int
    end

    def read_mark_param_string(mark, key)
      out_len = FFI::MemoryPointer.new(:ulong)
      buf_bytes = 512
      val_buf = FFI::MemoryPointer.new(:uint8, buf_bytes)
      return nil if Raw.FPDFPageObjMark_GetParamStringValue(mark, key,
                                                              val_buf, buf_bytes,
                                                              out_len) == 0

      needed = out_len.read_ulong
      return nil if needed < 2

      payload_bytes = [needed - 2, buf_bytes - 2].min
      return nil if payload_bytes <= 0

      val_buf.read_bytes(payload_bytes)
             .force_encoding("UTF-16LE")
             .encode("UTF-8")
             .delete("\u0000")
    end

    def annotation_contains?(annot, x, y)
      rect = annot.rect
      return false unless rect

      x >= rect[:x0] && x <= rect[:x1] && y >= rect[:top] && y <= rect[:bottom]
    end

    def box_to_topdown(box)
      return nil unless box

      page_h = height
      [box[:left], page_h - box[:top],
       box[:right], page_h - box[:bottom]]
    end

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

    # Costruisce un segmento dalla coppia di endpoint nello spazio raw
    # PDFium (bottom-up, pre-rotazione). Applica la rotazione della pagina
    # per restituire coord top-down nel sistema post-rotation, coerente
    # con il sistema usato da `chars`.
    def build_segment(x0, y0, x1, y1, rotation_ctx, stroke_width, dashed: false)
      r = rotation_ctx[:rotation]
      raw_w = rotation_ctx[:raw_w]
      raw_h = rotation_ctx[:raw_h]

      nx0, ny0 = apply_page_rotation_to_point(r, raw_w, raw_h, x0, y0)
      nx1, ny1 = apply_page_rotation_to_point(r, raw_w, raw_h, x1, y1)

      {
        x0: nx0, y0: ny0,
        x1: nx1, y1: ny1,
        stroke_width: stroke_width,
        dashed: dashed
      }
    end

    # Trasforma un singolo punto (x, y) dal sistema raw PDFium (bottom-up)
    # al sistema top-down post-rotation della pagina.
    def apply_page_rotation_to_point(rotation, raw_w, raw_h, x, y)
      case rotation
      when 0, nil
        [x, raw_h - y]              # bottom-up → top-down
      when 90
        [y, x]                       # 90° CW
      when 180
        [raw_w - x, y]
      when 270
        [raw_h - y, raw_w - x]
      else
        [x, raw_h - y]
      end
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
