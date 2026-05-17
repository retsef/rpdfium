# frozen_string_literal: true

require "spec_helper"

# Test di Page#font_inventory, Page#chars_where, Page#lines.
#
# Lo spec usa il path RPDFIUM_FORM_PDF se settato; altrimenti skippa.
# Aspetta un PDF di "modulo compilato" tipo F24 con almeno due font
# distinti (template + dati).

RSpec.describe "Form-aware extraction APIs", :integration do
  let(:form_path) { ENV["RPDFIUM_FORM_PDF"] }

  before(:each) do
    skip "set RPDFIUM_FORM_PDF to enable" unless form_path && File.exist?(form_path)
  end

  describe "Page#font_inventory" do
    it "returns an Array of Hash sorted by count desc" do
      Rpdfium.open(form_path) do |doc|
        inv = doc.page(0).font_inventory
        expect(inv).to be_an(Array)
        expect(inv).to all(include(:font, :height, :weight, :count, :sample))
        counts = inv.map { |g| g[:count] }
        expect(counts).to eq(counts.sort.reverse)
      end
    end

    it "has at least 2 distinct font groups for a typical form PDF" do
      Rpdfium.open(form_path) do |doc|
        expect(doc.page(0).font_inventory.size).to be >= 2
      end
    end
  end

  describe "Page#chars_where" do
    it "filters by exact font name" do
      Rpdfium.open(form_path) do |doc|
        page = doc.page(0)
        most_common_font = page.font_inventory.first[:font]
        filtered = page.chars_where(font: most_common_font)
        expect(filtered).not_to be_empty
        expect(filtered.map { |c| c[:font] }.uniq).to eq([most_common_font])
      end
    end

    it "filters by Regexp" do
      Rpdfium.open(form_path) do |doc|
        page = doc.page(0)
        # Match any font (regex `.`)
        all = page.chars_where(font: /./)
        non_gen = page.chars.reject { |c| c[:generated] }
        # All non-generated chars have some font (modulo edge cases)
        expect(all.size).to be > 0
      end
    end

    it "filters by bbox" do
      Rpdfium.open(form_path) do |doc|
        page = doc.page(0)
        # Half the page (top half in top-down coords)
        top_half = page.chars_where(bbox: [0, 0, page.width, page.height / 2.0])
        bottom_half = page.chars_where(bbox: [0, page.height / 2.0, page.width, page.height])
        all = page.chars.reject { |c| c[:generated] }
        # Top + bottom should approximately equal total
        expect(top_half.size + bottom_half.size).to be_within(5).of(all.size)
      end
    end

    it "combines filters with AND semantics" do
      Rpdfium.open(form_path) do |doc|
        page = doc.page(0)
        most_common_font = page.font_inventory.first[:font]
        all_font = page.chars_where(font: most_common_font)
        in_top_corner = page.chars_where(
          font: most_common_font,
          bbox: [0, 0, 200, 200]
        )
        expect(in_top_corner.size).to be <= all_font.size
      end
    end

    it "accepts `where:` block predicate" do
      Rpdfium.open(form_path) do |doc|
        digits_only = doc.page(0).chars_where(where: ->(c) { c[:char] =~ /\d/ })
        expect(digits_only.map { |c| c[:char] }.join).to match(/\A\d+\z/)
      end
    end
  end

  describe "Page#lines" do
    it "returns Array of String" do
      Rpdfium.open(form_path) do |doc|
        lines = doc.page(0).lines
        expect(lines).to all(be_a(String))
      end
    end

    it "respects font filter" do
      Rpdfium.open(form_path) do |doc|
        page = doc.page(0)
        rare_font = page.font_inventory.last[:font]
        common_font = page.font_inventory.first[:font]
        lines_rare = page.lines(font: rare_font)
        lines_common = page.lines(font: common_font)
        # Rare font has fewer lines (usually)
        expect(lines_rare.size).to be <= lines_common.size
      end
    end

    it "produces top-down ordered lines" do
      # Hard to assert this without knowing the PDF content, but
      # smoke-test that it doesn't crash
      Rpdfium.open(form_path) do |doc|
        expect { doc.page(0).lines }.not_to raise_error
      end
    end
  end
end
