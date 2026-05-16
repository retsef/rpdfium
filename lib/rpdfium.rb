# frozen_string_literal: true

require_relative "rpdfium/version"
require_relative "rpdfium/errors"
require_relative "rpdfium/raw"

require_relative "rpdfium/io/png"

require_relative "rpdfium/structure/outline"
require_relative "rpdfium/structure/attachment"
require_relative "rpdfium/structure/element"
require_relative "rpdfium/structure/tree"

require_relative "rpdfium/image/embedded"
require_relative "rpdfium/annotation/annotation"
require_relative "rpdfium/form/form"
require_relative "rpdfium/search/search"

require_relative "rpdfium/document"
require_relative "rpdfium/page"

require_relative "rpdfium/util/cluster"
require_relative "rpdfium/util/word_extractor"
require_relative "rpdfium/util/text_extraction"

require_relative "rpdfium/table/edges"
require_relative "rpdfium/table/cells"
require_relative "rpdfium/table/table"
require_relative "rpdfium/table/extractor"
require_relative "rpdfium/table/debugger"

# rpdfium - Ruby bindings to PDFium with table extraction.
#
# Top-level API:
#   Rpdfium.open(path_or_io_or_bytes) { |doc| ... }
#   Rpdfium.extract_text(path)
#   Rpdfium.extract_tables(path)
#   Rpdfium.render_to_pngs(path, output_dir:)
module Rpdfium
  def self.open(input, password: nil, &block)
    Document.open(input, password: password, &block)
  end

  # Estrai tutto il testo di tutte le pagine, una stringa per pagina.
  def self.extract_text(input, password: nil)
    open(input, password: password) { |doc| doc.map(&:text) }
  end

  # Estrai tutte le tabelle di tutte le pagine.
  # Ritorna Array<{ page: Integer, rows: Array<Array<String>> }>.
  #
  # `keep_blank_rows: false` (default) elimina le righe completamente vuote
  # che la strategia `:text` di words_to_edges_h genera per costruzione (ogni
  # riga visiva produce due edges, top + bottom, e tra coppie di edges
  # adiacenti si formano "righe spurie" di altezza pari al gap interlinea).
  # Con `keep_blank_rows: true` ottieni l'output grezzo di Table#extract.
  def self.extract_tables(input, password: nil, keep_blank_rows: false, **opts)
    open(input, password: password) do |doc|
      doc.flat_map do |page|
        Table::Extractor.new(page, **opts).extract.map do |rows|
          rows = rows.reject { |r| r.all? { |c| c.nil? || c.empty? } } unless keep_blank_rows
          { page: page.index, rows: rows }
        end
      end
    end
  end

  # Renderizza ogni pagina in un PNG dentro output_dir.
  def self.render_to_pngs(input, output_dir:, scale: 2.0, password: nil)
    Dir.mkdir(output_dir) unless Dir.exist?(output_dir)
    open(input, password: password) do |doc|
      doc.map do |page|
        path = File.join(output_dir, format("page_%04d.png", page.index + 1))
        page.render_to_png(path, scale: scale)
        path
      end
    end
  end
end
