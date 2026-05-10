# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rpdfium::Util::WordExtractor do
  # Helper: costruisce un char hash con default sensati
  def char(text, x0, top, width: 5, height: 10, **extra)
    {
      char: text, codepoint: text.ord,
      x0: x0.to_f, x1: x0 + width.to_f,
      top: top.to_f, bottom: top + height.to_f,
      generated: false
    }.merge(extra)
  end

  describe "#extract_words" do
    it "joins consecutive char with small gap into one word" do
      chars = [
        char("H", 0, 100), char("e", 5, 100), char("l", 10, 100),
        char("l", 15, 100), char("o", 20, 100)
      ]
      words = described_class.new.extract_words(chars)
      expect(words.size).to eq(1)
      expect(words.first[:text]).to eq("Hello")
      expect(words.first[:x0]).to eq(0.0)
      expect(words.first[:x1]).to eq(25.0)
    end

    it "splits at large gaps (> x_tolerance)" do
      chars = [
        char("F", 0, 100), char("o", 5, 100), char("o", 10, 100),
        # gap di 30 px → nuova parola
        char("B", 50, 100), char("a", 55, 100), char("r", 60, 100)
      ]
      words = described_class.new(x_tolerance: 3.0).extract_words(chars)
      expect(words.map { |w| w[:text] }).to eq(%w[Foo Bar])
    end

    it "splits at row breaks (top differs by > y_tolerance)" do
      chars = [
        char("A", 0, 100), char("B", 5, 100),
        char("C", 0, 200), char("D", 5, 200)  # nuova riga
      ]
      words = described_class.new(y_tolerance: 3.0).extract_words(chars)
      expect(words.map { |w| w[:text] }).to eq(%w[AB CD])
    end

    it "treats whitespace chars as separators by default" do
      chars = [
        char("A", 0, 100), char("B", 5, 100),
        char(" ", 10, 100),  # spazio fisico → separatore
        char("C", 15, 100), char("D", 20, 100)
      ]
      words = described_class.new.extract_words(chars)
      expect(words.map { |w| w[:text] }).to eq(%w[AB CD])
    end

    it "splits on extra_attrs change (e.g. font)" do
      chars = [
        char("A", 0, 100, font: "Helvetica"),
        char("B", 5, 100, font: "Helvetica"),
        char("C", 10, 100, font: "TimesBold")  # font diverso → nuova word
      ]
      we = described_class.new(extra_attrs: [:font])
      words = we.extract_words(chars)
      expect(words.map { |w| w[:text] }).to eq(%w[AB C])
    end

    it "is empty-safe" do
      expect(described_class.new.extract_words([])).to eq([])
    end
  end
end
