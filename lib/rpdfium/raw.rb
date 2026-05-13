# frozen_string_literal: true

require "ffi"
require "rbconfig"

module Rpdfium
  # Layer 1: bindings FFI grezzi alle API C di PDFium.
  # Mappa 1:1 con i nomi originali. Usare le classi wrapper per il codice
  # applicativo. Le API "Experimental" di PDFium sono marcate nei commenti:
  # in teoria potrebbero cambiare, in pratica sono stabili da anni.
  module Raw
    extend FFI::Library

    # Costruisce la lista di candidati che `ffi_lib` proverà in ordine.
    #
    # ATTENZIONE: FFI auto-appende l'estensione "naturale" della piattaforma
    # (.dylib su macOS, .so su linux, .dll su windows) quando il path passato
    # non termina già con un'estensione conosciuta. Quindi se passiamo
    # `libpdfium.so` su macOS, FFI cerca `libpdfium.so.dylib` — assurdo ma
    # documentato. Per evitarlo, filtriamo i nomi system_library_names per
    # OS host.
    #
    # Inoltre: ENV["PDFIUM_LIBRARY_PATH"] e Rpdfium::Binary.library_path sono
    # path ASSOLUTI/ESPLICITI: se non vengono trovati, NON facciamo fallback
    # a nomi di sistema. Restituiamo subito un array di un solo path: in
    # quel caso ffi_lib o riesce subito, o lancia LoadError chiaro
    # (è ciò che vuole l'utente — gli ha dato un path esplicito).
    def self.candidate_paths
      explicit = ENV["PDFIUM_LIBRARY_PATH"]
      return [explicit] if explicit && !explicit.empty?

      if defined?(Rpdfium::Binary) && Rpdfium::Binary.respond_to?(:library_path)
        path = Rpdfium::Binary.library_path
        return [path] if path && !path.empty?
      end

      system_library_names
    end

    # Nomi "di sistema" filtrati per OS host. Manteniamo `pdfium` /
    # `libpdfium` (senza estensione) per primi: FFI auto-appende l'ext giusta.
    # I nomi con estensione vengono SOLO se matchano l'OS host, così evitiamo
    # il bug di doppia estensione.
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
      ffi_convention :default # cdecl ovunque, anche su Win64 (build bblanchon)
      @native_loaded = true
    rescue ::LoadError, ::RuntimeError => e
      # Cadiamo in modalità "stub": le attach_function generano stub che
      # sollevano Rpdfium::LoadError alla prima invocazione. Permette di
      # caricare la gemma per usare i moduli puri-Ruby (Edges, Cells, PNG)
      # senza dover avere PDFium installato.
      @load_error = e
      ffi_lib_flags :now  # no-op senza ffi_lib, ma documenta intent
    end

    # Wrap di attach_function tollerante: se il binding fallisce (libreria
    # non caricata, simbolo non presente in questa versione di PDFium),
    # genera comunque un metodo che alza un errore chiaro al call site,
    # invece di far esplodere il `require`.
    def self.attach_function(name, *args)
      super
    rescue FFI::NotFoundError, RuntimeError => e
      define_singleton_method(name) do |*_a|
        raise Rpdfium::LoadError,
              "PDFium symbol #{name} not available: #{e.message}"
      end
    end

    unless @native_loaded
      # Override di attach_function quando la libreria non si è caricata:
      # non chiamare super (che esploderebbe), genera direttamente lo stub.
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
    # Tipi opachi
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
    # Strutture C
    # =========================================================================
    class FS_RECTF < FFI::Struct
      layout :left,   :float,
             :top,    :float,
             :right,  :float,
             :bottom, :float
    end

    class FS_MATRIX < FFI::Struct
      # PDF matrix: [a b 0; c d 0; e f 1] (row-major in PDF; FFI segue ordine campi)
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
    # Costanti
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
    FPDF_REVERSE_BYTE_ORDER = 0x10  # → RGBA invece di BGRA
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

    # Form field types (per widget annotations)
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
    # NOTE: FPDFText_GetTextRenderMode(text_page, char_index) è stato RIMOSSO
    # da PDFium in chromium/6611 (luglio 2024). Il rimpiazzo è in due passi:
    #   1. FPDFText_GetTextObject(text_page, char_index) → FPDF_PAGEOBJECT
    #   2. FPDFTextObj_GetTextRenderMode(page_object)    → int
    # Wrapper di alto livello: vedi Page#chars (campo :render_mode).
    # Riferimento: pypdfium2 issue #335, pdfium-render issue #151.
    attach_function :FPDFText_GetTextObject,
                    %i[FPDF_TEXTPAGE int], :FPDF_PAGEOBJECT
    attach_function :FPDFText_GetCharBox,
                    %i[FPDF_TEXTPAGE int pointer pointer pointer pointer],
                    :FPDF_BOOL
    # "Loose" char box: bbox proporzionale alla font size, più stabile per layout
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
    # Rendering con matrice 2x3 + clipping (per scaling/rotation arbitraria)
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
    # Form XObjects: contenitori che incapsulano grafica (linee, rect, testo)
    # come "subroutine grafica" riutilizzabile. Nei PDF generati da gestionali
    # (TeamSystem, Zucchetti, ...) e da molti template Word/Excel, l'INTERA
    # pagina è un singolo Form XObject. Senza discendervi dentro, non si
    # vedono linee/rect/chars. Cf. PDF Spec 1.7 §8.10.
    #
    # Dopo FPDFFormObj_GetObject(form, i) si ottiene un FPDF_PAGEOBJECT child
    # le cui coordinate sono nel sistema del form. La trasformazione al
    # sistema-pagina si ottiene da FPDFPageObj_GetMatrix(form_obj, &matrix).
    # =========================================================================
    attach_function :FPDFFormObj_CountObjects, %i[FPDF_PAGEOBJECT], :int
    attach_function :FPDFFormObj_GetObject,
                    %i[FPDF_PAGEOBJECT ulong], :FPDF_PAGEOBJECT

    # =========================================================================
    # Path segments — fondamentali per detection linee tabella
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
    # Text page-objects (font name di un text object, glifi)
    # =========================================================================
    attach_function :FPDFTextObj_GetFontSize,
                    %i[FPDF_PAGEOBJECT pointer], :FPDF_BOOL
    attach_function :FPDFTextObj_GetText,
                    %i[FPDF_PAGEOBJECT FPDF_TEXTPAGE pointer ulong], :ulong
    attach_function :FPDFTextObj_GetFont, %i[FPDF_PAGEOBJECT], :FPDF_FONT
    # FPDFTextObj_GetTextRenderMode è il rimpiazzo dell'ex
    # FPDFText_GetTextRenderMode (rimossa upstream in chromium/6611).
    # Prende un text PAGEOBJECT, non (textpage, char_index).
    attach_function :FPDFTextObj_GetTextRenderMode, %i[FPDF_PAGEOBJECT], :int
    # NOTE: FPDFFont_GetFontName è marcata come legacy in PDFium recenti.
    # Il modello nuovo prevede due API distinte:
    #   - FPDFFont_GetBaseFontName  → BaseFont entry del PDF dict (può
    #                                 includere prefissi di subset come
    #                                 "ABCDEF+Helvetica")
    #   - FPDFFont_GetFamilyName    → nome famiglia "pulito" (es. "Helvetica")
    # Queste API usano `c_size_t` per lunghezza/return type invece di
    # `c_ulong`. Su build di PDFium <= chromium/6533 non sono presenti:
    # in tal caso lo stub `attach_function` (in raw.rb) assicura che la
    # chiamata fallisca con LoadError chiaro al call site, non al require.
    attach_function :FPDFFont_GetBaseFontName,
                    %i[FPDF_FONT pointer size_t], :size_t
    attach_function :FPDFFont_GetFamilyName,
                    %i[FPDF_FONT pointer size_t], :size_t
    # Mantenuta per compatibilità con build PDFium più vecchi. Su build
    # nuovi può non essere presente: stesso meccanismo di stub.
    attach_function :FPDFFont_GetFontName,
                    %i[FPDF_FONT pointer ulong], :ulong
    attach_function :FPDFFont_GetFlags,    %i[FPDF_FONT pointer], :FPDF_BOOL
    attach_function :FPDFFont_GetWeight,   %i[FPDF_FONT], :int
    attach_function :FPDFFont_GetIsEmbedded, %i[FPDF_FONT], :int
    attach_function :FPDFFont_GetItalicAngle,
                    %i[FPDF_FONT pointer], :FPDF_BOOL

    # Metriche font ascendente/discendente in unità del font program.
    # Per ottenere il valore in coordinate pagina serve moltiplicare per
    # font_size del text object e poi per la scala del CTM. Utili per
    # baseline detection e leading di linee.
    attach_function :FPDFFont_GetAscent,  %i[FPDF_FONT int pointer], :FPDF_BOOL
    attach_function :FPDFFont_GetDescent, %i[FPDF_FONT int pointer], :FPDF_BOOL

    # Larghezza nominale di un glifo nel font program ("advance width").
    # È la larghezza che il PDF dichiara per quel glifo prima del kerning
    # applicato dagli operatori `TJ`. In combinazione con FPDFText_GetMatrix
    # (per la scala del CTM), permette di calcolare l'advance reale in
    # coordinate pagina. Equivale concettualmente all'advance che pdfminer.six
    # legge dal font program direttamente.
    #
    # ATTENZIONE: il valore ritornato è in unità "scalate per font_size",
    # con font_size passato come parametro. Per la maggior parte dei PDF
    # generati da gestionali, il font_size è 1.0 e il CTM scala
    # (tipicamente 5×–10× per il rendering finale).
    attach_function :FPDFFont_GetGlyphWidth,
                    %i[FPDF_FONT uint float pointer], :FPDF_BOOL

    # NOTA: FPDFText_GetMatrix è già attaccata sopra (sezione text page).
    # In combinazione con FPDFFont_GetGlyphWidth, permette di calcolare
    # l'advance del glifo in coordinate pagina come
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
    # FPDF_FORMFILLINFO è una struct ricca (~70 campi negli ultimi build).
    # Per la sola ESTRAZIONE basta passare una versione minima con version=2
    # e tutti i callback nulli — PDFium tollera NULL su quelli non chiamati
    # in modalità read-only (no JavaScript, no XFA).
    class FPDF_FORMFILLINFO < FFI::Struct
      # Tieni allineato all'header pubblico fpdf_formfill.h. Il campo critico è
      # `version` — se sbagli, init fallisce silenziosamente. Per uso read-only
      # basta version=2 + tutti gli altri zero/NULL. Allochiamo un buffer molto
      # generoso (256 puntatori) per essere robusti a future estensioni
      # dell'header.
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
    # Structure tree (per PDF tagged → estrazione semantica robusta)
    # =========================================================================
    attach_function :FPDF_StructTree_GetForPage,
                    %i[FPDF_PAGE], :FPDF_STRUCTTREE
    attach_function :FPDF_StructTree_Close, %i[FPDF_STRUCTTREE], :void
    attach_function :FPDF_StructTree_CountChildren,
                    %i[FPDF_STRUCTTREE], :int
    attach_function :FPDF_StructTree_GetChildAtIndex,
                    %i[FPDF_STRUCTTREE int], :FPDF_STRUCTELEMENT
    attach_function :FPDF_StructElement_CountChildren,
                    %i[FPDF_STRUCTELEMENT], :int
    attach_function :FPDF_StructElement_GetChildAtIndex,
                    %i[FPDF_STRUCTELEMENT int], :FPDF_STRUCTELEMENT
    attach_function :FPDF_StructElement_GetType,
                    %i[FPDF_STRUCTELEMENT pointer ulong], :ulong
    attach_function :FPDF_StructElement_GetTitle,
                    %i[FPDF_STRUCTELEMENT pointer ulong], :ulong

    # =========================================================================
    # Page box geometry — media/crop/bleed/trim/art box
    # =========================================================================
    # Ogni pagina PDF ha fino a 5 box rettangolari, in coordinate bottom-up:
    #   - media: l'area fisica completa della pagina (sempre presente)
    #   - crop: la sotto-area visibile (default = media se non specificata)
    #   - bleed: area utile per stampa con marginatura (rare)
    #   - trim: area finale di taglio (rare, per pre-stampa)
    #   - art: area di contenuto significativo (rare)
    #
    # In pdfplumber sono esposte come `page.mediabox`, `page.cropbox`, ecc.
    # Senza accesso a cropbox, una libreria di estrazione PDF non può sapere
    # qual è l'area "visibile" della pagina vs quella "fisica".
    # Tutte ritornano FPDF_BOOL: 0 se il box non è definito.
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
    # Page object: stato, bounds rotati, dash pattern, marked content
    # =========================================================================
    # `FPDFPageObj_GetIsActive`: alcuni page object possono essere "inattivi"
    # (es. nascosti da Optional Content / livelli disabilitati). Senza
    # questo check, l'estrazione includerebbe contenuto non visibile.
    # Restituisce 0/1 in *out_active.
    attach_function :FPDFPageObj_GetIsActive,
                    %i[FPDF_PAGEOBJECT pointer], :FPDF_BOOL

    # `FPDFPageObj_GetRotatedBounds`: bbox in 4 punti (FS_QUADPOINTSF) per
    # oggetti ruotati. La GetBounds standard ritorna l'AABB (Axis-Aligned
    # Bounding Box), inutile per oggetti a 45°/90°. Per testo verticale o
    # ruotato, questo è il bbox "vero".
    attach_function :FPDFPageObj_GetRotatedBounds,
                    %i[FPDF_PAGEOBJECT pointer], :FPDF_BOOL

    # Dash pattern: utile in `line_segments` per filtrare linee guida
    # tratteggiate (spesso usate come "non-printing" hints nei template).
    # Le linee dashed possono confondere la detection cellule tabelle.
    attach_function :FPDFPageObj_GetDashCount,
                    %i[FPDF_PAGEOBJECT], :int
    attach_function :FPDFPageObj_GetDashArray,
                    %i[FPDF_PAGEOBJECT pointer size_t], :FPDF_BOOL
    attach_function :FPDFPageObj_GetDashPhase,
                    %i[FPDF_PAGEOBJECT pointer], :FPDF_BOOL

    # Marked content (Tagged PDF) — operatori BMC/BDC del content stream.
    # In PDF strutturati (PDF/UA, Word→PDF, InDesign export), gli operatori
    # `/Span BMC ... EMC` o `/Span <</MCID 12>> BDC ... EMC` raggruppano
    # semanticamente i char. Per PDF generati da gestionali italiani questi
    # tag NON sono presenti; per PDF "tagged" sono il modo più affidabile
    # di raggruppare token.
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
    # FPDFCatalog_GetLanguage: lingua dichiarata dal documento (es. "it-IT").
    # Utile per pipeline di estrazione che vogliono switchare regole
    # language-specific (es. tokenizer di parole, lookup hyphen).
    attach_function :FPDFCatalog_GetLanguage,
                    %i[FPDF_DOCUMENT pointer ulong], :ulong

    # FPDFDoc_GetPageMode: stato di apertura PDF (es. PageMode.UseOutlines,
    # PageMode.FullScreen). Numeric. Utile per editor PDF/viewer building.
    attach_function :FPDFDoc_GetPageMode, %i[FPDF_DOCUMENT], :int

    # =========================================================================
    # Links (annotation Link e LinkAtPoint per ricerca per coordinata)
    # =========================================================================
    # `FPDFLink_GetLinkAtPoint`: dato (x, y) in coordinate pagina, ritorna
    # il link annotation che lo contiene. Cuore della funzione "click handling"
    # in viewer / OCR-style "extract links". Pdfplumber espone simile via
    # `page.hyperlinks`.
    attach_function :FPDFLink_GetLinkAtPoint,
                    %i[FPDF_PAGE double double], :FPDF_LINK
    attach_function :FPDFLink_GetLinkZOrderAtPoint,
                    %i[FPDF_PAGE double double], :int
    attach_function :FPDFLink_GetAnnot,
                    %i[FPDF_PAGE FPDF_LINK], :FPDF_ANNOTATION
    attach_function :FPDFLink_GetAnnotRect,
                    %i[FPDF_LINK pointer], :FPDF_BOOL
    # FPDFLink_GetTextRange: range di char_index nella text page corrispondenti
    # al link. Permette di mappare hyperlink → testo della pagina.
    attach_function :FPDFLink_GetTextRange,
                    %i[FPDF_LINK pointer pointer], :FPDF_BOOL
    # Rect e QuadPoints: geometria del link (rectangle o quadrilatero per
    # link che attraversano più righe).
    attach_function :FPDFLink_GetRect,
                    %i[FPDF_LINK int pointer], :FPDF_BOOL
    attach_function :FPDFLink_GetQuadPoints,
                    %i[FPDF_LINK int pointer], :FPDF_BOOL

    # =========================================================================
    # Action / Destination (estensioni outline + link)
    # =========================================================================
    # FPDFAction_GetDest: per action di tipo "GoTo", ritorna il FPDF_DEST.
    # FPDFAction_GetFilePath: per action "Launch" o "RemoteGoTo", path del file
    # esterno target.
    attach_function :FPDFAction_GetDest,
                    %i[FPDF_DOCUMENT FPDF_ACTION], :FPDF_DEST
    attach_function :FPDFAction_GetFilePath,
                    %i[FPDF_ACTION pointer ulong], :ulong
    # FPDFBookmark_GetAction: action associata a un bookmark (alternativa a
    # GetDest se il bookmark è un'action invece di una destinazione).
    attach_function :FPDFBookmark_GetAction,
                    %i[FPDF_BOOKMARK], :FPDF_ACTION
    # FPDFBookmark_GetCount: numero di sub-bookmark (positivo = espansi,
    # negativo = collassati, 0 = leaf).
    attach_function :FPDFBookmark_GetCount,
                    %i[FPDF_BOOKMARK], :int
    # FPDFDest_GetView: tipo di view (Fit, FitH, XYZ ecc.) + parametri.
    # FPDFDest_GetLocationInPage: x/y/zoom estratti dal dest.
    attach_function :FPDFDest_GetView,
                    %i[FPDF_DEST pointer pointer], :ulong
    attach_function :FPDFDest_GetLocationInPage,
                    %i[FPDF_DEST pointer pointer pointer pointer pointer pointer],
                    :FPDF_BOOL

    # =========================================================================
    # Font extras: GetFontData, GetAscent, GetDescent
    # =========================================================================
    # Già attaccate sopra: FPDFFont_GetGlyphWidth.
    # Aggiungiamo: FontData (raw font program bytes — utile per inspection,
    # debug embedding, font substitution) e GetGlyphPath (path vettoriale di
    # un glifo, alternativa a GlyphWidth per font esotici).
    # GetFontData ha la convention bool: ritorna `out_buflen` se buf è NULL.
    attach_function :FPDFFont_GetFontData,
                    %i[FPDF_FONT pointer size_t pointer], :FPDF_BOOL
    attach_function :FPDFFont_GetGlyphPath,
                    %i[FPDF_FONT uint float], :FPDF_GLYPHPATH
    # FPDF_GLYPHPATH: handle a un path. Lo aggiungo come typedef.
    # Le sue API GlyphPath_* sono niche, ma le esponiamo per simmetria.
    attach_function :FPDFGlyphPath_CountGlyphSegments,
                    %i[FPDF_GLYPHPATH], :int
    attach_function :FPDFGlyphPath_GetGlyphPathSegment,
                    %i[FPDF_GLYPHPATH int], :FPDF_PATHSEGMENT

    # =========================================================================
    # Text page: char index at position
    # =========================================================================
    # FPDFText_GetCharIndexAtPos: dato un punto (x, y) in coord pagina,
    # ritorna l'indice del char più vicino (entro tolerance). Utile per
    # "hit test" in viewer e per mapping coord → text index nella ricerca.
    attach_function :FPDFText_GetCharIndexAtPos,
                    %i[FPDF_TEXTPAGE double double double double], :int
    # FPDFText_GetTextIndexFromCharIndex / GetCharIndexFromTextIndex:
    # mappano l'indice "char" (per glifo) all'indice "text" (per codepoint
    # logico). I due indici differiscono per ligature/sostituzioni.
    attach_function :FPDFText_GetTextIndexFromCharIndex,
                    %i[FPDF_TEXTPAGE int], :int
    attach_function :FPDFText_GetCharIndexFromTextIndex,
                    %i[FPDF_TEXTPAGE int], :int

    # =========================================================================
    # Annotation extras: GetFlags, GetColor, GetBorder, AP, attachment points
    # =========================================================================
    # FPDFAnnot_GetFlags: bitmask di Flags (Hidden, Print, NoZoom ecc.).
    # Senza questo, non possiamo distinguere un annotation visibile da uno
    # con flag Hidden.
    attach_function :FPDFAnnot_GetFlags, %i[FPDF_ANNOTATION], :int
    # Colore: stroke (BORDER_COLOR) e fill (INTERIOR_COLOR).
    attach_function :FPDFAnnot_GetColor,
                    %i[FPDF_ANNOTATION int pointer pointer pointer pointer],
                    :FPDF_BOOL
    # Border: spessore, raggio orizzontale/verticale, dash array count.
    attach_function :FPDFAnnot_GetBorder,
                    %i[FPDF_ANNOTATION pointer pointer pointer], :FPDF_BOOL
    # AP (Appearance Stream): forma renderizzata dell'annotation in vari
    # modi (Normal/Rollover/Down).
    attach_function :FPDFAnnot_GetAP,
                    %i[FPDF_ANNOTATION int pointer ulong], :ulong
    # FileAttachment: per Annotation di sottotipo FileAttachment, ottiene
    # l'FPDF_ATTACHMENT.
    attach_function :FPDFAnnot_GetFileAttachment,
                    %i[FPDF_ANNOTATION], :FPDF_ATTACHMENT
    # AttachmentPoints: per highlight/markup che attraversano più righe,
    # i 4 punti di ogni quadrilatero.
    attach_function :FPDFAnnot_CountAttachmentPoints,
                    %i[FPDF_ANNOTATION], :size_t
    attach_function :FPDFAnnot_GetAttachmentPoints,
                    %i[FPDF_ANNOTATION size_t pointer], :FPDF_BOOL

    # =========================================================================
    # Attachment extras
    # =========================================================================
    # FPDFAttachment_GetSubtype: MIME-like subtype del file allegato.
    attach_function :FPDFAttachment_GetSubtype,
                    %i[FPDF_ATTACHMENT pointer ulong], :ulong
    # FPDFAttachment_GetStringValue/HasKey: per leggere i metadati custom
    # del file attachment (Description, CreationDate, ecc.).
    attach_function :FPDFAttachment_HasKey,
                    %i[FPDF_ATTACHMENT string], :FPDF_BOOL
    attach_function :FPDFAttachment_GetValueType,
                    %i[FPDF_ATTACHMENT string], :int
    attach_function :FPDFAttachment_GetStringValue,
                    %i[FPDF_ATTACHMENT string pointer ulong], :ulong

    # =========================================================================
    # Helper: leggere stringhe UTF-16LE che PDFium ritorna in bytes
    # =========================================================================
    # Convenzione PDFium: la maggior parte delle Get*Text/Get*Name ritornano
    # `unsigned long` (numero BYTES, terminatore incluso). Si chiama prima con
    # buffer NULL/0 per ottenere la dimensione, poi con buffer allocato.
    def self.read_utf16_string(method_name, *args)
      args_probe = args + [FFI::Pointer::NULL, 0]
      n_bytes = send(method_name, *args_probe)
      return "" if n_bytes <= 2 # solo terminatore null o errore

      buf = FFI::MemoryPointer.new(:uchar, n_bytes)
      args_real = args + [buf, n_bytes]
      send(method_name, *args_real)
      utf16_bytes_to_utf8(buf.read_bytes(n_bytes))
    end

    # PDFium ritorna UTF-16LE little-endian con terminatore null.
    def self.utf16_bytes_to_utf8(bytes)
      bytes.force_encoding("UTF-16LE")
           .encode("UTF-8", invalid: :replace, undef: :replace)
           .delete("\x00")
    end
  end
end
