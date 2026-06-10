# frozen_string_literal: true

module Rpdfium
  # Wrapper for FPDF_ANNOTATION. Annotations include links, highlights,
  # comments, form widgets. PDFium requires closing each handle with
  # FPDFPage_CloseAnnot, handled here via a finalizer.
  class Annotation
    SUBTYPES = {
      Raw::FPDF_ANNOT_UNKNOWN => :unknown,
      Raw::FPDF_ANNOT_TEXT => :text,
      Raw::FPDF_ANNOT_LINK => :link,
      Raw::FPDF_ANNOT_FREETEXT => :free_text,
      Raw::FPDF_ANNOT_LINE => :line,
      Raw::FPDF_ANNOT_SQUARE => :square,
      Raw::FPDF_ANNOT_CIRCLE => :circle,
      Raw::FPDF_ANNOT_HIGHLIGHT => :highlight,
      Raw::FPDF_ANNOT_UNDERLINE => :underline,
      Raw::FPDF_ANNOT_SQUIGGLY => :squiggly,
      Raw::FPDF_ANNOT_STRIKEOUT => :strikeout,
      Raw::FPDF_ANNOT_STAMP => :stamp,
      Raw::FPDF_ANNOT_INK => :ink,
      Raw::FPDF_ANNOT_POPUP => :popup,
      Raw::FPDF_ANNOT_FILEATTACHMENT => :file_attachment,
      Raw::FPDF_ANNOT_WIDGET => :widget,
      Raw::FPDF_ANNOT_REDACT => :redact
    }.freeze

    attr_reader :page, :index

    def initialize(page, index)
      @page   = page
      @index  = index
      handle  = Raw.FPDFPage_GetAnnot(page.handle, index)
      raise Error, "Could not load annotation #{index}" if handle.null?

      @state = { handle: handle, closed: false }
      ObjectSpace.define_finalizer(self, self.class.finalizer(@state))
    end

    def self.finalizer(state)
      proc do
        next if state[:closed]
        next if state[:handle].null?

        Raw.FPDFPage_CloseAnnot(state[:handle])
        state[:closed] = true
      end
    end

    def handle
      @state[:handle]
    end

    def subtype
      SUBTYPES[Raw.FPDFAnnot_GetSubtype(@state[:handle])] || :unknown
    end

    def bbox
      rect = Raw::FS_RECTF.new
      return nil if Raw.FPDFAnnot_GetRect(@state[:handle], rect) == 0

      h = @page.height
      { x0: rect[:left], x1: rect[:right],
        top: h - rect[:top], bottom: h - rect[:bottom] }
    end

    # Value of a key in the annotation dict (UTF-16LE).
    # Common keys: "Contents" (annotation text), "T" (author),
    # "M" (mod date), "NM" (uniq name).
    def [](key)
      Raw.read_utf16_string(:FPDFAnnot_GetStringValue, @state[:handle], key.to_s)
    end

    def has_key?(key)
      Raw.FPDFAnnot_HasKey(@state[:handle], key.to_s) == 1
    end

    # For :link annotations → destination URL (if external) or nil.
    def link_uri
      return nil unless subtype == :link

      link_handle = Raw.FPDFAnnot_GetLink(@state[:handle])
      return nil if link_handle.null?

      action = Raw.FPDFLink_GetAction(link_handle)
      return nil if action.null?

      Raw.read_utf16_string(:FPDFAction_GetURIPath, @page.document.handle, action)
    end

    # For internal links → destination page index, or nil.
    def link_dest_page
      return nil unless subtype == :link

      link_handle = Raw.FPDFAnnot_GetLink(@state[:handle])
      return nil if link_handle.null?

      dest = Raw.FPDFLink_GetDest(@page.document.handle, link_handle)
      return nil if dest.null?

      idx = Raw.FPDFDest_GetDestPageIndex(@page.document.handle, dest)
      idx >= 0 ? idx : nil
    end

    def close
      return if @state[:closed]

      Raw.FPDFPage_CloseAnnot(@state[:handle]) unless @state[:handle].null?
      @state[:handle] = FFI::Pointer::NULL
      @state[:closed] = true
      ObjectSpace.undefine_finalizer(self)
    end
  end
end
