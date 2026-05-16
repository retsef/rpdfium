# frozen_string_literal: true

require "spec_helper"

# Test di Page#struct_tree, Structure::Tree, Structure::Element.
#
# Il test richiede un PDF tagged. Se non disponibile, lo spec viene
# skippato. Per generarne uno da una HTML semplice:
#
#   echo '<html><body><h1>T</h1><table><tr><th>A</th><th>B</th></tr>
#         <tr><td>1</td><td>2</td></tr></table></body></html>' > /tmp/x.html
#   soffice --headless --convert-to pdf --outdir /tmp /tmp/x.html
#
# Lo spec accetta il path via ENV per essere flessibile in CI.

RSpec.describe "Page#struct_tree", :integration do
  let(:tagged_path) { ENV["RPDFIUM_TAGGED_PDF"] || File.expand_path("../tagged.pdf", __dir__) }

  context "on a non-tagged PDF" do
    it "returns nil" do
      # Usa un PDF di test non tagged. Cerca in spec/fixtures o falla
      # silenziosamente se non c'è.
      candidates = [
        File.expand_path("../sample.pdf", __dir__),
        ENV["RPDFIUM_NONTAGGED_PDF"]
      ].compact

      path = candidates.find { |p| File.exist?(p) }
      skip "no non-tagged PDF available" unless path

      Rpdfium.open(path) do |doc|
        expect(doc.page(0).struct_tree).to be_nil
      end
    end
  end

  context "on a tagged PDF" do
    before(:all) do
      tagged = ENV["RPDFIUM_TAGGED_PDF"] || File.expand_path("../tagged.pdf", __dir__)
      skip "no tagged PDF available (set RPDFIUM_TAGGED_PDF)" unless File.exist?(tagged)
    end

    it "returns a Tree", :aggregate_failures do
      skip unless File.exist?(tagged_path)

      Rpdfium.open(tagged_path) do |doc|
        tree = doc.page(0).struct_tree
        expect(tree).not_to be_nil
        expect(tree).to be_a(Rpdfium::Structure::Tree)
        expect(tree.root_count).to be > 0
        expect(tree.empty?).to be false
      end
    end

    it "exposes root elements with type" do
      skip unless File.exist?(tagged_path)

      Rpdfium.open(tagged_path) do |doc|
        tree = doc.page(0).struct_tree
        roots = tree.roots
        expect(roots).not_to be_empty
        # LibreOffice export tipico: 1 root "Document"
        expect(roots.first.type).to eq("Document")
      end
    end

    it "walks the tree depth-first" do
      skip unless File.exist?(tagged_path)

      Rpdfium.open(tagged_path) do |doc|
        tree = doc.page(0).struct_tree
        types = tree.walk.map(&:type).compact
        expect(types).to include("Document")
        # Tipi probabili: P (paragrafo), Table (se la HTML ha una table)
        expect(types).to include(satisfy { |t| %w[P H1 H2 Span].include?(t) })
      end
    end

    it "finds elements by type" do
      skip unless File.exist?(tagged_path)

      Rpdfium.open(tagged_path) do |doc|
        tree = doc.page(0).struct_tree
        paragraphs = tree.find_all(type: "P")
        expect(paragraphs).not_to be_empty
        expect(paragraphs).to all(be_a(Rpdfium::Structure::Element))
        expect(paragraphs.map(&:type).uniq).to eq(["P"])
      end
    end

    it "resolves text via MCID" do
      skip unless File.exist?(tagged_path)

      Rpdfium.open(tagged_path) do |doc|
        tree = doc.page(0).struct_tree
        # Almeno UN element del tree deve avere text non vuoto
        with_text = tree.walk.find { |el| el.text && !el.text.empty? }
        expect(with_text).not_to be_nil
      end
    end

    it "closes via block style" do
      skip unless File.exist?(tagged_path)

      Rpdfium.open(tagged_path) do |doc|
        tree_ref = nil
        result = doc.page(0).struct_tree do |tree|
          tree_ref = tree
          expect(tree.closed?).to be false
          tree.root_count
        end
        expect(result).to be > 0
        expect(tree_ref.closed?).to be true
      end
    end

    it "closes via block style even on exception" do
      skip unless File.exist?(tagged_path)

      tree_ref = nil
      Rpdfium.open(tagged_path) do |doc|
        expect do
          doc.page(0).struct_tree do |tree|
            tree_ref = tree
            raise "test error"
          end
        end.to raise_error("test error")
      end
      expect(tree_ref.closed?).to be true
    end

    describe "#tables shortcut" do
      it "returns Table elements" do
        skip unless File.exist?(tagged_path)

        Rpdfium.open(tagged_path) do |doc|
          tree = doc.page(0).struct_tree
          tables = tree.tables
          # Se il PDF tagged contiene tabelle, le troviamo. Altrimenti
          # un Array vuoto (caso valido).
          expect(tables).to all(satisfy { |t| t.type == "Table" })
        end
      end
    end
  end
end
