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

    attr_reader :handle, :source

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

      # Stato condiviso tra istanza e finalizer. Lo wrappiamo in un Hash
      # così la closure del finalizer e il metodo close vedono lo stesso
      # mutable state — il finalizer non chiude un handle già chiuso.
      @state = {
        handle:        handle,
        retain_buffer: retain_buffer,
        closed:        false
      }
      @form_env = nil
      @page_cache = {}

      # ATTENZIONE: il finalizer NON deve chiudere altri Ruby objects
      # (es. pages cached o form_env), perché potrebbero essere già stati
      # finalizzati dal GC in ordine non deterministico. Il finalizer è
      # un best-effort di ultima istanza: chiude SOLO l'handle nativo,
      # e SOLO se il close esplicito non è già stato chiamato.
      ObjectSpace.define_finalizer(self, self.class.finalizer(@state))
    end

    # IMPORTANTE: questa proc deve essere un *class method* o un
    # `lambda` definito FUORI dall'instance scope. Se la chiusura cattura
    # `self`, il GC non potrà MAI raccogliere il Document — definirebbe
    # un riferimento permanente.
    def self.finalizer(state)
      proc do
        next if state[:closed]
        next if state[:handle].null?

        Raw.FPDF_CloseDocument(state[:handle])
        state[:closed] = true
        # retain_buffer va tenuto vivo finché PDFium tiene il Document.
        # Una volta chiuso, può essere rilasciato (ma è già nella state hash,
        # quindi viene comunque liberato quando il finalizer esce).
      end
    end

    def handle
      @state[:handle]
    end

    # ===== Pages =====

    def page_count
      ensure_open!
      Raw.FPDF_GetPageCount(handle)
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
      Raw.read_utf16_string(:FPDF_GetPageLabel, handle, index)
    end

    # ===== Metadata =====

    def metadata
      META_KEYS.each_with_object({}) do |key, h|
        v = Raw.read_utf16_string(:FPDF_GetMetaText, handle, key)
        h[key.downcase.to_sym] = v unless v.empty?
      end
    end

    def file_version
      buf = FFI::MemoryPointer.new(:int)
      return nil if Raw.FPDF_GetFileVersion(handle, buf) == 0

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
      bits = Raw.FPDF_GetDocPermissions(handle)
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
      FORM_TYPES[Raw.FPDF_GetFormType(handle)] || :unknown
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
      n = Raw.FPDFDoc_GetAttachmentCount(handle)
      Array.new(n) { |i| Attachment.new(self, i) }
    end

    # ===== Close =====

    def close
      return if closed?

      # Ordine corretto: prima chiudi tutto ciò che dipende dal documento,
      # poi il documento stesso. Questo è il path "manuale": la cascata
      # è sotto il nostro controllo, non in mano al GC.
      @form_env&.close
      @page_cache.each_value(&:close)
      @page_cache.clear

      Raw.FPDF_CloseDocument(handle)
      @state[:handle] = FFI::Pointer::NULL
      @state[:retain_buffer] = nil
      @state[:closed] = true

      # Disarma il finalizer: non c'è più nulla da chiudere, evitiamo
      # qualsiasi possibilità di doppia chiamata via GC.
      ObjectSpace.undefine_finalizer(self)
    end

    def closed?
      @state[:closed]
    end

    private

    def ensure_open!
      raise Error, "Document is closed" if closed?
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
