# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rpdfium::Table::Cells do
  # Helper: costruisce una griglia completa di intersezioni con edge "globali"
  # per asse (un solo h shared per riga, un solo v shared per colonna).
  # Questo è esattamente ciò che `merge_edges` produce in casi normali e
  # garantisce che `edge_connect` funzioni.
  def grid_intersections(xs, ys)
    h_edges = ys.to_h { |y| [y, { x0: xs.min, x1: xs.max, top: y, bottom: y, orientation: "h" }] }
    v_edges = xs.to_h { |x| [x, { x0: x, x1: x, top: ys.min, bottom: ys.max, orientation: "v" }] }
    intersections = {}
    xs.each do |x|
      ys.each do |y|
        intersections[[x, y]] = { v: [v_edges[x]], h: [h_edges[y]] }
      end
    end
    intersections
  end

  describe ".intersections_to_cells" do
    it "builds 4 cells from a 3×3 intersection grid (2×2 cells)" do
      ints = grid_intersections([0.0, 100.0, 200.0], [0.0, 50.0, 100.0])
      cells = described_class.intersections_to_cells(ints)
      expect(cells.size).to eq(4)
      # bbox = [x0, top, x1, bottom]
      expect(cells).to include([0.0, 0.0, 100.0, 50.0])
      expect(cells).to include([100.0, 0.0, 200.0, 50.0])
      expect(cells).to include([0.0, 50.0, 100.0, 100.0])
      expect(cells).to include([100.0, 50.0, 200.0, 100.0])
    end

    it "skips cells where a corner is missing" do
      ints = grid_intersections([0.0, 100.0, 200.0], [0.0, 50.0])
      # Rimuovo il corner [200, 50] simulando edge orizzontale che si ferma a 100
      ints.delete([200.0, 50.0])
      cells = described_class.intersections_to_cells(ints)
      expect(cells.size).to eq(1)
      expect(cells.first).to eq([0.0, 0.0, 100.0, 50.0])
    end

    it "rejects pairs that share no edge object even if coords align" do
      # Due intersezioni alla stessa x ma con edge verticali DIVERSI:
      # questo simula due colonne staccate che casualmente hanno x uguale.
      v1 = { x0: 50, x1: 50, top: 0, bottom: 50, orientation: "v" }
      v2 = { x0: 50, x1: 50, top: 100, bottom: 200, orientation: "v" }
      h_top = { x0: 0, x1: 100, top: 0, bottom: 0, orientation: "h" }
      h_bot = { x0: 0, x1: 100, top: 100, bottom: 100, orientation: "h" }
      ints = {
        [50.0, 0.0]   => { v: [v1], h: [h_top] },
        [50.0, 100.0] => { v: [v2], h: [h_bot] }
      }
      # Manca un secondo punto (x diverso da 50) per chiudere comunque la
      # cella a destra; ma il punto importante è verificare che intersections
      # incomplete + edge_connect=false NON producano celle false.
      cells = described_class.intersections_to_cells(ints)
      expect(cells).to be_empty
    end
  end

  describe ".cells_to_tables" do
    it "groups corner-sharing cells into one table" do
      cells = [
        [0.0, 0.0, 100.0, 50.0],
        [100.0, 0.0, 200.0, 50.0],
        [0.0, 50.0, 100.0, 100.0],
        [100.0, 50.0, 200.0, 100.0]
      ]
      tables = described_class.cells_to_tables(cells)
      expect(tables.size).to eq(1)
      expect(tables.first.size).to eq(4)
    end

    it "rejects single-cell groups" do
      cells = [[0.0, 0.0, 100.0, 50.0]]
      expect(described_class.cells_to_tables(cells)).to be_empty
    end

    it "splits unconnected cell groups into separate tables" do
      cells = [
        # Gruppo A
        [0.0, 0.0, 100.0, 50.0],
        [100.0, 0.0, 200.0, 50.0],
        # Gruppo B (lontano, nessun corner condiviso)
        [500.0, 500.0, 600.0, 550.0],
        [600.0, 500.0, 700.0, 550.0]
      ]
      tables = described_class.cells_to_tables(cells)
      expect(tables.size).to eq(2)
      tables.each { |t| expect(t.size).to eq(2) }
    end
  end
end
