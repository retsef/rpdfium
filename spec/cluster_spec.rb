# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rpdfium::Util::Cluster do
  describe ".cluster_list" do
    it "groups consecutive values within tolerance" do
      expect(described_class.cluster_list([1, 2, 5, 6], tolerance: 1))
        .to eq([[1, 2], [5, 6]])
    end

    it "treats tolerance=0 as 'all distinct'" do
      expect(described_class.cluster_list([1, 2, 3, 4], tolerance: 0))
        .to eq([[1], [2], [3], [4]])
    end

    it "handles 'stepping stones' (chained values)" do
      # Comportamento di pdfplumber: tolleranza locale, non globale.
      # 1→2 ok, 2→3 ok, 3→4 ok → tutti nello stesso cluster anche se 1↔4 = 3.
      expect(described_class.cluster_list([1, 2, 3, 4], tolerance: 1))
        .to eq([[1, 2, 3, 4]])
    end

    it "is empty-safe" do
      expect(described_class.cluster_list([], tolerance: 1)).to eq([])
    end
  end

  describe ".cluster_objects" do
    it "groups objects by hash key" do
      objs = [{ x: 10 }, { x: 11 }, { x: 50 }]
      result = described_class.cluster_objects(objs, :x, tolerance: 2)
      expect(result.size).to eq(2)
      expect(result.first.size).to eq(2)
    end

    it "groups objects by callable" do
      objs = [{ x: 10 }, { x: 11 }, { x: 50 }]
      result = described_class.cluster_objects(objs, ->(o) { o[:x] }, tolerance: 2)
      expect(result.size).to eq(2)
    end
  end

  describe ".objects_to_bbox" do
    it "returns [min_x0, min_top, max_x1, max_bottom]" do
      objs = [
        { x0: 10, top: 100, x1: 50,  bottom: 120 },
        { x0: 5,  top: 105, x1: 80,  bottom: 110 },
        { x0: 60, top: 95,  x1: 100, bottom: 130 }
      ]
      expect(described_class.objects_to_bbox(objs)).to eq([5, 95, 100, 130])
    end
  end

  describe ".bbox_overlap" do
    it "returns nil for non-overlapping bboxes" do
      expect(described_class.bbox_overlap([0, 0, 10, 10], [20, 20, 30, 30])).to be_nil
    end

    it "returns the intersection bbox" do
      expect(described_class.bbox_overlap([0, 0, 10, 10], [5, 5, 20, 20]))
        .to eq([5, 5, 10, 10])
    end

    it "returns nil for tangent bboxes (zero area)" do
      expect(described_class.bbox_overlap([0, 0, 10, 10], [10, 0, 20, 10])).to be_nil
    end
  end
end
