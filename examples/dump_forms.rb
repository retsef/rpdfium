# frozen_string_literal: true

# Lista i form fields di un PDF AcroForm in JSON.
#
# Uso: ruby dump_forms.rb form.pdf

require "rpdfium"
require "json"

input = ARGV[0] or abort "Usage: ruby dump_forms.rb form.pdf"

Rpdfium.open(input) do |doc|
  unless doc.has_forms?
    warn "No forms in this document (form_type=#{doc.form_type})"
    exit 1
  end

  fields = doc.flat_map.with_index do |page, page_idx|
    page.form_fields.map { |f| f.to_h.merge(page: page_idx + 1) }
  end

  puts JSON.pretty_generate(fields)
end
