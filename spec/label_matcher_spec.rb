# frozen_string_literal: true

require "spec_helper"

# Test del LabelMatcher con word fabbricate (no PDF richiesto)
RSpec.describe Rpdfium::Util::LabelMatcher do
  # Helper: costruisce un word hash con coords
  def word(text, x0, top, w: nil, h: 10)
    w ||= text.length * 5
    { text: text, x0: x0, x1: x0 + w, top: top, bottom: top + h }
  end

  let(:matcher) { described_class.new }

  describe "#cluster_anchors" do
    it "merges words on same row close in x" do
      words = [
        word("importi", 100, 50),
        word("a", 140, 50),
        word("debito", 150, 50)
      ]
      labels = matcher.cluster_anchors(words)
      expect(labels.size).to eq(1)
      expect(labels.first[:text]).to eq("importi a debito")
    end

    it "merges words on adjacent rows with x overlap" do
      words = [
        word("importi a", 100, 50),
        word("debito versati", 100, 62)  # row immediately below
      ]
      labels = matcher.cluster_anchors(words)
      expect(labels.size).to eq(1)
    end

    it "keeps separate words too far apart" do
      words = [
        word("CONTRIBUENTE", 50, 50),
        word("SALDO", 400, 200)
      ]
      labels = matcher.cluster_anchors(words)
      expect(labels.size).to eq(2)
    end
  end

  describe "#match" do
    let(:anchors) do
      [
        word("importi a debito versati", 50, 30, w: 100),
        word("SALDO", 50, 100, w: 30)
      ]
    end

    it "associates value below an anchor as col label" do
      values = [word("499.81", 60, 60)]
      pairs = matcher.match(values, anchors)
      expect(pairs.first[:labels][:col]).to include("importi a debito")
    end

    it "associates value to the right of an anchor as row label" do
      values = [word("100", 200, 100)]
      pairs = matcher.match(values, anchors)
      expect(pairs.first[:labels][:row]).to include("SALDO")
    end

    it "returns nil for both labels when value is isolated" do
      values = [word("orphan", 500, 500)]
      pairs = matcher.match(values, anchors)
      expect(pairs.first[:labels][:col]).to be_nil
      expect(pairs.first[:labels][:row]).to be_nil
    end

    it "always returns one pair per value, in input order" do
      values = [word("A", 60, 60), word("B", 60, 200), word("C", 60, 400)]
      pairs = matcher.match(values, anchors)
      expect(pairs.size).to eq(3)
      expect(pairs.map { |p| p[:value] }).to eq(%w[A B C])
    end

    it "exposes geometry of each value" do
      values = [word("V", 60, 60, w: 10, h: 5)]
      pairs = matcher.match(values, anchors)
      geom = pairs.first[:geometry]
      expect(geom).to include(:x0, :x1, :top, :bottom)
      expect(geom[:x0]).to eq(60)
    end
  end

  describe "tolerance tuning" do
    it "respects col_max_dy" do
      tight = described_class.new(col_max_dy: 5)
      anchors = [word("FAR LABEL", 50, 10)]
      values = [word("V", 60, 60)]  # 50pt below
      pairs = tight.match(values, anchors)
      expect(pairs.first[:labels][:col]).to be_nil
    end

    it "respects row_max_dx" do
      tight = described_class.new(row_max_dx: 5)
      anchors = [word("LABEL", 50, 100)]
      values = [word("V", 300, 100)]  # 250pt right
      pairs = tight.match(values, anchors)
      expect(pairs.first[:labels][:row]).to be_nil
    end
  end
end
