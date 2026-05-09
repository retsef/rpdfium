# frozen_string_literal: true

module Rpdfium
  module Form
    # FPDF_FORMHANDLE è necessario per leggere widget annotations.
    # In modalità read-only basta inizializzarlo con una FORMFILLINFO minimale
    # (version=2, callbacks NULL). PDFium chiama i callback solo durante
    # interazione utente o JavaScript, che noi non usiamo.
    class Environment
      attr_reader :handle, :document

      def initialize(document)
        @document = document

        info = Raw::FPDF_FORMFILLINFO.new
        info[:version] = 2

        # Tutti i puntatori restano NULL (default di FFI::Struct).
        handle = Raw.FPDFDOC_InitFormFillEnvironment(document.handle, @info)
        if handle.null?
          raise FormError,
                "FPDFDOC_InitFormFillEnvironment failed (form_type=#{document.form_type})"
        end

        @state = { handle: handle, closed: false, info: info }
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

      def info
        @state[:info]
      end

      def closed?
        @state[:closed]
      end

      def close
        return if closed?

        Raw.FPDFDOC_ExitFormFillEnvironment(handle)

        @state[:handle] = FFI::Pointer::NULL
        @state[:closed] = true
        @state[:info] = nil

        ObjectSpace.undefine_finalizer(self)
      end
    end

    # Wrapper per un widget di form. Si costruisce a partire da
    # un'annotazione di tipo :widget e l'env del documento.
    class Field
      TYPES = {
        Raw::FPDF_FORMFIELD_UNKNOWN     => :unknown,
        Raw::FPDF_FORMFIELD_PUSHBUTTON  => :pushbutton,
        Raw::FPDF_FORMFIELD_CHECKBOX    => :checkbox,
        Raw::FPDF_FORMFIELD_RADIOBUTTON => :radiobutton,
        Raw::FPDF_FORMFIELD_COMBOBOX    => :combobox,
        Raw::FPDF_FORMFIELD_LISTBOX     => :listbox,
        Raw::FPDF_FORMFIELD_TEXTFIELD   => :textfield,
        Raw::FPDF_FORMFIELD_SIGNATURE   => :signature
      }.freeze

      attr_reader :env, :annotation

      def initialize(env, annotation)
        @env = env
        @annotation = annotation
      end

      def type
        TYPES[Raw.FPDFAnnot_GetFormFieldType(@env.handle, @annotation.handle)] || :unknown
      end

      def name
        Raw.read_utf16_string(:FPDFAnnot_GetFormFieldName, @env.handle, @annotation.handle)
      end

      def value
        Raw.read_utf16_string(:FPDFAnnot_GetFormFieldValue, @env.handle, @annotation.handle)
      end

      def flags
        Raw.FPDFAnnot_GetFormFieldFlags(@env.handle, @annotation.handle)
      end

      # PDF spec §12.7.4.1: bit 1=read-only, bit 2=required, bit 3=no-export
      def readonly?; (flags & (1 << 0)).positive?; end
      def required?; (flags & (1 << 1)).positive?; end

      # Per checkbox e radio
      def checked?
        return false unless %i[checkbox radiobutton].include?(type)

        Raw.FPDFAnnot_IsChecked(@env.handle, @annotation.handle) == 1
      end

      # Per combobox/listbox
      def options
        n = Raw.FPDFAnnot_GetOptionCount(@env.handle, @annotation.handle)
        return [] if n <= 0

        Array.new(n) do |i|
          Raw.read_utf16_string(:FPDFAnnot_GetOptionLabel,
                                @env.handle, @annotation.handle, i)
        end
      end

      def to_h
        {
          name: name, type: type, value: value,
          readonly: readonly?, required: required?,
          checked: (%i[checkbox radiobutton].include?(type) ? checked? : nil),
          options: (%i[combobox listbox].include?(type) ? options : nil),
          bbox: @annotation.bbox
        }.compact
      end
    end
  end
end
