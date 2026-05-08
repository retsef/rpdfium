# frozen_string_literal: true

require "ffi"

module Rpdfium
  # Layer 1: bindings FFI grezzi alle API C di PDFium.
  # Mappa 1:1 con i nomi originali. Usare le classi wrapper per il codice
  # applicativo. Le API "Experimental" di PDFium sono marcate nei commenti:
  # in teoria potrebbero cambiare, in pratica sono stabili da anni.
  module Raw
    extend FFI::Library

    def self.candidate_paths
      paths = []
      paths << ENV["PDFIUM_LIBRARY_PATH"] if ENV["PDFIUM_LIBRARY_PATH"]
      if defined?(Rpdfium::Binary) && Rpdfium::Binary.respond_to?(:library_path)
        paths << Rpdfium::Binary.library_path
      end
      paths.concat(%w[pdfium libpdfium libpdfium.so libpdfium.dylib pdfium.dll])
      paths.compact
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

    if !@native_loaded
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
    attach_function :FPDFText_GetTextRenderMode,
                    %i[FPDF_TEXTPAGE int], :int
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
    attach_function :FPDFTextObj_GetTextRenderMode, %i[FPDF_PAGEOBJECT], :int
    attach_function :FPDFFont_GetFontName,
                    %i[FPDF_FONT pointer ulong], :ulong
    attach_function :FPDFFont_GetFlags,    %i[FPDF_FONT pointer], :FPDF_BOOL
    attach_function :FPDFFont_GetWeight,   %i[FPDF_FONT], :int
    attach_function :FPDFFont_GetIsEmbedded, %i[FPDF_FONT], :int
    attach_function :FPDFFont_GetItalicAngle,
                    %i[FPDF_FONT pointer], :FPDF_BOOL

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
