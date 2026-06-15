# frozen_string_literal: true

require "spec_helper"

# Stub di Page sufficiente per testare Extractor senza PDFium nativo.
class FakePage
  attr_reader :width, :height, :horizontal_lines, :vertical_lines

  def initialize(chars: [], horizontal_lines: [], vertical_lines: [],
                 width: 595.0, height: 842.0)
    @chars = chars
    @horizontal_lines = horizontal_lines
    @vertical_lines = vertical_lines
    @width = width
    @height = height
  end

  # Mirrors Page#chars' signature so the Extractor/Table pipeline can call
  # it with lean:/geometry: keywords. The stub ignores them and returns the
  # canned chars.
  def chars(loose: true, inject_spaces: true, lean: false, geometry: false)
    @chars
  end
end

RSpec.describe Rpdfium::Table::Extractor do
  # Generatore: costruisce char per una griglia "tabellare" semplice.
  # Ogni riga ha N celle, ognuna con una "parola" composta da `text`.
  def make_chars_grid(rows:, cols_x0:, top_step: 20.0, char_width: 5.0)
    chars = []
    rows.each_with_index do |row, ri|
      top = 100.0 + ri * top_step
      row.each_with_index do |word_text, ci|
        x0 = cols_x0[ci]
        word_text.chars.each_with_index do |c, k|
          chars << {
            char: c, codepoint: c.ord,
            x0: x0 + k * char_width, x1: x0 + (k + 1) * char_width,
            top: top, bottom: top + 10.0,
            generated: false
          }
        end
      end
    end
    chars
  end

  describe "with :text strategy on a clean grid" do
    let(:chars) do
      make_chars_grid(
        rows: [
          %w[A1 B1 C1],
          %w[A2 B2 C2],
          %w[A3 B3 C3],
          %w[A4 B4 C4]
        ],
        cols_x0: [50, 200, 350]
      )
    end

    it "finds the table and extracts the right rows × cols" do
      page = FakePage.new(chars: chars)
      ext = described_class.new(page,
        vertical_strategy: :text, horizontal_strategy: :text,
        min_words_vertical: 3, min_words_horizontal: 1,
        snap_tolerance: 1.0, intersection_tolerance: 3.0,
        edge_min_length: 1.0, auto_fallback: false
      )
      tables = ext.tables
      expect(tables.size).to eq(1)

      data = tables.first.extract
      # NOTA: words_to_edges_h emette DUE edges per riga (top + bottom), che
      # è il comportamento di pdfplumber. Ne consegue che tra ogni coppia di
      # righe "vere" c'è una riga "vuota" generata dalla coppia top-N/top-(N+1).
      # Le righe "vere" sono ai posti pari (0, 2, 4, 6).
      expect(data.size).to be >= 7
      expect(data[0].map(&:strip)).to eq(%w[A1 B1 C1])
      expect(data[2].map(&:strip)).to eq(%w[A2 B2 C2])
      expect(data[4].map(&:strip)).to eq(%w[A3 B3 C3])
    end
  end

  describe "validation" do
    it "raises on invalid strategy" do
      page = FakePage.new
      expect {
        described_class.new(page, vertical_strategy: :foo)
      }.to raise_error(ArgumentError, /vertical_strategy/)
    end

    it "raises on :explicit without enough lines" do
      page = FakePage.new
      expect {
        described_class.new(page,
          vertical_strategy: :explicit,
          explicit_vertical_lines: [50]
        )
      }.to raise_error(ArgumentError, /explicit_/)
    end
  end
end
