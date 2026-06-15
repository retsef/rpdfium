# frozen_string_literal: true

require "ffi"
require "rbconfig"

module Rpdfium
  # Layer 1: raw FFI bindings to the PDFium C API.
  # 1:1 mapping with the original names. Use the wrapper classes for
  # application code. PDFium "Experimental" APIs are marked in the comments:
  # in theory they could change, in practice they have been stable for years.
  module Raw
    extend FFI::Library

    # Builds the list of candidates that `ffi_lib` will try in order.
    #
    # WARNING: FFI auto-appends the platform's "natural" extension
    # (.dylib on macOS, .so on Linux, .dll on Windows) when the supplied path
    # does not already end with a known extension. Therefore, if we pass
    # `libpdfium.so` on macOS, FFI looks for `libpdfium.so.dylib` — absurd but
    # documented. To avoid this, we filter the system_library_names by
    # host OS.
    #
    # Additionally: ENV["PDFIUM_LIBRARY_PATH"] and Rpdfium::Binary.library_path
    # are ABSOLUTE/EXPLICIT paths: if they are not found, we do NOT fall back
    # to system names. We immediately return an array of a single path: in
    # that case ffi_lib either succeeds right away, or raises a clear LoadError
    # (which is what the user wants — they provided an explicit path).
    def self.candidate_paths
      explicit = ENV["PDFIUM_LIBRARY_PATH"]
      return [explicit] if explicit && !explicit.empty?

      if defined?(Rpdfium::Binary) && Rpdfium::Binary.respond_to?(:library_path)
        path = Rpdfium::Binary.library_path
        return [path] if path && !path.empty?
      end

      system_library_names
    end

    # "System" names filtered by host OS. We keep `pdfium` /
    # `libpdfium` (without extension) first: FFI auto-appends the right ext.
    # Names with an extension are included ONLY if they match the host OS, so
    # we avoid the double-extension bug.
    def self.system_library_names
      base = %w[pdfium libpdfium]
      host = host_os
      ext_specific = case host
                     when :macos   then %w[libpdfium.dylib]
                     when :linux   then %w[libpdfium.so]
                     when :windows then %w[pdfium.dll libpdfium.dll]
                     else []
                     end
      base + ext_specific
    end

    def self.host_os
      case RbConfig::CONFIG["host_os"]
      when /darwin/         then :macos
      when /linux/          then :linux
      when /mswin|mingw|cygwin/ then :windows
      end
    end

    @native_loaded = false
    @load_error    = nil

    def self.native_loaded?; @native_loaded; end
    def self.load_error;     @load_error;    end

    begin
      ffi_lib(*candidate_paths)
      ffi_convention :default # cdecl everywhere, even on Win64 (bblanchon build)
      @native_loaded = true
    rescue ::LoadError, ::RuntimeError => e
      # We fall back to "stub" mode: the attach_function calls generate stubs
      # that raise Rpdfium::LoadError on first invocation. This allows the gem
      # to be loaded in order to use the pure-Ruby modules (Edges, Cells, PNG)
      # without having PDFium installed.
      @load_error = e
      ffi_lib_flags :now  # no-op without ffi_lib, but documents intent
    end

    # Tolerant attach_function wrapper: if the binding fails (library
    # not loaded, symbol not present in this version of PDFium),
    # it still generates a method that raises a clear error at the call site,
    # instead of blowing up the `require`.
    def self.attach_function(name, *args)
      super
    rescue FFI::NotFoundError, RuntimeError => e
      define_singleton_method(name) do |*_a|
        raise Rpdfium::LoadError,
              "PDFium symbol #{name} not available: #{e.message}"
      end
    end

    unless @native_loaded
      # Override of attach_function when the library failed to load:
      # do not call super (which would blow up), generate the stub directly.
      def self.attach_function(name, *_args)
        err = @load_error
        define_singleton_method(name) do |*_a|
          raise Rpdfium::LoadError, <<~MSG.strip
            PDFium native library not loaded.
            Set ENV["PDFIUM_LIBRARY_PATH"] to a valid libpdfium.{so,dylib,dll},
            or install the rpdfium-binary gem (when released).
            Original error: #{err.message}
          MSG
        end
      end
    end

    # =========================================================================
    # Opaque types
    # =========================================================================
    typedef :pointer, :FPDF_DOCUMENT
    typedef :pointer, :FPDF_PAGE
    typedef :pointer, :FPDF_TEXTPAGE
    typedef :pointer, :FPDF_BITMAP
    typedef :pointer, :FPDF_PAGEOBJECT
    typedef :pointer, :FPDF_PAGEOBJECTMARK
    typedef :pointer, :FPDF_PATHSEGMENT
    typedef :pointer, :FPDF_FONT
    typedef :pointer, :FPDF_ANNOTATION
    typedef :pointer, :FPDF_FORMHANDLE
    typedef :pointer, :FPDF_BOOKMARK
    typedef :pointer, :FPDF_DEST
    typedef :pointer, :FPDF_ACTION
    typedef :pointer, :FPDF_LINK
    typedef :pointer, :FPDF_GLYPHPATH
    typedef :pointer, :FPDF_SCHHANDLE
    typedef :pointer, :FPDF_ATTACHMENT
    typedef :pointer, :FPDF_STRUCTTREE
    typedef :pointer, :FPDF_STRUCTELEMENT
    typedef :int,     :FPDF_BOOL
    typedef :ushort,  :FPDF_WCHAR

    # =========================================================================
    # C structures
    # =========================================================================
    class FS_RECTF < FFI::Struct
      layout :left,   :float,
             :top,    :float,
             :right,  :float,
             :bottom, :float
    end

    class FS_MATRIX < FFI::Struct
      # PDF matrix: [a b 0; c d 0; e f 1] (row-major in PDF; FFI follows field order)
      layout :a, :float, :b, :float,
             :c, :float, :d, :float,
             :e, :float, :f, :float
    end

    class FS_POINTF < FFI::Struct
      layout :x, :float, :y, :float
    end

    class FS_SIZEF < FFI::Struct
      layout :width, :float, :height, :float
    end

    class FS_QUADPOINTSF < FFI::Struct
      layout :x1, :float, :y1, :float,
             :x2, :float, :y2, :float,
             :x3, :float, :y3, :float,
             :x4, :float, :y4, :float
    end

    class FPDF_IMAGEOBJ_METADATA < FFI::Struct
      layout :width,            :uint,
             :height,           :uint,
             :horizontal_dpi,   :float,
             :vertical_dpi,     :float,
             :bits_per_pixel,   :uint,
             :colorspace,       :int,
             :marked_content_id, :int
    end

    # =========================================================================
    # Constants
    # =========================================================================
    # Bitmap formats
    FPDFBitmap_Unknown = 0
    FPDFBitmap_Gray    = 1
    FPDFBitmap_BGR     = 2
    FPDFBitmap_BGRx    = 3
    FPDFBitmap_BGRA    = 4

    # Render flags (bit fields)
    FPDF_ANNOT          = 0x01
    FPDF_LCD_TEXT       = 0x02
    FPDF_NO_NATIVETEXT  = 0x04
    FPDF_GRAYSCALE      = 0x08
    FPDF_REVERSE_BYTE_ORDER = 0x10  # → RGBA instead of BGRA
    FPDF_NO_GDIPLUS     = 0x40
    FPDF_PRINTING       = 0x800
    FPDF_RENDER_NO_SMOOTHTEXT  = 0x1000
    FPDF_RENDER_NO_SMOOTHIMAGE = 0x2000
    FPDF_RENDER_NO_SMOOTHPATH  = 0x4000

    # Page object types
    PAGEOBJ_UNKNOWN = 0
    PAGEOBJ_TEXT    = 1
    PAGEOBJ_PATH    = 2
    PAGEOBJ_IMAGE   = 3
    PAGEOBJ_SHADING = 4
    PAGEOBJ_FORM    = 5

    # Path segment types
    SEGMENT_UNKNOWN  = -1
    SEGMENT_LINETO   = 0
    SEGMENT_BEZIERTO = 1
    SEGMENT_MOVETO   = 2

    # Path fill mode
    FILLMODE_NONE      = 0
    FILLMODE_ALTERNATE = 1
    FILLMODE_WINDING   = 2

    # Text render modes
    TEXT_RENDERMODE_FILL          = 0
    TEXT_RENDERMODE_STROKE        = 1
    TEXT_RENDERMODE_FILL_STROKE   = 2
    TEXT_RENDERMODE_INVISIBLE     = 3

    # Annotation subtypes (PDF spec 12.5.6)
    FPDF_ANNOT_UNKNOWN          = 0
    FPDF_ANNOT_TEXT             = 1
    FPDF_ANNOT_LINK             = 2
    FPDF_ANNOT_FREETEXT         = 3
    FPDF_ANNOT_LINE             = 4
    FPDF_ANNOT_SQUARE           = 5
    FPDF_ANNOT_CIRCLE           = 6
    FPDF_ANNOT_HIGHLIGHT        = 9
    FPDF_ANNOT_UNDERLINE        = 10
    FPDF_ANNOT_SQUIGGLY         = 11
    FPDF_ANNOT_STRIKEOUT        = 12
    FPDF_ANNOT_STAMP            = 13
    FPDF_ANNOT_INK              = 15
    FPDF_ANNOT_POPUP            = 16
    FPDF_ANNOT_FILEATTACHMENT   = 17
    FPDF_ANNOT_WIDGET           = 20
    FPDF_ANNOT_REDACT           = 27

    ANNOT_SUBTYPE_NAMES = {
      FPDF_ANNOT_TEXT => "Text", FPDF_ANNOT_LINK => "Link",
      FPDF_ANNOT_FREETEXT => "FreeText", FPDF_ANNOT_LINE => "Line",
      FPDF_ANNOT_SQUARE => "Square", FPDF_ANNOT_CIRCLE => "Circle",
      FPDF_ANNOT_HIGHLIGHT => "Highlight", FPDF_ANNOT_UNDERLINE => "Underline",
      FPDF_ANNOT_SQUIGGLY => "Squiggly", FPDF_ANNOT_STRIKEOUT => "StrikeOut",
      FPDF_ANNOT_STAMP => "Stamp", FPDF_ANNOT_INK => "Ink",
      FPDF_ANNOT_POPUP => "Popup",
      FPDF_ANNOT_FILEATTACHMENT => "FileAttachment",
      FPDF_ANNOT_WIDGET => "Widget", FPDF_ANNOT_REDACT => "Redact"
    }.freeze

    # Form field types (for widget annotations)
    FPDF_FORMFIELD_UNKNOWN     = 0
    FPDF_FORMFIELD_PUSHBUTTON  = 1
    FPDF_FORMFIELD_CHECKBOX    = 2
    FPDF_FORMFIELD_RADIOBUTTON = 3
    FPDF_FORMFIELD_COMBOBOX    = 4
    FPDF_FORMFIELD_LISTBOX     = 5
    FPDF_FORMFIELD_TEXTFIELD   = 6
    FPDF_FORMFIELD_SIGNATURE   = 7

    # Search flags
    FPDF_MATCHCASE      = 0x01
    FPDF_MATCHWHOLEWORD = 0x02
    FPDF_CONSECUTIVE    = 0x04

    # Form types (FPDF_GetFormType)
    FORMTYPE_NONE      = 0
    FORMTYPE_ACRO_FORM = 1
    FORMTYPE_XFA_FULL  = 2
    FORMTYPE_XFA_FOREGROUND = 3

    # =========================================================================
    # Library lifecycle
    # =========================================================================
    attach_function :FPDF_InitLibrary,    [], :void
    attach_function :FPDF_DestroyLibrary, [], :void
    attach_function :FPDF_GetLastError,   [], :ulong

    # =========================================================================
    # Document
    # =========================================================================
    attach_function :FPDF_LoadDocument,
                    %i[string string], :FPDF_DOCUMENT
    attach_function :FPDF_LoadMemDocument64,
                    %i[pointer size_t string], :FPDF_DOCUMENT
    attach_function :FPDF_CloseDocument, %i[FPDF_DOCUMENT], :void
    attach_function :FPDF_GetPageCount,  %i[FPDF_DOCUMENT], :int
    attach_function :FPDF_GetDocPermissions, %i[FPDF_DOCUMENT], :ulong
    attach_function :FPDF_GetSecurityHandlerRevision, %i[FPDF_DOCUMENT], :int
    attach_function :FPDF_GetFileVersion,
                    %i[FPDF_DOCUMENT pointer], :FPDF_BOOL
    attach_function :FPDF_GetFormType,   %i[FPDF_DOCUMENT], :int

    # Metadata: FPDF_GetMetaText(doc, "Title"|"Author"|"Subject"|"Keywords"|
    #                            "Creator"|"Producer"|"CreationDate"|"ModDate")
    attach_function :FPDF_GetMetaText,
                    %i[FPDF_DOCUMENT string pointer ulong], :ulong

    # Page label (PDF spec: roman/letter labelling)
    attach_function :FPDF_GetPageLabel,
                    %i[FPDF_DOCUMENT int pointer ulong], :ulong

    # =========================================================================
    # Pages
    # =========================================================================
    attach_function :FPDF_LoadPage,    %i[FPDF_DOCUMENT int], :FPDF_PAGE
    attach_function :FPDF_ClosePage,   %i[FPDF_PAGE], :void
    attach_function :FPDF_GetPageWidthF,   %i[FPDF_PAGE], :float
    attach_function :FPDF_GetPageHeightF,  %i[FPDF_PAGE], :float
    attach_function :FPDF_GetPageBoundingBox,
                    %i[FPDF_PAGE pointer], :FPDF_BOOL
    attach_function :FPDFPage_GetRotation, %i[FPDF_PAGE], :int
    attach_function :FPDFPage_HasTransparency, %i[FPDF_PAGE], :FPDF_BOOL

    # CropBox / MediaBox / BleedBox / TrimBox / ArtBox
    %i[FPDFPage_GetMediaBox FPDFPage_GetCropBox FPDFPage_GetBleedBox
       FPDFPage_GetTrimBox  FPDFPage_GetArtBox].each do |fn|
      attach_function fn, %i[FPDF_PAGE pointer pointer pointer pointer], :FPDF_BOOL
    end

    # =========================================================================
    # Text extraction
    # =========================================================================
    attach_function :FPDFText_LoadPage,    %i[FPDF_PAGE], :FPDF_TEXTPAGE
    attach_function :FPDFText_ClosePage,   %i[FPDF_TEXTPAGE], :void
    attach_function :FPDFText_CountChars,  %i[FPDF_TEXTPAGE], :int
    attach_function :FPDFText_GetUnicode,  %i[FPDF_TEXTPAGE int], :uint
    attach_function :FPDFText_GetFontSize, %i[FPDF_TEXTPAGE int], :double
    attach_function :FPDFText_GetFontWeight, %i[FPDF_TEXTPAGE int], :int
    attach_function :FPDFText_GetFontInfo,
                    %i[FPDF_TEXTPAGE int pointer ulong pointer], :ulong
    # NOTE: FPDFText_GetTextRenderMode(text_page, char_index) was REMOVED
    # from PDFium in chromium/6611 (July 2024). The replacement is two steps:
    #   1. FPDFText_GetTextObject(text_page, char_index) → FPDF_PAGEOBJECT
    #   2. FPDFTextObj_GetTextRenderMode(page_object)    → int
    # High-level wrapper: see Page#chars (the :render_mode field).
    # Reference: pypdfium2 issue #335, pdfium-render issue #151.
    attach_function :FPDFText_GetTextObject,
                    %i[FPDF_TEXTPAGE int], :FPDF_PAGEOBJECT
    attach_function :FPDFText_GetCharBox,
                    %i[FPDF_TEXTPAGE int pointer pointer pointer pointer],
                    :FPDF_BOOL
    # "Loose" char box: bbox proportional to the font size, more stable for layout
    attach_function :FPDFText_GetLooseCharBox,
                    %i[FPDF_TEXTPAGE int pointer], :FPDF_BOOL
    attach_function :FPDFText_GetMatrix,
                    %i[FPDF_TEXTPAGE int pointer], :FPDF_BOOL
    attach_function :FPDFText_GetCharOrigin,
                    %i[FPDF_TEXTPAGE int pointer pointer], :FPDF_BOOL
    attach_function :FPDFText_GetCharAngle,
                    %i[FPDF_TEXTPAGE int], :float
    attach_function :FPDFText_HasUnicodeMapError,
                    %i[FPDF_TEXTPAGE int], :int
    attach_function :FPDFText_IsGenerated, %i[FPDF_TEXTPAGE int], :int
    attach_function :FPDFText_IsHyphen,    %i[FPDF_TEXTPAGE int], :int
    attach_function :FPDFText_GetText,
                    %i[FPDF_TEXTPAGE int int pointer], :int
    attach_function :FPDFText_GetBoundedText,
                    %i[FPDF_TEXTPAGE double double double double pointer int],
                    :int
    attach_function :FPDFText_CountRects,
                    %i[FPDF_TEXTPAGE int int], :int
    attach_function :FPDFText_GetRect,
                    %i[FPDF_TEXTPAGE int pointer pointer pointer pointer],
                    :FPDF_BOOL

    # =========================================================================
    # Search
    # =========================================================================
    attach_function :FPDFText_FindStart,
                    %i[FPDF_TEXTPAGE pointer ulong int], :FPDF_SCHHANDLE
    attach_function :FPDFText_FindNext,    %i[FPDF_SCHHANDLE], :FPDF_BOOL
    attach_function :FPDFText_FindPrev,    %i[FPDF_SCHHANDLE], :FPDF_BOOL
    attach_function :FPDFText_GetSchResultIndex, %i[FPDF_SCHHANDLE], :int
    attach_function :FPDFText_GetSchCount, %i[FPDF_SCHHANDLE], :int
    attach_function :FPDFText_FindClose,   %i[FPDF_SCHHANDLE], :void

    # =========================================================================
    # Bitmap & rendering
    # =========================================================================
    attach_function :FPDFBitmap_Create,     %i[int int int], :FPDF_BITMAP
    attach_function :FPDFBitmap_CreateEx,
                    %i[int int int pointer int], :FPDF_BITMAP
    attach_function :FPDFBitmap_Destroy,    %i[FPDF_BITMAP], :void
    attach_function :FPDFBitmap_FillRect,
                    %i[FPDF_BITMAP int int int int ulong], :void
    attach_function :FPDFBitmap_GetBuffer,  %i[FPDF_BITMAP], :pointer
    attach_function :FPDFBitmap_GetWidth,   %i[FPDF_BITMAP], :int
    attach_function :FPDFBitmap_GetHeight,  %i[FPDF_BITMAP], :int
    attach_function :FPDFBitmap_GetStride,  %i[FPDF_BITMAP], :int
    attach_function :FPDFBitmap_GetFormat,  %i[FPDF_BITMAP], :int
    attach_function :FPDF_RenderPageBitmap,
                    %i[FPDF_BITMAP FPDF_PAGE int int int int int int],
                    :void
    # Rendering with a 2x3 matrix + clipping (for arbitrary scaling/rotation)
    attach_function :FPDF_RenderPageBitmapWithMatrix,
                    %i[FPDF_BITMAP FPDF_PAGE pointer pointer int],
                    :void

    # =========================================================================
    # Page objects (generic)
    # =========================================================================
    attach_function :FPDFPage_CountObjects, %i[FPDF_PAGE], :int
    attach_function :FPDFPage_GetObject,    %i[FPDF_PAGE int], :FPDF_PAGEOBJECT
    attach_function :FPDFPageObj_GetType,   %i[FPDF_PAGEOBJECT], :int
    attach_function :FPDFPageObj_GetBounds,
                    %i[FPDF_PAGEOBJECT pointer pointer pointer pointer],
                    :FPDF_BOOL
    attach_function :FPDFPageObj_GetMatrix,
                    %i[FPDF_PAGEOBJECT pointer], :FPDF_BOOL
    attach_function :FPDFPageObj_GetFillColor,
                    %i[FPDF_PAGEOBJECT pointer pointer pointer pointer],
                    :FPDF_BOOL
    attach_function :FPDFPageObj_GetStrokeColor,
                    %i[FPDF_PAGEOBJECT pointer pointer pointer pointer],
                    :FPDF_BOOL
    attach_function :FPDFPageObj_GetStrokeWidth,
                    %i[FPDF_PAGEOBJECT pointer], :FPDF_BOOL
    attach_function :FPDFPageObj_GetLineCap,   %i[FPDF_PAGEOBJECT], :int
    attach_function :FPDFPageObj_GetLineJoin,  %i[FPDF_PAGEOBJECT], :int

    # =========================================================================
    # Form XObjects: containers that encapsulate graphics (lines, rects, text)
    # as a reusable "graphics subroutine". In PDFs generated by management
    # software (TeamSystem, Zucchetti, ...) and by many Word/Excel templates,
    # the ENTIRE page is a single Form XObject. Without descending into it, no
    # lines/rects/chars are visible. Cf. PDF Spec 1.7 §8.10.
    #
    # After FPDFFormObj_GetObject(form, i) one obtains a child FPDF_PAGEOBJECT
    # whose coordinates are in the form's system. The transformation to the
    # page system is obtained from FPDFPageObj_GetMatrix(form_obj, &matrix).
    # =========================================================================
    attach_function :FPDFFormObj_CountObjects, %i[FPDF_PAGEOBJECT], :int
    attach_function :FPDFFormObj_GetObject,
                    %i[FPDF_PAGEOBJECT ulong], :FPDF_PAGEOBJECT

    # =========================================================================
    # Path segments — fundamental for table line detection
    # =========================================================================
    attach_function :FPDFPath_CountSegments, %i[FPDF_PAGEOBJECT], :int
    attach_function :FPDFPath_GetPathSegment,
                    %i[FPDF_PAGEOBJECT int], :FPDF_PATHSEGMENT
    attach_function :FPDFPath_GetDrawMode,
                    %i[FPDF_PAGEOBJECT pointer pointer], :FPDF_BOOL
    attach_function :FPDFPathSegment_GetPoint,
                    %i[FPDF_PATHSEGMENT pointer pointer], :FPDF_BOOL
    attach_function :FPDFPathSegment_GetType, %i[FPDF_PATHSEGMENT], :int
    attach_function :FPDFPathSegment_GetClose, %i[FPDF_PATHSEGMENT], :FPDF_BOOL

    # =========================================================================
    # Image objects
    # =========================================================================
    attach_function :FPDFImageObj_GetImageMetadata,
                    %i[FPDF_PAGEOBJECT FPDF_PAGE pointer], :FPDF_BOOL
    attach_function :FPDFImageObj_GetImagePixelSize,
                    %i[FPDF_PAGEOBJECT pointer pointer], :FPDF_BOOL
    attach_function :FPDFImageObj_GetBitmap,
                    %i[FPDF_PAGEOBJECT], :FPDF_BITMAP
    attach_function :FPDFImageObj_GetRenderedBitmap,
                    %i[FPDF_DOCUMENT FPDF_PAGE FPDF_PAGEOBJECT], :FPDF_BITMAP
    attach_function :FPDFImageObj_GetImageDataDecoded,
                    %i[FPDF_PAGEOBJECT pointer ulong], :ulong
    attach_function :FPDFImageObj_GetImageDataRaw,
                    %i[FPDF_PAGEOBJECT pointer ulong], :ulong
    attach_function :FPDFImageObj_GetImageFilterCount,
                    %i[FPDF_PAGEOBJECT], :int
    attach_function :FPDFImageObj_GetImageFilter,
                    %i[FPDF_PAGEOBJECT int pointer ulong], :ulong

    # =========================================================================
    # Text page-objects (font name of a text object, glyphs)
    # =========================================================================
    attach_function :FPDFTextObj_GetFontSize,
                    %i[FPDF_PAGEOBJECT pointer], :FPDF_BOOL
    attach_function :FPDFTextObj_GetText,
                    %i[FPDF_PAGEOBJECT FPDF_TEXTPAGE pointer ulong], :ulong
    attach_function :FPDFTextObj_GetFont, %i[FPDF_PAGEOBJECT], :FPDF_FONT
    # FPDFTextObj_GetTextRenderMode is the replacement for the former
    # FPDFText_GetTextRenderMode (removed upstream in chromium/6611).
    # It takes a text PAGEOBJECT, not (textpage, char_index).
    attach_function :FPDFTextObj_GetTextRenderMode, %i[FPDF_PAGEOBJECT], :int
    # NOTE: FPDFFont_GetFontName is marked as legacy in recent PDFium.
    # The new model provides two distinct APIs:
    #   - FPDFFont_GetBaseFontName  → BaseFont entry of the PDF dict (may
    #                                 include subset prefixes such as
    #                                 "ABCDEF+Helvetica")
    #   - FPDFFont_GetFamilyName    → "clean" family name (e.g. "Helvetica")
    # These APIs use `c_size_t` for length/return type instead of
    # `c_ulong`. On PDFium builds <= chromium/6533 they are not present:
    # in that case the `attach_function` stub (in raw.rb) ensures that the
    # call fails with a clear LoadError at the call site, not at require.
    attach_function :FPDFFont_GetBaseFontName,
                    %i[FPDF_FONT pointer size_t], :size_t
    attach_function :FPDFFont_GetFamilyName,
                    %i[FPDF_FONT pointer size_t], :size_t
    # Kept for compatibility with older PDFium builds. On newer builds
    # it may not be present: same stub mechanism.
    attach_function :FPDFFont_GetFontName,
                    %i[FPDF_FONT pointer ulong], :ulong
    attach_function :FPDFFont_GetFlags,    %i[FPDF_FONT pointer], :FPDF_BOOL
    attach_function :FPDFFont_GetWeight,   %i[FPDF_FONT], :int
    attach_function :FPDFFont_GetIsEmbedded, %i[FPDF_FONT], :int
    attach_function :FPDFFont_GetItalicAngle,
                    %i[FPDF_FONT pointer], :FPDF_BOOL

    # Font ascent/descent metrics in font-program units.
    # To obtain the value in page coordinates, multiply by the text object's
    # font_size and then by the CTM scale. Useful for
    # baseline detection and line leading.
    attach_function :FPDFFont_GetAscent,  %i[FPDF_FONT int pointer], :FPDF_BOOL
    attach_function :FPDFFont_GetDescent, %i[FPDF_FONT int pointer], :FPDF_BOOL

    # Nominal width of a glyph in the font program ("advance width").
    # It is the width the PDF declares for that glyph before the kerning
    # applied by the `TJ` operators. In combination with FPDFText_GetMatrix
    # (for the CTM scale), it allows the real advance in page coordinates to
    # be computed. Conceptually equivalent to the advance that pdfminer.six
    # reads directly from the font program.
    #
    # WARNING: the returned value is in "font_size-scaled" units,
    # with font_size passed as a parameter. For most PDFs
    # generated by management software, the font_size is 1.0 and the CTM
    # scales (typically 5×–10× for the final rendering).
    attach_function :FPDFFont_GetGlyphWidth,
                    %i[FPDF_FONT uint float pointer], :FPDF_BOOL

    # NOTE: FPDFText_GetMatrix is already attached above (text page section).
    # In combination with FPDFFont_GetGlyphWidth, it allows the glyph advance
    # in page coordinates to be computed as
    # `glyph_width × |FPDFText_GetMatrix.a|`.

    # =========================================================================
    # Annotations
    # =========================================================================
    attach_function :FPDFPage_GetAnnotCount, %i[FPDF_PAGE], :int
    attach_function :FPDFPage_GetAnnot,
                    %i[FPDF_PAGE int], :FPDF_ANNOTATION
    attach_function :FPDFPage_CloseAnnot, %i[FPDF_ANNOTATION], :void
    attach_function :FPDFAnnot_GetSubtype,
                    %i[FPDF_ANNOTATION], :int
    attach_function :FPDFAnnot_GetRect,
                    %i[FPDF_ANNOTATION pointer], :FPDF_BOOL
    attach_function :FPDFAnnot_GetStringValue,
                    %i[FPDF_ANNOTATION string pointer ulong], :ulong
    attach_function :FPDFAnnot_HasKey,
                    %i[FPDF_ANNOTATION string], :FPDF_BOOL
    attach_function :FPDFAnnot_GetLink,
                    %i[FPDF_ANNOTATION], :FPDF_LINK
    attach_function :FPDFLink_GetURL,
                    %i[FPDF_LINK pointer ulong], :ulong
    attach_function :FPDFAction_GetType,   %i[FPDF_ACTION], :uint
    attach_function :FPDFAction_GetURIPath,
                    %i[FPDF_DOCUMENT FPDF_ACTION pointer ulong], :ulong
    attach_function :FPDFLink_GetAction,   %i[FPDF_LINK], :FPDF_ACTION
    attach_function :FPDFLink_GetDest,     %i[FPDF_DOCUMENT FPDF_LINK], :FPDF_DEST

    # =========================================================================
    # Forms
    # =========================================================================
    # FPDF_FORMFILLINFO is a rich struct (~70 fields in the latest builds).
    # For EXTRACTION alone it is enough to pass a minimal version with version=2
    # and all callbacks null — PDFium tolerates NULL on those not called
    # in read-only mode (no JavaScript, no XFA).
    class FPDF_FORMFILLINFO < FFI::Struct
      # Keep aligned with the public header fpdf_formfill.h. The critical field
      # is `version` — if it is wrong, init fails silently. For read-only use
      # version=2 + all others zero/NULL is enough. We allocate a very
      # generous buffer (256 pointers) to be robust against future extensions
      # of the header.
      layout :version, :int,
             :_callbacks, [:pointer, 256]
    end

    attach_function :FPDFDOC_InitFormFillEnvironment,
                    %i[FPDF_DOCUMENT pointer], :FPDF_FORMHANDLE
    attach_function :FPDFDOC_ExitFormFillEnvironment,
                    %i[FPDF_FORMHANDLE], :void
    attach_function :FPDF_FFLDraw,
                    %i[FPDF_FORMHANDLE FPDF_BITMAP FPDF_PAGE int int int int int int],
                    :void
    attach_function :FPDFAnnot_GetFormFieldType,
                    %i[FPDF_FORMHANDLE FPDF_ANNOTATION], :int
    attach_function :FPDFAnnot_GetFormFieldName,
                    %i[FPDF_FORMHANDLE FPDF_ANNOTATION pointer ulong], :ulong
    attach_function :FPDFAnnot_GetFormFieldValue,
                    %i[FPDF_FORMHANDLE FPDF_ANNOTATION pointer ulong], :ulong
    attach_function :FPDFAnnot_GetFormFieldFlags,
                    %i[FPDF_FORMHANDLE FPDF_ANNOTATION], :int
    attach_function :FPDFAnnot_IsChecked,
                    %i[FPDF_FORMHANDLE FPDF_ANNOTATION], :FPDF_BOOL
    attach_function :FPDFAnnot_GetOptionCount,
                    %i[FPDF_FORMHANDLE FPDF_ANNOTATION], :int
    attach_function :FPDFAnnot_GetOptionLabel,
                    %i[FPDF_FORMHANDLE FPDF_ANNOTATION int pointer ulong], :ulong

    # =========================================================================
    # Bookmarks (outline)
    # =========================================================================
    attach_function :FPDFBookmark_GetFirstChild,
                    %i[FPDF_DOCUMENT FPDF_BOOKMARK], :FPDF_BOOKMARK
    attach_function :FPDFBookmark_GetNextSibling,
                    %i[FPDF_DOCUMENT FPDF_BOOKMARK], :FPDF_BOOKMARK
    attach_function :FPDFBookmark_GetTitle,
                    %i[FPDF_BOOKMARK pointer ulong], :ulong
    attach_function :FPDFBookmark_GetDest,
                    %i[FPDF_DOCUMENT FPDF_BOOKMARK], :FPDF_DEST
    attach_function :FPDFDest_GetDestPageIndex,
                    %i[FPDF_DOCUMENT FPDF_DEST], :int

    # =========================================================================
    # Attachments
    # =========================================================================
    attach_function :FPDFDoc_GetAttachmentCount, %i[FPDF_DOCUMENT], :int
    attach_function :FPDFDoc_GetAttachment,
                    %i[FPDF_DOCUMENT int], :FPDF_ATTACHMENT
    attach_function :FPDFAttachment_GetName,
                    %i[FPDF_ATTACHMENT pointer ulong], :ulong
    attach_function :FPDFAttachment_GetFile,
                    %i[FPDF_ATTACHMENT pointer ulong pointer], :FPDF_BOOL

    # =========================================================================
    # Structure tree (for tagged PDF → robust semantic extraction)
    # =========================================================================
    #
    # For "tagged" PDFs (PDF/UA, exports from Word/LibreOffice/InDesign), the
    # `StructTreeRoot` exposes a logical structure of the document (Document
    # → P, H1, Table, TR, TH, TD, Figure...) independent of the graphical
    # layout. Each element can be linked to the page text via
    # `MarkedContentID`: page objects with the same MCID belong
    # semantically to that element.
    #
    # On NON-tagged PDFs (most Italian management-software output):
    # FPDF_StructTree_GetForPage returns NULL.
    #
    # On "tagged but empty" PDFs (e.g. a Banca d'Italia CR, where the
    # StructTreeRoot exists with 700+ entries but all elements are
    # placeholders without type/MCID): the tree is present but the walk
    # produces empty output. See `Rpdfium::Structure::Tree#empty?`.
    typedef :pointer, :FPDF_STRUCTELEMENT_ATTR
    typedef :pointer, :FPDF_STRUCTELEMENT_ATTR_VALUE

    attach_function :FPDF_StructTree_GetForPage,
                    %i[FPDF_PAGE], :FPDF_STRUCTTREE
    attach_function :FPDF_StructTree_Close, %i[FPDF_STRUCTTREE], :void
    attach_function :FPDF_StructTree_CountChildren,
                    %i[FPDF_STRUCTTREE], :int
    attach_function :FPDF_StructTree_GetChildAtIndex,
                    %i[FPDF_STRUCTTREE int], :FPDF_STRUCTELEMENT

    # Tree navigation
    attach_function :FPDF_StructElement_CountChildren,
                    %i[FPDF_STRUCTELEMENT], :int
    attach_function :FPDF_StructElement_GetChildAtIndex,
                    %i[FPDF_STRUCTELEMENT int], :FPDF_STRUCTELEMENT
    attach_function :FPDF_StructElement_GetParent,
                    %i[FPDF_STRUCTELEMENT], :FPDF_STRUCTELEMENT

    # Element identification
    attach_function :FPDF_StructElement_GetType,
                    %i[FPDF_STRUCTELEMENT pointer ulong], :ulong
    attach_function :FPDF_StructElement_GetObjType,
                    %i[FPDF_STRUCTELEMENT pointer ulong], :ulong
    attach_function :FPDF_StructElement_GetTitle,
                    %i[FPDF_STRUCTELEMENT pointer ulong], :ulong
    attach_function :FPDF_StructElement_GetID,
                    %i[FPDF_STRUCTELEMENT pointer ulong], :ulong
    attach_function :FPDF_StructElement_GetLang,
                    %i[FPDF_STRUCTELEMENT pointer ulong], :ulong

    # "Logical" text overrides (accessibility, ligature resolution)
    attach_function :FPDF_StructElement_GetActualText,
                    %i[FPDF_STRUCTELEMENT pointer ulong], :ulong
    attach_function :FPDF_StructElement_GetAltText,
                    %i[FPDF_STRUCTELEMENT pointer ulong], :ulong
    attach_function :FPDF_StructElement_GetExpansion,
                    %i[FPDF_STRUCTELEMENT pointer ulong], :ulong

    # Marked content IDs (link elements → page objects with the same MCID)
    # GetMarkedContentID returns the first MCID (for back-compat).
    # GetMarkedContentIdCount + IdAtIndex for elements with multiple MCIDs.
    # GetChildMarkedContentID: MCID of the child if it is a direct MCR.
    attach_function :FPDF_StructElement_GetMarkedContentID,
                    %i[FPDF_STRUCTELEMENT], :int
    attach_function :FPDF_StructElement_GetMarkedContentIdCount,
                    %i[FPDF_STRUCTELEMENT], :int
    attach_function :FPDF_StructElement_GetMarkedContentIdAtIndex,
                    %i[FPDF_STRUCTELEMENT int], :int
    attach_function :FPDF_StructElement_GetChildMarkedContentID,
                    %i[FPDF_STRUCTELEMENT int], :int

    # Structural PDF attributes (RowSpan, ColSpan, Scope, Headers, etc.)
    # They live in a sub-API: each element has 0+ attribute objects, each
    # with 0+ key/value pairs.
    attach_function :FPDF_StructElement_GetAttributeCount,
                    %i[FPDF_STRUCTELEMENT], :int
    attach_function :FPDF_StructElement_GetAttributeAtIndex,
                    %i[FPDF_STRUCTELEMENT int], :FPDF_STRUCTELEMENT_ATTR
    attach_function :FPDF_StructElement_GetStringAttribute,
                    %i[FPDF_STRUCTELEMENT string pointer ulong], :ulong

    # Attribute getters: key/value enumeration
    attach_function :FPDF_StructElement_Attr_GetCount,
                    %i[FPDF_STRUCTELEMENT_ATTR], :int
    attach_function :FPDF_StructElement_Attr_GetName,
                    %i[FPDF_STRUCTELEMENT_ATTR int pointer ulong pointer],
                    :FPDF_BOOL
    attach_function :FPDF_StructElement_Attr_GetValue,
                    %i[FPDF_STRUCTELEMENT_ATTR string],
                    :FPDF_STRUCTELEMENT_ATTR_VALUE
    attach_function :FPDF_StructElement_Attr_GetType,
                    %i[FPDF_STRUCTELEMENT_ATTR_VALUE], :int
    attach_function :FPDF_StructElement_Attr_GetBooleanValue,
                    %i[FPDF_STRUCTELEMENT_ATTR_VALUE pointer], :FPDF_BOOL
    attach_function :FPDF_StructElement_Attr_GetNumberValue,
                    %i[FPDF_STRUCTELEMENT_ATTR_VALUE pointer], :FPDF_BOOL
    attach_function :FPDF_StructElement_Attr_GetStringValue,
                    %i[FPDF_STRUCTELEMENT_ATTR_VALUE pointer ulong pointer],
                    :FPDF_BOOL
    attach_function :FPDF_StructElement_Attr_GetBlobValue,
                    %i[FPDF_STRUCTELEMENT_ATTR_VALUE pointer ulong pointer],
                    :FPDF_BOOL
    # Attribute whose value is another array (e.g. Headers, an array of IDs)
    attach_function :FPDF_StructElement_Attr_CountChildren,
                    %i[FPDF_STRUCTELEMENT_ATTR_VALUE], :int
    attach_function :FPDF_StructElement_Attr_GetChildAtIndex,
                    %i[FPDF_STRUCTELEMENT_ATTR_VALUE int],
                    :FPDF_STRUCTELEMENT_ATTR_VALUE

    # =========================================================================
    # Page box geometry — media/crop/bleed/trim/art box
    # =========================================================================
    # Each PDF page has up to 5 rectangular boxes, in bottom-up coordinates:
    #   - media: the complete physical area of the page (always present)
    #   - crop: the visible sub-area (default = media if not specified)
    #   - bleed: usable area for printing with bleed margins (rare)
    #   - trim: final cut area (rare, for pre-press)
    #   - art: area of significant content (rare)
    #
    # In pdfplumber these are exposed as `page.mediabox`, `page.cropbox`, etc.
    # Without access to the cropbox, a PDF extraction library cannot know
    # which is the "visible" area of the page vs the "physical" one.
    # They all return FPDF_BOOL: 0 if the box is not defined.
    attach_function :FPDFPage_GetMediaBox,
                    %i[FPDF_PAGE pointer pointer pointer pointer], :FPDF_BOOL
    attach_function :FPDFPage_GetCropBox,
                    %i[FPDF_PAGE pointer pointer pointer pointer], :FPDF_BOOL
    attach_function :FPDFPage_GetBleedBox,
                    %i[FPDF_PAGE pointer pointer pointer pointer], :FPDF_BOOL
    attach_function :FPDFPage_GetTrimBox,
                    %i[FPDF_PAGE pointer pointer pointer pointer], :FPDF_BOOL
    attach_function :FPDFPage_GetArtBox,
                    %i[FPDF_PAGE pointer pointer pointer pointer], :FPDF_BOOL

    # =========================================================================
    # Page object: state, rotated bounds, dash pattern, marked content
    # =========================================================================
    # `FPDFPageObj_GetIsActive`: some page objects may be "inactive"
    # (e.g. hidden by Optional Content / disabled layers). Without
    # this check, extraction would include non-visible content.
    # Returns 0/1 in *out_active.
    attach_function :FPDFPageObj_GetIsActive,
                    %i[FPDF_PAGEOBJECT pointer], :FPDF_BOOL

    # `FPDFPageObj_GetRotatedBounds`: bbox as 4 points (FS_QUADPOINTSF) for
    # rotated objects. The standard GetBounds returns the AABB (Axis-Aligned
    # Bounding Box), useless for objects at 45°/90°. For vertical or
    # rotated text, this is the "true" bbox.
    attach_function :FPDFPageObj_GetRotatedBounds,
                    %i[FPDF_PAGEOBJECT pointer], :FPDF_BOOL

    # Dash pattern: useful in `line_segments` to filter out dashed
    # guide lines (often used as "non-printing" hints in templates).
    # Dashed lines can confuse table cell detection.
    attach_function :FPDFPageObj_GetDashCount,
                    %i[FPDF_PAGEOBJECT], :int
    attach_function :FPDFPageObj_GetDashArray,
                    %i[FPDF_PAGEOBJECT pointer size_t], :FPDF_BOOL
    attach_function :FPDFPageObj_GetDashPhase,
                    %i[FPDF_PAGEOBJECT pointer], :FPDF_BOOL

    # Marked content (Tagged PDF) — BMC/BDC operators of the content stream.
    # In structured PDFs (PDF/UA, Word→PDF, InDesign export), the operators
    # `/Span BMC ... EMC` or `/Span <</MCID 12>> BDC ... EMC` group
    # chars semantically. For PDFs generated by Italian management software
    # these tags are NOT present; for "tagged" PDFs they are the most reliable
    # way to group tokens.
    attach_function :FPDFPageObj_CountMarks,
                    %i[FPDF_PAGEOBJECT], :int
    attach_function :FPDFPageObj_GetMark,
                    %i[FPDF_PAGEOBJECT ulong], :FPDF_PAGEOBJECTMARK
    attach_function :FPDFPageObj_GetMarkedContentID,
                    %i[FPDF_PAGEOBJECT], :int
    attach_function :FPDFPageObjMark_GetName,
                    %i[FPDF_PAGEOBJECTMARK pointer ulong pointer], :FPDF_BOOL
    attach_function :FPDFPageObjMark_CountParams,
                    %i[FPDF_PAGEOBJECTMARK], :int
    attach_function :FPDFPageObjMark_GetParamKey,
                    %i[FPDF_PAGEOBJECTMARK ulong pointer ulong pointer],
                    :FPDF_BOOL
    attach_function :FPDFPageObjMark_GetParamValueType,
                    %i[FPDF_PAGEOBJECTMARK string], :int
    attach_function :FPDFPageObjMark_GetParamIntValue,
                    %i[FPDF_PAGEOBJECTMARK string pointer], :FPDF_BOOL
    attach_function :FPDFPageObjMark_GetParamStringValue,
                    %i[FPDF_PAGEOBJECTMARK string pointer ulong pointer],
                    :FPDF_BOOL

    # =========================================================================
    # Catalog / Document metadata
    # =========================================================================
    # FPDFCatalog_GetLanguage: language declared by the document (e.g. "it-IT").
    # Useful for extraction pipelines that want to switch language-specific
    # rules (e.g. word tokenizer, hyphen lookup).
    attach_function :FPDFCatalog_GetLanguage,
                    %i[FPDF_DOCUMENT pointer ulong], :ulong

    # FPDFDoc_GetPageMode: PDF open state (e.g. PageMode.UseOutlines,
    # PageMode.FullScreen). Numeric. Useful for PDF editor/viewer building.
    attach_function :FPDFDoc_GetPageMode, %i[FPDF_DOCUMENT], :int

    # =========================================================================
    # Links (Link annotation and LinkAtPoint for coordinate-based lookup)
    # =========================================================================
    # `FPDFLink_GetLinkAtPoint`: given (x, y) in page coordinates, returns
    # the link annotation that contains it. The core of "click handling"
    # in viewers / OCR-style "extract links". Pdfplumber exposes something
    # similar via `page.hyperlinks`.
    attach_function :FPDFLink_GetLinkAtPoint,
                    %i[FPDF_PAGE double double], :FPDF_LINK
    attach_function :FPDFLink_GetLinkZOrderAtPoint,
                    %i[FPDF_PAGE double double], :int
    attach_function :FPDFLink_GetAnnot,
                    %i[FPDF_PAGE FPDF_LINK], :FPDF_ANNOTATION
    attach_function :FPDFLink_GetAnnotRect,
                    %i[FPDF_LINK pointer], :FPDF_BOOL
    # FPDFLink_GetTextRange: range of char_index in the text page corresponding
    # to the link. Allows mapping hyperlink → page text.
    attach_function :FPDFLink_GetTextRange,
                    %i[FPDF_LINK pointer pointer], :FPDF_BOOL
    # Rect and QuadPoints: link geometry (rectangle or quadrilateral for
    # links that span multiple lines).
    attach_function :FPDFLink_GetRect,
                    %i[FPDF_LINK int pointer], :FPDF_BOOL
    attach_function :FPDFLink_GetQuadPoints,
                    %i[FPDF_LINK int pointer], :FPDF_BOOL

    # =========================================================================
    # Action / Destination (outline + link extensions)
    # =========================================================================
    # FPDFAction_GetDest: for "GoTo"-type actions, returns the FPDF_DEST.
    # FPDFAction_GetFilePath: for "Launch" or "RemoteGoTo" actions, the path of
    # the target external file.
    attach_function :FPDFAction_GetDest,
                    %i[FPDF_DOCUMENT FPDF_ACTION], :FPDF_DEST
    attach_function :FPDFAction_GetFilePath,
                    %i[FPDF_ACTION pointer ulong], :ulong
    # FPDFBookmark_GetAction: action associated with a bookmark (alternative to
    # GetDest if the bookmark is an action instead of a destination).
    attach_function :FPDFBookmark_GetAction,
                    %i[FPDF_BOOKMARK], :FPDF_ACTION
    # FPDFBookmark_GetCount: number of sub-bookmarks (positive = expanded,
    # negative = collapsed, 0 = leaf).
    attach_function :FPDFBookmark_GetCount,
                    %i[FPDF_BOOKMARK], :int
    # FPDFDest_GetView: view type (Fit, FitH, XYZ, etc.) + parameters.
    # FPDFDest_GetLocationInPage: x/y/zoom extracted from the dest.
    attach_function :FPDFDest_GetView,
                    %i[FPDF_DEST pointer pointer], :ulong
    attach_function :FPDFDest_GetLocationInPage,
                    %i[FPDF_DEST pointer pointer pointer pointer pointer pointer],
                    :FPDF_BOOL

    # =========================================================================
    # Font extras: GetFontData, GetAscent, GetDescent
    # =========================================================================
    # Already attached above: FPDFFont_GetGlyphWidth.
    # We add: FontData (raw font program bytes — useful for inspection,
    # embedding debugging, font substitution) and GetGlyphPath (vector path of
    # a glyph, an alternative to GlyphWidth for exotic fonts).
    # GetFontData follows the bool convention: it returns `out_buflen` if buf is NULL.
    attach_function :FPDFFont_GetFontData,
                    %i[FPDF_FONT pointer size_t pointer], :FPDF_BOOL
    attach_function :FPDFFont_GetGlyphPath,
                    %i[FPDF_FONT uint float], :FPDF_GLYPHPATH
    # FPDF_GLYPHPATH: handle to a path. Added as a typedef.
    # Its GlyphPath_* APIs are niche, but we expose them for symmetry.
    attach_function :FPDFGlyphPath_CountGlyphSegments,
                    %i[FPDF_GLYPHPATH], :int
    attach_function :FPDFGlyphPath_GetGlyphPathSegment,
                    %i[FPDF_GLYPHPATH int], :FPDF_PATHSEGMENT

    # =========================================================================
    # Text page: char index at position
    # =========================================================================
    # FPDFText_GetCharIndexAtPos: given a point (x, y) in page coordinates,
    # returns the index of the nearest char (within tolerance). Useful for
    # "hit test" in viewers and for mapping coord → text index during search.
    attach_function :FPDFText_GetCharIndexAtPos,
                    %i[FPDF_TEXTPAGE double double double double], :int
    # FPDFText_GetTextIndexFromCharIndex / GetCharIndexFromTextIndex:
    # map the "char" index (per glyph) to the "text" index (per logical
    # codepoint). The two indices differ due to ligatures/substitutions.
    attach_function :FPDFText_GetTextIndexFromCharIndex,
                    %i[FPDF_TEXTPAGE int], :int
    attach_function :FPDFText_GetCharIndexFromTextIndex,
                    %i[FPDF_TEXTPAGE int], :int

    # =========================================================================
    # Annotation extras: GetFlags, GetColor, GetBorder, AP, attachment points
    # =========================================================================
    # FPDFAnnot_GetFlags: bitmask of Flags (Hidden, Print, NoZoom, etc.).
    # Without this, we cannot distinguish a visible annotation from one
    # with the Hidden flag.
    attach_function :FPDFAnnot_GetFlags, %i[FPDF_ANNOTATION], :int
    # Color: stroke (BORDER_COLOR) and fill (INTERIOR_COLOR).
    attach_function :FPDFAnnot_GetColor,
                    %i[FPDF_ANNOTATION int pointer pointer pointer pointer],
                    :FPDF_BOOL
    # Border: thickness, horizontal/vertical radius, dash array count.
    attach_function :FPDFAnnot_GetBorder,
                    %i[FPDF_ANNOTATION pointer pointer pointer], :FPDF_BOOL
    # AP (Appearance Stream): rendered form of the annotation in various
    # modes (Normal/Rollover/Down).
    attach_function :FPDFAnnot_GetAP,
                    %i[FPDF_ANNOTATION int pointer ulong], :ulong
    # FileAttachment: for annotations of subtype FileAttachment, obtains
    # the FPDF_ATTACHMENT.
    attach_function :FPDFAnnot_GetFileAttachment,
                    %i[FPDF_ANNOTATION], :FPDF_ATTACHMENT
    # AttachmentPoints: for highlight/markup spanning multiple lines,
    # the 4 points of each quadrilateral.
    attach_function :FPDFAnnot_CountAttachmentPoints,
                    %i[FPDF_ANNOTATION], :size_t
    attach_function :FPDFAnnot_GetAttachmentPoints,
                    %i[FPDF_ANNOTATION size_t pointer], :FPDF_BOOL

    # =========================================================================
    # Attachment extras
    # =========================================================================
    # FPDFAttachment_GetSubtype: MIME-like subtype of the attached file.
    attach_function :FPDFAttachment_GetSubtype,
                    %i[FPDF_ATTACHMENT pointer ulong], :ulong
    # FPDFAttachment_GetStringValue/HasKey: to read the custom metadata
    # of the file attachment (Description, CreationDate, etc.).
    attach_function :FPDFAttachment_HasKey,
                    %i[FPDF_ATTACHMENT string], :FPDF_BOOL
    attach_function :FPDFAttachment_GetValueType,
                    %i[FPDF_ATTACHMENT string], :int
    attach_function :FPDFAttachment_GetStringValue,
                    %i[FPDF_ATTACHMENT string pointer ulong], :ulong

    # =========================================================================
    # Helper: reading UTF-16LE strings that PDFium returns as bytes
    # =========================================================================
    # PDFium convention: most Get*Text/Get*Name calls return
    # `unsigned long` (number of BYTES, terminator included). It is called
    # first with a NULL/0 buffer to obtain the size, then with an allocated buffer.
    def self.read_utf16_string(method_name, *args)
      args_probe = args + [FFI::Pointer::NULL, 0]
      n_bytes = send(method_name, *args_probe)
      return "" if n_bytes <= 2 # only the null terminator or an error

      buf = FFI::MemoryPointer.new(:uchar, n_bytes)
      args_real = args + [buf, n_bytes]
      send(method_name, *args_real)
      utf16_bytes_to_utf8(buf.read_bytes(n_bytes))
    end

    # Same two-call convention, but for the few APIs that return 7-bit
    # ASCII bytes instead of UTF-16LE (e.g. FPDFAction_GetURIPath).
    def self.read_ascii_string(method_name, *args)
      args_probe = args + [FFI::Pointer::NULL, 0]
      n_bytes = send(method_name, *args_probe)
      return "" if n_bytes <= 1 # only the null terminator or an error

      buf = FFI::MemoryPointer.new(:uchar, n_bytes)
      args_real = args + [buf, n_bytes]
      send(method_name, *args_real)
      buf.read_bytes(n_bytes).delete("\x00").force_encoding("UTF-8")
    end

    # PDFium returns little-endian UTF-16LE with a null terminator.
    def self.utf16_bytes_to_utf8(bytes)
      bytes.force_encoding("UTF-16LE")
           .encode("UTF-8", invalid: :replace, undef: :replace)
           .delete("\x00")
    end
  end
end
