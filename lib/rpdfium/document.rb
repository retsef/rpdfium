# frozen_string_literal: true

module Rpdfium
  # Wrapper di livello documento. Espone:
  # - apertura da path / IO / bytes / pagina by index
  # - metadata (Title, Author, ecc.)
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
      # Stato condiviso tra istanza e finalizer. Wrappato in Hash mutabile
      # perché la closure del finalizer e il close() esplicito devono vedere
      # lo stesso :closed flag — altrimenti chi arriva secondo richiama
      # FPDF_CloseDocument su un handle già liberato e PDFium segfaulta.
      @state = {
        handle: handle,
        retain_buffer: retain_buffer,
        closed: false
      }
      @form_env = nil
      @page_cache = {}
      # IMPORTANTE: il finalizer cattura @state (Hash), NON self. Catturare
      # self impedirebbe al GC di raccogliere il Document. Inoltre il
      # finalizer NON tocca @page_cache: le Page hanno il loro finalizer
      # individuale, e l'ordine di esecuzione tra finalizer è non
      # deterministico in Ruby.
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

      # Le pagine sono cacheable: ricaricarle è costoso e gli oggetti sono
      # immutabili dal punto di vista applicativo (in modalità read-only).
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
      # PDFium ritorna 14 → 1.4, 17 → 1.7
      "#{v / 10}.#{v % 10}"
    end

    # Permission bits secondo PDF spec (Table 22 §7.6.3.2)
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

    # Lazy form environment. Necessario per:
    # - leggere FormFieldType/Value/Name su widget annotations
    # - renderizzare i form fields sopra la pagina (FFLDraw)
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

      # Ordine: chiudi prima form env e pagine cached, poi documento.
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
      # CRITICO: PDFium NON copia i bytes — li referenzia. Dobbiamo tenere
      # vivo il buffer per tutta la vita del documento.
      buf = FFI::MemoryPointer.new(:uchar, bytes.bytesize)
      buf.put_bytes(0, bytes)
      [Raw.FPDF_LoadMemDocument64(buf, bytes.bytesize, password), buf]
    end
  end
end
