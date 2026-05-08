# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rpdfium::Table::Cells do
  describe ".from_intersections" do
    it "builds a 2×2 grid of cells from a 3×3 intersection grid" do
      ints = []
      [0.0, 100.0, 200.0].each do |x|
        [0.0, 50.0, 100.0].each do |y|
          ints << { x: x, y: y, h: nil, v: nil }
        end
      end
      cells = described_class.from_intersections(ints)
      expect(cells.size).to eq(4)
      expect(cells.first).to include(x0: 0.0, x1: 100.0, top: 0.0, bottom: 50.0)
    end

    it "skips cells where corners are missing" do
      # Manca un corner della cella destra-bassa
      ints = [
        { x: 0,   y: 0,  h: nil, v: nil },
        { x: 100, y: 0,  h: nil, v: nil },
        { x: 200, y: 0,  h: nil, v: nil },
        { x: 0,   y: 50, h: nil, v: nil },
        { x: 100, y: 50, h: nil, v: nil }
        # manca {x:200, y:50}
      ]
      cells = described_class.from_intersections(ints)
      expect(cells.size).to eq(1)  # solo cella sinistra
    end
  end

  describe ".group_into_tables" do
    it "groups adjacent cells into one table" do
      cells = [
        { x0: 0,   x1: 100, top: 0,  bottom: 50 },
        { x0: 100, x1: 200, top: 0,  bottom: 50 },
        { x0: 0,   x1: 100, top: 50, bottom: 100 },
        { x0: 100, x1: 200, top: 50, bottom: 100 }
      ]
      tables = described_class.group_into_tables(cells)
      expect(tables.size).to eq(1)
      expect(tables.first[:rows]).to eq(2)
      expect(tables.first[:cols]).to eq(2)
    end

    it "rejects 1×N tables" do
      cells = [
        { x0: 0,   x1: 100, top: 0, bottom: 50 },
        { x0: 100, x1: 200, top: 0, bottom: 50 }
      ]
      expect(described_class.group_into_tables(cells)).to be_empty
    end
  end
end
