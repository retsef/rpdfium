# frozen_string_literal: true

require_relative "rpdfium/version"
require_relative "rpdfium/errors"

# Loads the companion gem rpdfium-binary if present: this must happen BEFORE
# raw.rb, which calls ffi_lib at require time and queries
# Rpdfium::Binary.library_path to find the absolute path to the .so/.dylib.
begin
  require "rpdfium/binary"
rescue LoadError
  nil
end

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
require_relative "rpdfium/util/word_merger"
require_relative "rpdfium/util/column_inference"
require_relative "rpdfium/util/label_matcher"

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

  # Extract all the text of all pages, one string per page.
  def self.extract_text(input, password: nil)
    open(input, password: password) do |doc|
      doc.each_page_streaming.map(&:text)
    end
  end

  # Extract all the tables of all pages.
  # Returns Array<{ page: Integer, rows: Array<Array<String>> }>.
  #
  # `keep_blank_rows: false` (default) removes the completely empty rows
  # that the `:text` strategy of words_to_edges_h generates by construction (each
  # visual row produces two edges, top + bottom, and between pairs of adjacent
  # edges "spurious rows" form, with a height equal to the line gap).
  # With `keep_blank_rows: true` you get the raw output of Table#extract.
  def self.extract_tables(input, password: nil, keep_blank_rows: false, **opts)
    open(input, password: password) do |doc|
      doc.each_page_streaming.flat_map do |page|
        Table::Extractor.new(page, **opts).extract.map do |rows|
          rows = rows.reject { |r| r.all? { |c| c.nil? || c.empty? } } unless keep_blank_rows
          { page: page.index, rows: rows }
        end
      end
    end
  end

  # Render each page to a PNG inside output_dir.
  def self.render_to_pngs(input, output_dir:, scale: 2.0, password: nil)
    Dir.mkdir(output_dir) unless Dir.exist?(output_dir)
    open(input, password: password) do |doc|
      doc.each_page_streaming.map do |page|
        path = File.join(output_dir, format("page_%04d.png", page.index + 1))
        page.render_to_png(path, scale: scale)
        path
      end
    end
  end
end
