# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rpdfium::Table::Edges do
  def hedge(top, x0, x1)
    { x0: x0.to_f, x1: x1.to_f, top: top.to_f, bottom: top.to_f, orientation: "h" }
  end

  def vedge(x, top, bottom)
    { x0: x.to_f, x1: x.to_f, top: top.to_f, bottom: bottom.to_f, orientation: "v" }
  end

  describe ".snap_edges" do
    it "snaps near-collinear horizontal edges to a common top" do
      edges = [hedge(100.0, 0, 50), hedge(100.4, 60, 100), hedge(200.0, 0, 50)]
      result = described_class.snap_edges(edges, x_tolerance: 1.0, y_tolerance: 1.0)
      tops = result.map { |e| e[:top] }.uniq.sort
      expect(tops.size).to eq(2)
      expect(tops.first).to be_within(0.3).of(100.2)
      expect(tops.last).to eq(200.0)
    end

    it "snaps near-collinear vertical edges to a common x0" do
      edges = [vedge(50.0, 0, 100), vedge(50.4, 0, 100), vedge(200.0, 0, 100)]
      result = described_class.snap_edges(edges, x_tolerance: 1.0, y_tolerance: 1.0)
      xs = result.map { |e| e[:x0] }.uniq.sort
      expect(xs.size).to eq(2)
    end
  end

  describe ".join_edge_group" do
    it "merges contiguous horizontal segments on the same top" do
      edges = [hedge(100.0, 0, 50), hedge(100.0, 51, 100), hedge(100.0, 200, 250)]
      result = described_class.join_edge_group(edges, "h", tolerance: 2.0)
      expect(result.size).to eq(2)
      expect(result.first).to include(x0: 0.0, x1: 100.0)
      expect(result.last).to include(x0: 200.0, x1: 250.0)
    end
  end

  describe ".filter_edges" do
    it "drops edges shorter than min_length" do
      edges = [hedge(100, 0, 2), hedge(100, 0, 50), vedge(10, 0, 1), vedge(20, 0, 100)]
      result = described_class.filter_edges(edges, min_length: 5.0)
      expect(result.size).to eq(2)
    end
  end

  describe ".edges_to_intersections" do
    it "finds h × v crossings within tolerance, with edge identity preserved" do
      h = hedge(100.0, 0, 200)
      v = vedge(50.0, 0, 300)
      result = described_class.edges_to_intersections(
        [h, v], x_tolerance: 1.0, y_tolerance: 1.0
      )
      expect(result.keys).to contain_exactly([50.0, 100.0])
      entry = result[[50.0, 100.0]]
      # Cells.intersections_to_cells si fida dell'identità degli edge per
      # verificare il "connect"; questo test garantisce che gli oggetti
      # vengano passati intatti (no copia).
      expect(entry[:h].first).to be(h)
      expect(entry[:v].first).to be(v)
    end

    it "rejects crossings outside edge extents" do
      h = hedge(100.0, 0, 40)
      v = vedge(50.0, 0, 300)
      result = described_class.edges_to_intersections(
        [h, v], x_tolerance: 1.0, y_tolerance: 1.0
      )
      expect(result).to be_empty
    end
  end

  describe ".words_to_edges_v" do
    let(:words) do
      cols = [10, 100, 200]
      tops = [50, 80, 110]
      cols.flat_map.with_index do |x0, ci|
        tops.map do |t|
          { text: "c#{ci}", x0: x0.to_f, x1: x0 + 30.0, top: t.to_f, bottom: t + 10.0 }
        end
      end
    end

    it "emits one v edge per column + final right edge, all orientation v" do
      edges = described_class.words_to_edges_v(words, word_threshold: 3)
      xs = edges.map { |e| e[:x0] }.sort
      expect(xs).to eq([10.0, 100.0, 200.0, 230.0])
      expect(edges).to all(include(orientation: "v"))
    end

    it "uses x1 cluster too (right-aligned numeric columns)" do
      # Caso reale: 3 word numeriche right-aligned alla stessa x1
      # ma con x0 diverse (numeri di larghezza variabile come "1.234,56" vs "9").
      words = [
        { x0: 100, x1: 200, top: 10, bottom: 20 },
        { x0: 130, x1: 200, top: 30, bottom: 40 },
        { x0: 145, x1: 200, top: 50, bottom: 60 }
      ].map { |h| h.transform_values(&:to_f) }
      edges = described_class.words_to_edges_v(words, word_threshold: 3)
      # Per via del cluster x1, anche se gli x0 non si allineano bene,
      # x=200 è una colonna detectabile.
      expect(edges.map { |e| e[:x0] }).to include(200.0)
    end
  end

  describe ".words_to_edges_h" do
    let(:words) do
      [50, 80, 110].flat_map do |t|
        [10, 100, 200].map do |x0|
          { text: "r", x0: x0.to_f, x1: x0 + 30.0, top: t.to_f, bottom: t + 10.0 }
        end
      end
    end

    it "emits TWO horizontal edges per row cluster (top + bottom)" do
      edges = described_class.words_to_edges_h(words, word_threshold: 1)
      tops = edges.map { |e| e[:top] }.sort.uniq
      # Per ogni riga (50, 80, 110): top (=50/80/110) e bottom (=60/90/120)
      # → 6 valori distinti. La riga "bottom" è quella che chiude visivamente
      # l'ultima riga della tabella, senza la quale extract perderebbe l'ultimo.
      expect(tops).to eq([50.0, 60.0, 80.0, 90.0, 110.0, 120.0])
      expect(edges).to all(include(orientation: "h"))
    end
  end
end
