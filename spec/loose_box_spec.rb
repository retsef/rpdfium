# frozen_string_literal: true

require "spec_helper"

# Test di integrazione: verifica del comportamento "loose char box"
# introdotto in 0.3.2. Senza il loose box, i char di punteggiatura
# (`.`, `,`) hanno bbox tight del solo glifo (alto 0.85pt anziché ~7pt).
# Ne risulta che il loro v_mid è ~3pt sotto quello dei numeri sulla
# stessa baseline, e il filtro midpoint di Table#extract li scarta.
RSpec.describe "Loose char box integration", :integration do
  let(:fixture) { "spec/fixtures/teamsystem.pdf" }

  before do
    skip "Fixture non presente" unless File.exist?(fixture)
  end

  it "preserves punctuation in numeric cells" do
    Rpdfium.open(fixture) do |doc|
      page = doc.page(0)
      ext = Rpdfium::Table::Extractor.new(page,
        vertical_strategy: :lines, horizontal_strategy: :lines,
        auto_fallback: false)

      cells = ext.tables.first.extract.flatten.compact
      # I valori numerici tipici di un cedolino italiano hanno punto
      # (migliaia) e virgola (decimali). Devono arrivare integri.
      expect(cells.any? { |c| c.match?(/\d\.\d{3},\d{2}/) }).to be(true),
        "Nessuna cella con il pattern N.NNN,NN trovata"
    end
  end

  it "all chars on same line share same v_mid (loose box)" do
    Rpdfium.open(fixture) do |doc|
      page = doc.page(0)
      # Restringi ad una riga sola
      cs = page.chars.select { |c| c[:top] > 220 && c[:top] < 225 }
                     .select { |c| c[:char].match?(/[\d,.]/) }
      v_mids = cs.map { |c| (c[:top] + c[:bottom]) / 2.0 }.uniq
      expect(v_mids.size).to be <= 2,
        "Mi aspetto v_mid uniformi nella riga (effetto loose box), " \
        "trovati #{v_mids.size} distinti"
    end
  end

  describe "inject_spaces opt-in" do
    it "is disabled by default" do
      Rpdfium.open(fixture) do |doc|
        cs = doc.page(0).chars
        synthetic = cs.count { |c| c[:char] == " " && c[:generated] }
        # Senza injection ci sono solo gli spazi sintetici di PDFium "naturali"
        baseline = synthetic
        cs2 = doc.page(0).chars(inject_spaces: true)
        expect(cs2.count { |c| c[:char] == " " && c[:generated] }).to be > baseline
      end
    end
  end
end
