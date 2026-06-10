# frozen_string_literal: true

module Rpdfium
  # Document-level wrapper. Exposes:
  # - opening from path / IO / bytes / page by index
  # - metadata (Title, Author, etc.)
  # - permissions
  # - outline (bookmarks)
  # - attachments
  # - form environment (lazy)
  class Document
    include Enumerable

    META_KEYS = %w[Title Author Subject Keywords Creator Producer
                   CreationDate ModDate Trapped].freeze

    attr_reader :source

    def self.open(input, password: nil, &block)
      doc = new(input, password: password)
      return doc unless block_given?

      begin
        yield doc
      ensure
        doc.close
      end
    end

    def initialize(input, password: nil)
      Rpdfium.init!
      @password = password
      @source   = input
      handle, retain_buffer = load_handle(input, password)
      if handle.null?
        code = Rpdfium.last_error_code
        msg  = Rpdfium.last_error_message
        raise PasswordError, msg if code == 4

        raise LoadError, "Failed to load PDF: #{msg}"
      end
      # State shared between the instance and the finalizer. Wrapped in a
      # mutable Hash because the finalizer closure and the explicit
      # close() must see the same :closed flag — otherwise whichever
      # arrives second calls FPDF_CloseDocument on an already-freed
      # handle and PDFium segfaults.
      @state = {
        handle: handle,
        retain_buffer: retain_buffer,
        closed: false
      }
      @form_env = nil
      @page_cache = {}
      # IMPORTANT: the finalizer captures @state (Hash), NOT self.
      # Capturing self would prevent the GC from collecting the Document.
      # Moreover the finalizer does NOT touch @page_cache: Pages have
      # their own individual finalizer, and the execution order among
      # finalizers is non-deterministic in Ruby.
      ObjectSpace.define_finalizer(self, self.class.finalizer(@state))
    end

    def self.finalizer(state)
      proc do
        next if state[:closed]
        next if state[:handle].null?

        Raw.FPDF_CloseDocument(state[:handle])
        state[:closed] = true
        state[:retain_buffer] = nil
      end
    end

    def handle
      @state[:handle]
    end

    # ===== Pages =====

    def page_count
      ensure_open!
      Raw.FPDF_GetPageCount(@state[:handle])
    end
    alias size page_count
    alias length page_count

    def page(index)
      ensure_open!
      raise PageError, "Page index #{index} out of range" unless (0...page_count).cover?(index)

      # Pages are cacheable: reloading them is expensive and the objects
      # are immutable from the application's point of view (in read-only
      # mode).
      @page_cache[index] ||= Page.new(self, index)
    end
    alias [] page

    def each
      return enum_for(:each) unless block_given?

      page_count.times { |i| yield page(i) }
    end

    def page_label(index)
      Raw.read_utf16_string(:FPDF_GetPageLabel, @state[:handle], index)
    end

    # ===== Metadata =====

    def metadata
      META_KEYS.each_with_object({}) do |key, h|
        v = Raw.read_utf16_string(:FPDF_GetMetaText, @state[:handle], key)
        h[key.downcase.to_sym] = v unless v.empty?
      end
    end

    def file_version
      buf = FFI::MemoryPointer.new(:int)
      return nil if Raw.FPDF_GetFileVersion(@state[:handle], buf) == 0

      v = buf.read_int
      # PDFium returns 14 → 1.4, 17 → 1.7
      "#{v / 10}.#{v % 10}"
    end

    # Permission bits according to the PDF spec (Table 22 §7.6.3.2)
    PERMISSIONS = {
      print:       1 << 2,
      modify:      1 << 3,
      copy:        1 << 4,
      annotate:    1 << 5,
      fill_forms:  1 << 8,
      extract_acc: 1 << 9,
      assemble:    1 << 10,
      print_hq:    1 << 11
    }.freeze

    def permissions
      bits = Raw.FPDF_GetDocPermissions(@state[:handle])
      PERMISSIONS.transform_values { |mask| (bits & mask) == mask }
    end

    # ===== Form type =====

    FORM_TYPES = {
      Raw::FORMTYPE_NONE      => :none,
      Raw::FORMTYPE_ACRO_FORM => :acroform,
      Raw::FORMTYPE_XFA_FULL  => :xfa_full,
      Raw::FORMTYPE_XFA_FOREGROUND => :xfa_foreground
    }.freeze

    def form_type
      FORM_TYPES[Raw.FPDF_GetFormType(@state[:handle])] || :unknown
    end

    def has_forms?
      form_type != :none
    end

    # Lazy form environment. Required to:
    # - read FormFieldType/Value/Name on widget annotations
    # - render the form fields over the page (FFLDraw)
    def form_env
      @form_env ||= Form::Environment.new(self) if has_forms?
    end

    # ===== Outline =====

    def outline
      Outline.from_document(self)
    end

    # ===== Attachments =====

    def attachments
      n = Raw.FPDFDoc_GetAttachmentCount(@state[:handle])
      Array.new(n) { |i| Attachment.new(self, i) }
    end

    # ===== Close =====

    def close
      return if @state[:closed]

      # Order: close form env and cached pages first, then the document.
      @form_env&.close
      @page_cache.each_value(&:close)
      @page_cache.clear
      Raw.FPDF_CloseDocument(@state[:handle]) unless @state[:handle].null?
      @state[:handle] = FFI::Pointer::NULL
      @state[:retain_buffer] = nil
      @state[:closed] = true
      ObjectSpace.undefine_finalizer(self)
    end

    def closed?
      @state[:closed]
    end

    private

    def ensure_open!
      raise Error, "Document is closed" if @state[:closed]
    end

    def load_handle(input, password)
      case input
      when String
        if File.file?(input)
          [Raw.FPDF_LoadDocument(input, password), nil]
        else
          load_from_bytes(input, password)
        end
      when IO, StringIO
        load_from_bytes(input.read, password)
      else
        raise ArgumentError, "Unsupported input: #{input.class}"
      end
    end

    def load_from_bytes(bytes, password)
      # CRITICAL: PDFium does NOT copy the bytes — it references them. We
      # must keep the buffer alive for the entire life of the document.
      buf = FFI::MemoryPointer.new(:uchar, bytes.bytesize)
      buf.put_bytes(0, bytes)
      [Raw.FPDF_LoadMemDocument64(buf, bytes.bytesize, password), buf]
    end
  end
end
