# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rpdfium::Table::Edges do
  describe ".snap_horizontal" do
    it "snaps near-collinear horizontal edges to a common y" do
      edges = [
        { y: 100.0, x0: 0,  x1: 50 },
        { y: 100.4, x0: 60, x1: 100 },  # entro tol=1
        { y: 200.0, x0: 0,  x1: 50 }
      ]
      result = described_class.snap_horizontal(edges, 1.0)
      ys = result.map { |e| e[:y] }.uniq.sort
      expect(ys.size).to eq(2)
      expect(ys.first).to be_within(0.5).of(100.2)  # mean
      expect(ys.last).to eq(200.0)
    end

    it "leaves edges far apart untouched" do
      edges = [{ y: 100.0, x0: 0, x1: 50 }, { y: 200.0, x0: 0, x1: 50 }]
      result = described_class.snap_horizontal(edges, 1.0)
      expect(result.map { |e| e[:y] }).to contain_exactly(100.0, 200.0)
    end
  end

  describe ".join_horizontal" do
    it "merges contiguous segments on the same y" do
      edges = [
        { y: 100.0, x0: 0,   x1: 50 },
        { y: 100.0, x0: 51,  x1: 100 },  # contiguo entro tol=2
        { y: 100.0, x0: 200, x1: 250 }   # gap > tol → separato
      ]
      result = described_class.join_horizontal(edges, 2.0)
      expect(result.size).to eq(2)
      expect(result.first).to include(x0: 0, x1: 100)
      expect(result.last).to include(x0: 200, x1: 250)
    end
  end

  describe ".filter_short_horizontal" do
    it "removes edges shorter than min_length" do
      edges = [
        { y: 100.0, x0: 0, x1: 2 },     # len 2 → drop
        { y: 100.0, x0: 0, x1: 50 }     # len 50 → keep
      ]
      result = described_class.filter_short_horizontal(edges, 5.0)
      expect(result.size).to eq(1)
    end
  end

  describe ".intersections" do
    it "finds h × v crossings within tolerance" do
      h = [{ y: 100.0, x0: 0, x1: 200 }]
      v = [{ x: 50.0, top: 0, bottom: 300 }]
      result = described_class.intersections(h, v, x_tol: 1.0, y_tol: 1.0)
      expect(result.size).to eq(1)
      expect(result.first).to include(x: 50.0, y: 100.0)
    end

    it "rejects out-of-range crossings" do
      h = [{ y: 100.0, x0: 0, x1: 40 }]    # x1=40, v.x=50 → fuori
      v = [{ x: 50.0, top: 0, bottom: 300 }]
      result = described_class.intersections(h, v, x_tol: 1.0, y_tol: 1.0)
      expect(result).to be_empty
    end
  end
end
