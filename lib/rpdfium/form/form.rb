# frozen_string_literal: true

module Rpdfium
  module Form
    # FPDF_FORMHANDLE is required to read widget annotations.
    # In read-only mode it is enough to initialize it with a minimal FORMFILLINFO
    # (version=2, callbacks NULL). PDFium invokes the callbacks only during
    # user interaction or JavaScript, which we do not use.
    class Environment
      attr_reader :document

      def initialize(document)
        @document = document
        @info = Raw::FPDF_FORMFILLINFO.new
        @info[:version] = 2
        # All pointers remain NULL (the FFI::Struct default).
        handle = Raw.FPDFDOC_InitFormFillEnvironment(document.handle, @info)
        if handle.null?
          raise FormError,
                "FPDFDOC_InitFormFillEnvironment failed (form_type=#{document.form_type})"
        end
        @state = { handle: handle, closed: false }
        ObjectSpace.define_finalizer(self, self.class.finalizer(@state))
      end

      def self.finalizer(state)
        proc do
          next if state[:closed]
          next if state[:handle].null?

          Raw.FPDFDOC_ExitFormFillEnvironment(state[:handle])
          state[:closed] = true
        end
      end

      def handle
        @state[:handle]
      end

      def close
        return if @state[:closed]

        Raw.FPDFDOC_ExitFormFillEnvironment(@state[:handle]) unless @state[:handle].null?
        @state[:handle] = FFI::Pointer::NULL
        @info = nil
        @state[:closed] = true
        ObjectSpace.undefine_finalizer(self)
      end
    end

    # Wrapper for a form widget. It is built from
    # an annotation of type :widget and the document env.
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

      # For checkbox and radio
      def checked?
        return false unless %i[checkbox radiobutton].include?(type)

        Raw.FPDFAnnot_IsChecked(@env.handle, @annotation.handle) == 1
      end

      # For combobox/listbox
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
