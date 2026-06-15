# frozen_string_literal: true

module Rpdfium
  # Page wrapper. Lazy-loads the TextPage. All returned coordinates are
  # in the page's "top-down" space: (0,0) is at the top left, x grows
  # toward the right, y toward the bottom. PDFium uses "bottom-up" — the
  # conversion happens here once and for all.
  class Page
    attr_reader :document, :index

    def initialize(document, index)
      @document = document
      @index    = index
      handle    = Raw.FPDF_LoadPage(document.handle, index)
      raise PageError, "Could not load page #{index}" if handle.null?

      @text_page = nil
      # State shared with the finalizer: idempotent on close, survives GC
      # without making a double FPDF_ClosePage call. Holding a reference to
      # @document guarantees that the Document is not collected before the
      # Page (FPDF_ClosePage requires the Document still alive).
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

    # ===== Geometry =====

    def width;    Raw.FPDF_GetPageWidthF(@state[:handle]); end
    def height;   Raw.FPDF_GetPageHeightF(@state[:handle]); end

    # Rotation in degrees: 0/90/180/270
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

    # pdfplumber-compatible accessors. Return the box as the tuple
    # [x0, top, x1, bottom] in top-down coordinates (the same system
    # used by chars, edges, table cells). Return nil if the box is not
    # defined in the PDF (e.g. ArtBox or BleedBox are often absent).
    #
    # Usage example:
    #   crop = page.cropbox        # → [0.0, 0.0, 595.28, 841.88] or nil
    #   crop != [0, 0, page.width, page.height]  # PDF has an explicit crop
    def mediabox; box_to_topdown(box(:media)); end

    # PDF spec 14.11.2: if CropBox is absent, the default is MediaBox. The
    # cropbox is the "visible" area of the page; for PDFs from business
    # software it often coincides with the MediaBox. pdfplumber performs the
    # fallback automatically.
    def cropbox
      box_to_topdown(box(:crop)) || mediabox
    end

    def bleedbox; box_to_topdown(box(:bleed)); end
    def trimbox;  box_to_topdown(box(:trim));  end
    def artbox;   box_to_topdown(box(:art));   end

    # ===== Text ("simple" version) =====

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

    # Extracts the text inside an arbitrary bbox (top-down coords).
    # Useful for "read the header of this cell".
    def text_in_bbox(left:, top:, right:, bottom:)
      tp = text_page
      h = height
      # Convert to bottom-up for PDFium
      pdf_top    = h - top
      pdf_bottom = h - bottom
      # PDFium wants: left, top, right, bottom where top > bottom (PDF coords)
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

    # ===== Characters (char-level) =====

    # Returns every char with rich metadata:
    #   :char     string (1 codepoint)
    #   :x0,:x1   horizontal bbox
    #   :top,:bottom  vertical bbox (top-down: top < bottom)
    #   :origin_x, :origin_y  glyph insertion point (top-down)
    #   :angle    glyph rotation angle (radians)
    #   :fontsize size in points
    #   :font     font name (if available)
    #   :weight   weight (e.g. 400=regular, 700=bold)
    #   :render_mode  rendering mode (fill/stroke/invisible). Read via
    #                 the text object that contains the char (PDFium no
    #                 longer exposes a char-level API after chromium/6611).
    #                 nil on old PDFium builds that do not support the
    #                 char→object lookup.
    #   :generated  true if inserted by PDFium (e.g. synthetic spaces)
    #   :hyphen   true if a hyphenation hyphen
    #   :unicode_error  true if PDFium could not map it
    #
    # `loose: true` (DEFAULT) uses FPDFText_GetLooseCharBox: all chars on
    # the same logical line share the same vertical bbox (top/bottom),
    # proportional to the font size rather than to the individual glyph.
    # This is exactly the behavior of pdfminer.six/pdfplumber, and the only
    # one that lets the midpoint test in Table#extract also capture
    # punctuation chars (`.`, `,`) along with the numbers aligned to the
    # baseline. With `loose: false` you get the "tight" bbox of the single
    # glyph, useful for fine layout measurements but wrong for the table
    # cell filter.
    # `geometry: true` is a stronger form of `lean` reserved for the
    # table/word pipeline: on top of `lean` it ALSO skips the per-char
    # origin (FPDFText_GetCharOrigin) and the text-object lookup
    # (FPDFText_GetTextObject + GetFont/GetFontSize/GetTextRenderMode/
    # GetText), and emits a 6-key hash (char, x0, x1, top, bottom,
    # generated) instead of the full one. Those are exactly the fields the
    # WordExtractor / Table pipeline reads; cutting the rest removes ~3 FFI
    # roundtrips per char and a large amount of hash allocation, which on a
    # page with thousands of chars is the dominant cost of extract_tables.
    # Unlike `lean` (which keeps the full hash shape, just with nil/false
    # metadata), `geometry` changes the hash shape, so it is NOT a drop-in
    # for general char consumers — only for the geometry-only pipeline.
    def chars(loose: true, inject_spaces: true, lean: false, geometry: false)
      # Cache: chars() is called once by Table#extract and then again by
      # WordExtractor (going through Extractor#page_words if
      # vertical/horizontal_strategy is :text). Each call costs O(n) FFI
      # roundtrips per char — expensive on pages with thousands of chars.
      cache_key = [loose, inject_spaces, lean, geometry]
      @chars_cache ||= {}
      return @chars_cache[cache_key] if @chars_cache.key?(cache_key)

      raw = geometry ? compute_geometry_chars(loose: loose) : compute_chars(loose: loose, lean: lean)
      result = inject_spaces ? rebuild_word_separators(raw) : raw
      @chars_cache[cache_key] = result
    end

    # Rebuilds the spaces that separate words based on the GEOMETRY of the
    # "real" chars, completely discarding PDFium's synthetic spaces (which
    # are unreliable: PDFium emits them aggressively even between digits of
    # numbers like "2.895,26").
    #
    # Algorithm:
    #   1. Filter out all :generated chars (typically synthetic spaces
    #      with a degenerate bbox).
    #   2. Cluster the remaining chars by row (top tolerance 1pt).
    #   3. Within each row, sort by x0 and for each consecutive pair
    #      compute gap = next.x0 - prev.x1 and char_w = (prev.w + next.w) / 2.
    #      If gap > 0.275 × char_w → insert a new synthetic space
    #      (bbox normalized to the top/bottom of the chars).
    #
    # Threshold 0.275: tuned empirically on a real TeamSystem PDF.
    # Measured distribution: intra-word gap max ratio 0.24, inter-word
    # gap min ratio 0.31. Classification 100% correct on the training
    # dataset (1400 intra + 663 inter cases). pdfminer.six uses 0.1
    # internally (`word_margin`) but with additional info from the font
    # advance, not available from PDFium.
    def rebuild_word_separators(chars)
      reals = chars.reject { |c| c[:generated] }
      return chars if reals.empty?

      # Cluster by row, preserving the top ordering
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

            # Signal from the PDF content stream: prev.text_obj_ends_with_space.
            # If prev does NOT end a token (false), the gap is internal
            # kerning → never insert a space.
            #
            # If prev ends a token (true), it may be:
            #   - a real word end (relatively large geometric gap)
            #   - a syntactic token end (e.g. between digits and punctuation
            #     of a number "2", "."), with a small gap.
            #
            # We discriminate with the geometric threshold combined with the
            # typographic "context": if the pair (prev_char, curr_char) looks
            # like a numeric context (digits + punctuation), we use a higher
            # threshold; otherwise the normal threshold.
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

    # True if the pair (prev_char, curr_char) is a "numeric" context:
    # digit-punctuation, punctuation-digit, or digit-digit. In these
    # cases a modest gap is probably kerning internal to the number, not
    # a word boundary. A higher threshold avoids splitting numbers like
    # "2.895,26" into "2 . 895 , 26".
    NUMERIC_PUNCT = %w[. , ].freeze

    def numeric_context?(prev_char, curr_char)
      return false if prev_char.nil? || curr_char.nil?

      prev_num = prev_char.match?(/\d/) || NUMERIC_PUNCT.include?(prev_char)
      curr_num = curr_char.match?(/\d/) || NUMERIC_PUNCT.include?(curr_char)
      prev_num && curr_num
    end

    # Returns the "reference" width for computing the gap/width ratio.
    # Prefers the advance (more stable than the bbox for chars with
    # post-applied kerning). If either char lacks an advance, falls back
    # to the max of the bbox widths.
    def best_reference_width(a, b)
      a_adv = a[:advance]
      b_adv = b[:advance]

      return [a_adv, b_adv].max if a_adv && b_adv

      [(a[:x1] - a[:x0]), (b[:x1] - b[:x0])].max
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

      # Page geometry after applying the PDF rotation.
      h = height
      w = width
      page_rotation = rotation

      raw_w, raw_h = case page_rotation
                     when 90, 270 then [h, w]
                     else [w, h]
                     end

      result = Array.new(n)

      # FFI buffers reused across all loop iterations.
      # MemoryPointer.new is non-trivial (~µs each); allocating O(n) of them
      # per char is the main cost of compute_chars after the FFI calls.
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

        # Font name: skipped in lean mode (1 FFI call saved per char).
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

        # Advance: 2 FFI calls per char (GetGlyphWidth + GetMatrix). In lean
        # mode we skip it — best_reference_width falls back to bbox-width
        # which works just as well for the word-boundary discriminant.
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

        # In lean mode we skip 5 FFI calls per char:
        # GetCharAngle, GetFontWeight, IsHyphen, HasUnicodeMapError,
        # (and the GetFontSize fallback if font_size_for_obj is nil).
        # On pages with thousands of chars the saving is significant
        # (tens of ms). The metadata come out nil/false, which is the
        # neutral value for the internal text/tables/words pipeline.
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

    # Minimal char extraction for the table/word pipeline. See `chars`
    # `geometry:` for the rationale. Compared to compute_chars(lean: true)
    # this skips, per char: FPDFText_GetCharOrigin (origin is never read by
    # the pipeline) and the per-char angle/font/weight/render-mode reads,
    # the page rotation is applied inline (no origin, no intermediate
    # 6-tuple allocation), and the result hash carries only the fields the
    # WordExtractor / Table / rebuild_word_separators path reads.
    #
    # `text_obj_ends_with_space` is intentionally KEPT: rebuild_word_separators
    # uses it as the content-stream "token end" signal that distinguishes a
    # word boundary from internal numeric kerning (e.g. "2.895,26"). Dropping
    # it would change word splitting on PDFs that rely on that signal, so the
    # GetTextObject lookup stays (its info tuple is cached per text object).
    def compute_geometry_chars(loose:)
      tp = text_page
      n = tp.char_count
      return [] if n.zero?

      page_rotation = rotation
      raw_w, raw_h = case page_rotation
                     when 90, 270 then [height, width]
                     else [width, height]
                     end

      result = Array.new(n)

      # FFI buffers reused across all iterations (see compute_chars).
      l = FFI::MemoryPointer.new(:double)
      r = FFI::MemoryPointer.new(:double)
      b = FFI::MemoryPointer.new(:double)
      t = FFI::MemoryPointer.new(:double)
      rect = Raw::FS_RECTF.new
      fs_buf = FFI::MemoryPointer.new(:float)
      text_obj_text_buf = FFI::MemoryPointer.new(:uint8, TEXT_OBJ_INITIAL_BUF_BYTES)
      text_obj_cache = {}
      tp_handle = tp.handle

      n.times do |i|
        x0, x1, y_top, y_bot = read_char_bbox(tp, i, loose, l, r, b, t, rect)

        text_obj = begin
          Raw.FPDFText_GetTextObject(tp_handle, i)
        rescue Rpdfium::LoadError
          nil
        end
        _, _, _, ends_with_space =
          fetch_text_obj_info(text_obj, tp, text_obj_cache,
                              fs_buf: fs_buf, text_buf: text_obj_text_buf)

        # Inline page-rotation → top-down coords (mirror of
        # apply_page_rotation_to_char, dropping the origin outputs).
        case page_rotation
        when 90
          td_x0, td_x1, td_top, td_bottom = y_bot, y_top, x0, x1
        when 180
          td_x0, td_x1, td_top, td_bottom = raw_w - x1, raw_w - x0, y_bot, y_top
        when 270
          td_x0, td_x1, td_top, td_bottom = raw_h - y_top, raw_h - y_bot, raw_w - x1, raw_w - x0
        else # 0, nil, or non-multiple-of-90 fallback
          td_x0, td_x1, td_top, td_bottom = x0, x1, raw_h - y_top, raw_h - y_bot
        end

        result[i] = {
          char:      safe_codepoint(Raw.FPDFText_GetUnicode(tp_handle, i)),
          x0:        td_x0,
          x1:        td_x1,
          top:       td_top,
          bottom:    td_bottom,
          generated: Raw.FPDFText_IsGenerated(tp_handle, i) == 1,
          text_obj_ends_with_space: ends_with_space
        }
      end
      result
    end

    # Applies the page rotation to a char's coordinates.
    #
    # Input: raw PDFium coords (bottom-up, pre-rotation) of a bbox
    # `[x0, x1, y_top, y_bot]` (with y_top > y_bot because bottom-up) and
    # of an origin point.
    #
    # Output: top-down coords in the post-rotation page system, in the
    # standard rpdfium convention: `[x0, x1, top, bottom]` with
    # `top < bottom`. Consistent with pdfplumber.
    #
    # PDFium convention: GetRotation = N means the displayed page is
    # rotated by N*90° clockwise relative to the raw content stream
    # system. PDFium returns the coords in the raw system; we apply the
    # rotation to align with the rendering.
    #
    # Case 0°: identity + bottom-up→top-down.
    # Case 90° CW: a bbox wide in x becomes tall in y. The raw x_min (left)
    #   coincides with the top of the post-rotation system.
    # Case 180°: flips both axes.
    # Case 270° CW: a bbox wide in x becomes tall in y, but flipped vertically.
    def apply_page_rotation_to_char(rotation, raw_w, raw_h,
                                     x0, x1, y_top, y_bot,
                                     origin_x, origin_y)
      case rotation
      when 0, nil
        # No rotation. Standard bottom-up → top-down.
        # page_h_post == raw_h.
        [x0, x1, raw_h - y_top, raw_h - y_bot,
         origin_x, raw_h - origin_y]

      when 90
        # 90° CW. Post-rotation dimensions: w=raw_h, h=raw_w.
        # Transform: x_post = y_raw, y_post = raw_w - x_raw (bottom-up).
        # In top-down: top = x_min_raw, bottom = x_max_raw.
        new_x0 = y_bot   # small y_raw → small x_post
        new_x1 = y_top   # large y_raw → large x_post
        new_top    = x0  # small x_raw → small top (high)
        new_bottom = x1  # large x_raw → large bottom (low)
        new_ox = origin_y
        new_oy = origin_x       # top-down origin_y = x_raw
        [new_x0, new_x1, new_top, new_bottom, new_ox, new_oy]

      when 180
        # 180°. Post-rotation dimensions: unchanged (raw_w × raw_h).
        # Transform: x_post = raw_w - x_raw, y_post = raw_h - y_raw.
        # In top-down: top = y_bot_raw, bottom = y_top_raw.
        new_x0 = raw_w - x1
        new_x1 = raw_w - x0
        new_top    = y_bot   # raw bottom → td top (high)
        new_bottom = y_top   # raw top → td bottom (low)
        new_ox = raw_w - origin_x
        new_oy = y_top.zero? ? raw_h - origin_y : raw_h - origin_y
        # note: origin in top-down post-180 = y_origin_raw
        new_oy = origin_y
        [new_x0, new_x1, new_top, new_bottom, new_ox, new_oy]

      when 270
        # 270° CW (= 90° CCW). Post-rotation dimensions: w=raw_h, h=raw_w.
        # Transform: x_post = raw_h - y_raw, y_post = x_raw (bottom-up).
        # In top-down: top = raw_w - x_max_raw, bottom = raw_w - x_min_raw.
        new_x0 = raw_h - y_top  # large y → small x_post
        new_x1 = raw_h - y_bot
        new_top    = raw_w - x1
        new_bottom = raw_w - x0
        new_ox = raw_h - origin_y
        new_oy = raw_w - origin_x
        [new_x0, new_x1, new_top, new_bottom, new_ox, new_oy]

      else
        # Non-standard rotation (not a multiple of 90°): fall back to
        # the pre-rotation behavior. This should never happen for
        # well-formed PDFs.
        [x0, x1, raw_h - y_top, raw_h - y_bot,
         origin_x, raw_h - origin_y]
      end
    end

    # Cache lookup for a text object. Returns a tuple:
    #   [render_mode, font_handle, font_size, ends_with_space]
    #
    # `ends_with_space` indicates whether the text of the entire text object
    # ends with a space (a "token end" signal declared by the PDF). It is a
    # property of the object, not of the single char, so it can be computed
    # once and cached together with the other fields — this avoids one
    # FPDFTextObj_GetText call for every char that shares the obj.
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

    # "Fast" version of read_text_obj_text_from: reuses the passed buffer
    # instead of allocating it. For 99% of text objs the initial 256-byte
    # buffer is enough; in the rare case PDFium requires more space, it
    # allocates a larger buffer on demand (this is a rare path, OK to
    # allocate).
    def read_text_obj_text_fast(text_obj, tp, buf)
      return nil if text_obj.nil? || text_obj.null?

      needed = Raw.FPDFTextObj_GetText(text_obj, tp.handle, buf,
                                        TEXT_OBJ_INITIAL_BUF_BYTES)
      return nil if needed < 2

      if needed > TEXT_OBJ_INITIAL_BUF_BYTES
        # Rare path: text obj with > 128 chars. Allocate a dedicated buffer.
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

    # "Fast" version of compute_glyph_advance: reuses gw_buf and matrix
    # instead of allocating them per char. Same functional behavior.
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

      # CTM scale: reuse the matrix in-place.
      scale = if Raw.FPDFText_GetMatrix(tp_handle, char_index, matrix) == 1
                matrix[:a].abs
              else
                1.0
              end
      glyph_w_font_units * scale
    end

    # Initial buffer size for FPDFTextObj_GetText: 256 bytes = 128 UTF-16 chars.
    # Empirically sufficient for ~99% of real text objects (single words or
    # short phrases). When a text obj is larger, we fall back to the correct
    # probe-then-fetch.
    TEXT_OBJ_INITIAL_BUF_BYTES = 256

    # Reads the text of a PDF text object.
    #
    # C signature: `unsigned long FPDFTextObj_GetText(FPDF_PAGEOBJECT, FPDF_TEXTPAGE,
    # FPDF_WCHAR* buffer, unsigned long length)` — length in BYTES, the return
    # is the total number of bytes needed (including the null terminator), even
    # if the buffer is too small. Pattern: try with a stack-friendly buffer,
    # if PDFium requires more, reallocate.
    def read_text_obj_text_from(text_obj, tp, _char_index_unused = nil)
      return nil if text_obj.nil? || text_obj.null?

      # First attempt: fixed 256-byte buffer. Resolves 99% of cases.
      buf = FFI::MemoryPointer.new(:uint8, TEXT_OBJ_INITIAL_BUF_BYTES)
      needed = Raw.FPDFTextObj_GetText(text_obj, tp.handle, buf,
                                        TEXT_OBJ_INITIAL_BUF_BYTES)
      return nil if needed < 2

      # If PDFium wants more than what was allocated, reallocate exactly.
      if needed > TEXT_OBJ_INITIAL_BUF_BYTES
        buf = FFI::MemoryPointer.new(:uint8, needed)
        needed = Raw.FPDFTextObj_GetText(text_obj, tp.handle, buf, needed)
        return nil if needed < 2
      end

      # Defensive clamp: never read more than what was allocated.
      buf_capacity = buf.size
      payload_bytes = [needed - 2, buf_capacity - 2].min
      return nil if payload_bytes <= 0

      buf.read_bytes(payload_bytes)
         .force_encoding("UTF-16LE")
         .encode("UTF-8")
         .delete("\u0000")
    end

    # Computes the glyph advance in page coordinates, for a specific char
    # identified by (text_page, char_index).
    # Formula: glyph_width(font, codepoint, font_size) × |CTM.a|.
    # Returns nil if the advance is not computable (font unavailable,
    # PDFium not supporting the API).
    def compute_glyph_advance(font, codepoint, font_size, tp, char_index)
      return nil if font.nil? || font_size.nil?

      gw_buf = FFI::MemoryPointer.new(:float)
      ok = begin
        Raw.FPDFFont_GetGlyphWidth(font, codepoint, font_size, gw_buf)
      rescue Rpdfium::LoadError
        return nil  # FPDFFont_GetGlyphWidth not available in old builds
      end
      return nil if ok == 0

      glyph_w_font_units = gw_buf.read_float
      scale = char_ctm_scale_x(tp, char_index) || 1.0
      glyph_w_font_units * scale
    end

    # Computes the horizontal CTM scale for a specific char.
    def char_ctm_scale_x(tp, char_index)
      mat = Raw::FS_MATRIX.new
      return nil if Raw.FPDFText_GetMatrix(tp.handle, char_index, mat) == 0

      mat[:a].abs
    end

    # ===== Form-aware extraction =====
    #
    # "Filled form" PDFs (F24, Comunicazione IVA, 770, etc.) are output PDFs
    # where the pre-printed template and the entered values coexist as
    # graphical text — no AcroForm, no PDF/UA tag. The geometric table
    # extraction pipeline sees the whole form and produces noise (template
    # labels mixed in with the data).
    #
    # The robust strategy on these PDFs is to separate the chars by "role"
    # using font/height, which typically differ between the template
    # (proportional fonts, various sizes) and the data entered by the
    # business software (a single font, typically Courier or Helvetica,
    # a single size).
    #
    # Classic F24 example:
    #   Template: Futura-Light, Futura-Bold, Futura-Heavy, Times-Bold
    #   Data:     Courier 10.0
    #
    #   page.font_inventory          # → sees all the (font, height)
    #   page.chars_where(font: /Courier/i)
    #     # → only the chars of the entered data
    #   page.lines(font: /Courier/i) # → data text line by line

    # Distribution of chars by (font, visual height, weight).
    #
    # Returns an Array of Hash sorted by descending count:
    #   [{ font:, height:, weight:, count:, sample: }, ...]
    #
    # `height` is the visual height of the char in points (bottom - top),
    # more reliable than `fontsize`, which PDFium normalizes to 1.0 when the
    # real size is in the CTM matrix (a common case on forms generated with
    # scaling).
    #
    # `sample` is the first 40 chars of that group, in document order, for
    # inspection.
    #
    # Heights are bucketed within `height_tolerance` (single-linkage, per
    # font+weight) rather than rounded to a fixed precision. A round glyph
    # whose loose box overshoots the cap line by a fraction of a point
    # ("O", "S", "C"...) would otherwise land in a spurious one-glyph group
    # (e.g. "O" at h=6.6 split off from the rest of the line at h=6.5,
    # producing garbled samples like "CDICE FISCALE" with every "O"
    # missing). Clustering keeps each logical size in a single group.
    #
    # Use it to choose the `chars_where` filter: typically the font with the
    # most chars is the template, and the minority fonts (a single size,
    # often monospace) are the data.
    def font_inventory(height_tolerance: 0.5)
      real = chars.reject { |c| c[:generated] }
      # Tag with document position so the cluster (which gets reordered by
      # height) can be put back in reading order for the sample.
      indexed = real.each_with_index.to_a

      by_font_weight = indexed.group_by { |(c, _i)| [c[:font], c[:weight]] }

      by_font_weight.flat_map do |(font, weight), pairs|
        height_of = ->(p) { p[0][:bottom] - p[0][:top] }
        Util::Cluster.cluster_objects(pairs, height_of, tolerance: height_tolerance).map do |cluster|
          mean_h = cluster.sum { |p| height_of.call(p) } / cluster.size.to_f
          ordered = cluster.sort_by { |(_c, i)| i }
          {
            font: font,
            height: mean_h.round(1),
            weight: weight,
            count: cluster.size,
            sample: ordered.first(40).map { |(c, _i)| c[:char] }.join
          }
        end
      end.sort_by { |g| -g[:count] }
    end

    # Generic char filter. Returns the chars that match ALL the specified
    # predicates (intersection, not union).
    #
    # Supported arguments:
    #   font:   exact String, Array<String>, or Regexp
    #   height: Float (single value), Range, Array<Float>
    #   weight: Integer or Range
    #   bbox:   [left, top, right, bottom] in the page's top-down coords
    #   where:  block that receives the char hash, must return truthy
    #
    # All parameters are optional; the ones passed are combined with AND.
    #
    # Typically combined with WordExtractor to extract "clean" text:
    #
    #   data_chars = page.chars_where(font: /Courier/i)
    #   words = Rpdfium::Util::WordExtractor.new.extract_words(data_chars)
    #
    # or used as a building block for custom pipelines.
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

    # Groups the filtered chars into logical rows and returns an Array of
    # strings (one per row, top-to-bottom, chars within the row
    # left-to-right). Convenient when the PDF is a filled form and you
    # want only the entered values as clean rows.
    #
    # F24 example:
    #
    #   page.lines(font: /Courier/i)
    #   # => ["Soggetto:  Azienda  S.R.L.  ( 01234567890 )",
    #   #     "0  1  2  3  4  5  6  7  8  9  0",
    #   #     "Azienda  S.R.L.",
    #   #     "1001  11  2021  499,81  0,00",
    #   #     "1712  12  2021  32,46  0,00",
    #   #     "1701  11  2021  0,00  295,89",
    #   #     "532,27  295,89  236,38",
    #   #     ...]
    #
    # The filter parameters are the same as `chars_where`. The
    # `x_tolerance` and `y_tolerance` parameters control the WordExtractor.
    #
    # The inter-word separator is two spaces (for readability on forms with
    # spaced fields); change it with `separator:`.
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

      # Cluster by top (with tolerance), then sort by x0 within the row
      rows = Util::Cluster.cluster_objects(words, :top, tolerance: y_tolerance)
      rows.map do |row_words|
        row_words.sort_by { |w| w[:x0] }.map { |w| w[:text] }.join(separator)
      end
    end

    # Associates the template's semantic labels with the values entered on
    # the page. For filled forms (F24, Comunicazione IVA, 770, etc.) where
    # the template and the data are both static text but in different fonts.
    #
    # @param data_font [String, Regexp, Array] font of the entered "data"
    #   layer. Typically Courier (F24, 770) or Helvetica (Comunicazione IVA).
    #   See `Page#font_inventory` to identify it.
    # Associates the template's semantic labels with the values entered on
    # the page. A primitive for structured extraction from filled forms
    # where template and data coexist as graphical text in different fonts.
    #
    # **For advanced cases** (repetitive tables, merging of multi-cell
    # words, structured output) compose with `Util::WordMerger`,
    # `Util::ColumnInference`, and configure the `Util::LabelMatcher`
    # appropriately — see the examples in the docs.
    #
    # @param data_font [String, Regexp, Array] font of the "data" layer.
    # @param template_font [String, Regexp, Array, nil] font of the
    #   "template" layer. If nil, uses all chars that are NOT in `data_font`.
    # @param data_filter [Proc, nil] optional filter on the value text.
    # @param matcher [LabelMatcher, nil] preconfigured instance. If nil,
    #   creates one with the defaults.
    # @param x_tolerance, y_tolerance [Float] tolerances for WordExtractor.
    # @param char_opts [Hash] kwargs passed to `#chars` (e.g. `inject_spaces:
    #   false` for box-based forms).
    #
    # @return [Array<Hash>] one per value:
    #   { value:, labels: { col:, row: }, geometry: {...} }
    def label_value_pairs(data_font:, template_font: nil,
                          data_filter: nil, matcher: nil,
                          x_tolerance: 3.0, y_tolerance: 3.0,
                          **char_opts)
      data_chars = chars_where(font: data_font, **char_opts)
      anchor_chars =
        if template_font
          chars_where(font: template_font, **char_opts)
        else
          chars(**char_opts).reject { |c| c[:generated] }.reject do |c|
            send(:font_matches?, c[:font], data_font)
          end
        end

      we = Util::WordExtractor.new(x_tolerance: x_tolerance, y_tolerance: y_tolerance)
      data_words = we.extract_words(data_chars)
      data_words = data_words.select { |w| data_filter.call(w[:text]) } if data_filter
      anchor_words = we.extract_words(anchor_chars)

      m = matcher || Util::LabelMatcher.new
      m.match(data_words, anchor_words)
    end

    # ===== Words =====


    def words(x_tolerance: 3.0, y_tolerance: 3.0, **char_opts)
      cs = chars(**char_opts)
      return [] if cs.empty?

      # Group into rows by y
      rows = group_consecutive(cs.sort_by { |c| [c[:top], c[:x0]] }) do |a, b|
        (a[:top] - b[:top]).abs <= y_tolerance
      end

      rows.flat_map do |row|
        sorted = row.sort_by { |c| c[:x0] }
        # Split on gap > x_tolerance or explicit space
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

    # ===== Vector lines (REAL path segments) =====

    # Extracts all the line segments (LINETO) of the path objects.
    # Returns Array<Hash>:
    #   :x0,:y0,:x1,:y1  endpoints (top-down)
    #   :stroke_width    stroke width
    #   :horizontal/:vertical  derived for convenience
    #
    # For tables, mainly the "pure" horizontal and vertical segments are of
    # interest. Beziers and oblique segments are ignored by default
    # (pass `include_curves: true` to get them as the bbox of their points).
    #
    # Descends recursively into Form XObjects applying their transformation
    # matrix. Many PDFs (TeamSystem, Zucchetti, Excel templates) encapsulate
    # the entire page in a Form XObject — without the descent, we would see
    # zero lines here even though the page is visually full of
    # borders/separators. Behavior aligned with pdfminer.six (and therefore
    # pdfplumber).
    # `include_curves` true: includes Beziers as segments (with the :curve flag).
    # `include_dashed` true: includes dashed lines (with the :dashed flag).
    #   Default: false. Dashed lines are often non-visual "guides" in print
    #   templates and confuse table cell detection. Those who want them
    #   explicitly (e.g. full drawing extraction) pass true.
    def line_segments(include_curves: false, include_dashed: false)
      # Cache by parameters: line_segments is typically called twice per
      # page (by horizontal_lines AND by vertical_lines), and iterates all
      # the path objects of the page via FFI — expensive on PDFs with rich
      # graphics (e.g. CR Banca d'Italia: ~500-1000 path objs per page).
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

    # Identity matrix in PDF space: [1, 0, 0, 1, 0, 0]
    # (a, b, c, d, e, f) → (x', y') = (a*x + c*y + e,  b*x + d*y + f)
    def identity_matrix
      { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0 }
    end

    # Composes two PDF affine transforms: applies `child` BEFORE `parent`
    # in PDF space (pdfminer.six "apply_matrix_norm" notation).
    # Equivalent to: result = parent * child  (col-major).
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

    # Iterates the objects of a page or of a Form XObject, recursively
    # applying the transformation matrix. `parent` = handle (FPDF_PAGE at the
    # root or FPDF_PAGEOBJECT for form xobjects). `page_object: true` if
    # parent is a form xobject.
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
          # Descend into the form xobject composing its matrix with the CTM
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

    # FPDFPageObj_GetIsActive: returns true if the page object is marked
    # active (visible). On PDFs without Optional Content it is always-true;
    # on PDFs with disabled layers, some objs may be inactive.
    # Fallback: if the binding is missing or fails, we consider it active
    # (behavior equivalent to the pre-0.3.6 version).
    def object_active?(obj)
      active_buf = FFI::MemoryPointer.new(:int)
      return true if Raw.FPDFPageObj_GetIsActive(obj, active_buf) == 0

      active_buf.read_int != 0
    rescue Rpdfium::LoadError
      true
    end

    # FPDFPageObj_GetDashCount: number of elements in the dash array. 0 =
    # solid line, > 0 = dashed line (with N elements alternating on/off).
    def read_dash_count(obj)
      Raw.FPDFPageObj_GetDashCount(obj)
    rescue Rpdfium::LoadError
      0
    end

    public

    # Horizontal lines: dy ~ 0 within tolerance
    def horizontal_lines(tolerance: 0.5)
      line_segments.select { |s| (s[:y0] - s[:y1]).abs <= tolerance }
                   .map { |s| { y: (s[:y0] + s[:y1]) / 2.0,
                                x0: [s[:x0], s[:x1]].min,
                                x1: [s[:x0], s[:x1]].max,
                                stroke_width: s[:stroke_width] } }
    end

    # Vertical lines: dx ~ 0 within tolerance
    def vertical_lines(tolerance: 0.5)
      line_segments.select { |s| (s[:x0] - s[:x1]).abs <= tolerance }
                   .map { |s| { x: (s[:x0] + s[:x1]) / 2.0,
                                top: [s[:y0], s[:y1]].min,
                                bottom: [s[:y0], s[:y1]].max,
                                stroke_width: s[:stroke_width] } }
    end

    # Compat with the first version: bbox of the path objects (useful for
    # rectangles drawn as thin borders).
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

    # Iterates all the marked content of the page (BDC/BMC operators of the
    # PDF content stream) grouping the page objects by their mcid (Marked
    # Content ID). Useful for "tagged" PDFs (PDF/UA, exports from
    # Word/InDesign): an mcid ≥ 0 identifies a semantic unit (paragraph,
    # span, figure), and all the objects with the same mcid belong to the
    # same structure tag.
    #
    # Returns a Hash { mcid (Integer) => Array<page_object_handle> }.
    # mcid -1 (the page objects without marked content) is OMITTED.
    #
    # On non-tagged PDFs (e.g. most PDFs from Italian business software)
    # the Hash is empty. On tagged PDFs it is the source of truth for
    # semantically grouping chars/words — more reliable than any geometric
    # heuristic.
    def marked_content_regions
      out = Hash.new { |h, k| h[k] = [] }
      walk_page_objects do |obj, _ctm|
        mcid = read_marked_content_id(obj)
        out[mcid] << obj if mcid >= 0
      end
      out
    end

    # Iterates all the marks (BMC/BDC operators) with their names and
    # parameters. Returns Array<Hash> with { obj_handle, mark_name, params }.
    # For tagged PDFs, the common mark_names are: "P" (paragraph),
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

    # Hit-test: returns the link annotation that contains the point (x, y)
    # in the page's top-down coordinates. Returns an Annotation instance
    # or nil.
    #
    # More efficient than iterating `links` when starting from a coordinate
    # (e.g. mapping a click on the rendering → the link URL). pdfplumber has
    # no direct equivalent.
    def link_at(x, y)
      # PDFium uses bottom-up coords; convert
      pdf_y = height - y
      link_handle = Raw.FPDFLink_GetLinkAtPoint(@state[:handle],
                                                 x.to_f, pdf_y.to_f)
      return nil if link_handle.null?

      annot_handle = Raw.FPDFLink_GetAnnot(@state[:handle], link_handle)
      return nil if annot_handle.null?

      # Annotation requires an index in the page; we do not have it directly
      # here. We iterate the page's annotations and find the one with the
      # closest rect. For most PDFs this is O(small).
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

    # ===== Annotations =====

    def annotations
      n = Raw.FPDFPage_GetAnnotCount(@state[:handle])
      Array.new(n) { |i| Annotation.new(self, i) }
    end

    # Link annotations only (clickable, external or internal)
    def links
      annotations.select { |a| a.subtype == :link }
    end

    # Form widgets only
    def form_fields
      return [] unless @document.has_forms?

      annotations.select { |a| a.subtype == :widget }
                 .map    { |a| Form::Field.new(@document.form_env, a) }
    end

    # ===== Struct Tree (PDF tagged) =====

    # Struct tree of the page (PDF/UA / Tagged PDF). Returns nil if the
    # page is not tagged. For PDFs from Word/LibreOffice/InDesign exports
    # with accessibility tags enabled, it exposes the logical structure
    # (Document → P, H1, Table, TR, TH, TD, Figure, etc.).
    #
    # Usage modes:
    #
    #   # Automatic lifecycle (RAII via finalizer):
    #   tree = page.struct_tree
    #   tree&.walk { |el| puts el.type }
    #
    #   # Deterministic lifecycle (close at end of block):
    #   page.struct_tree do |tree|
    #     tree.tables.each { |t| ... }
    #   end
    #
    # On non-tagged PDFs it returns nil. On "tagged but empty" PDFs (e.g. CR
    # Banca d'Italia, StructTreeRoot present but with placeholder elements),
    # it returns a Tree with `Tree#empty? == true`.
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

    # Render to a bitmap. `output` can be :rgba (default), :bgra, :gray.
    # Returns [w, h, bytes] where bytes is a binary string.
    # If include_forms is true and the document has forms, it overlays the
    # widgets.
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
        # The stride may exceed w*bpp due to alignment padding.
        # In BGRA it is almost always w*4, but we respect it for safety.
        bytes  = buf.read_bytes(stride * h)
        [w, h, bytes, stride]
      ensure
        Raw.FPDFBitmap_Destroy(bitmap)
      end
    end

    # Direct rendering to a PNG file. Uses Rpdfium::IO::PNG (pure Ruby, zero deps).
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

    # Match helper for the `font:` parameter of chars_where/lines.
    def font_matches?(actual_font, pattern)
      return false if actual_font.nil?

      case pattern
      when String  then actual_font == pattern
      when Regexp  then actual_font.match?(pattern)
      when Array   then pattern.any? { |p| font_matches?(actual_font, p) }
      else false
      end
    end

    # Match helper for numeric parameters (`height:`, `weight:`).
    # Accepts a single value, Range, or Array<Numeric>. For a single
    # numeric value it uses a 0.05 tolerance (useful for height in points).
    def range_matches?(actual, spec)
      return false if actual.nil?

      case spec
      when Range    then spec.cover?(actual)
      when Array    then spec.any? { |s| range_matches?(actual, s) }
      when Numeric  then (actual - spec).abs < 0.1
      else false
      end
    end

    # Converts a PDFium box {left, bottom, right, top} in bottom-up coords
    # to the top-down tuple [x0, top, x1, bottom] used by the rest of the
    # library. Returns nil if the box is nil (box absent on the PDF).
    # Iterates all the page objects of the page recursively (descending
    # into Form XObjects), passing each (obj, current_ctm) to the block.
    # Same walk logic as collect_line_segments but abstracted — useful for
    # other obj-level operations (marked content, etc).
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

      # Clamp: if needed exceeds the buffer, read only what was allocated
      # (and accept that the string is truncated: the case is pathological).
      # Without the clamp → IndexError on exceptionally long mark names.
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

        # Value type: 0=Null, 1=Int, 2=String, 3=Blob, 4=Dict (ignored)
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

    # Builds a segment from the pair of endpoints in the raw PDFium space
    # (bottom-up, pre-rotation). Applies the page rotation to return
    # top-down coords in the post-rotation system, consistent with the
    # system used by `chars`.
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

    # Transforms a single point (x, y) from the raw PDFium system (bottom-up)
    # to the page's top-down post-rotation system.
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

    # Groups consecutive elements if a block considers them equivalent.
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

  # Wrapper for FPDF_TEXTPAGE
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
