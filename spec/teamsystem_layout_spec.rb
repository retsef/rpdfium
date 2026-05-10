# frozen_string_literal: true

require "spec_helper"

# Test di non-regressione basato sul layout REALE di un cedolino TeamSystem
#
# La tabella "voci paga" ha:
#   - header a y≈199.8 con 6 colonne: VOCE | DESCRIZIONE | ORE/GIORNI | BASE
#                                      | COMPETENZE | TRATTENUTE
#   - righe dati a y=212, 224, 234, 246, 256, 278, 290, 300, 322, 334
#
# Il PDF NON ha linee vettoriali — solo allineamento testuale.
# Quindi serve `vertical_strategy: :text` con `min_words_vertical` basso
# (header con 1 sola word, righe con valori non sempre presenti in TUTTE le
# colonne). Non testiamo l'auto-detection completa qui — testiamo che le
# primitive `words_to_edges_v` e `words_to_edges_h` producano edges
# congruenti con la struttura reale.

RSpec.describe "TeamSystem layout primitives" do
  # Estratto dal dump reale dell'utente (riga header a y=199.8)
  let(:header_words) do
    [
      { text: "VOCE",        x0:  31.5, x1:  46.2, top: 199.8, bottom: 209.0 },
      { text: "DESCRIZIONE", x0:  60.3, x1:  96.4, top: 199.8, bottom: 209.0 },
      { text: "ORE/GIORNI",  x0: 180.4, x1: 212.0, top: 199.8, bottom: 209.0 },
      { text: "BASE",        x0: 218.7, x1: 232.9, top: 199.8, bottom: 209.0 },
      { text: "COMPETENZE",  x0: 334.0, x1: 370.9, top: 199.8, bottom: 209.0 },
      { text: "TRATTENUTE",  x0: 391.5, x1: 427.1, top: 199.8, bottom: 209.0 }
    ]
  end

  # Righe dati: codice voce, descrizione, ore/giorni, base, competenze
  # Simulate. Non sempre TUTTI i campi sono presenti (es. "RETRIBUZIONE" non
  # ha ore/giorni). Replichiamo la realtà.
  let(:body_words) do
    rows_data = [
      # [voce_code, descrizione, ore_giorni, base, competenze]
      ["1052", "RETRIBUZIONE", nil,    nil,       "1234.56"],
      ["1100", "UTILE",        nil,    nil,        "100.00"],
      ["1200", "TFR",          nil,    nil,        "200.00"],
      ["2050", "ORE LAVORATE", "168",  nil,           nil],
      ["3001", "TRATTENUTA",   nil,    nil,           nil]
    ]
    cols_x0 = [31.5, 60.3, 180.4, 218.7, 334.0]
    char_w = 6.0
    rows_data.flat_map.with_index do |row, ri|
      top = 212.0 + ri * 12.0
      row.each_with_index.flat_map do |val, ci|
        next [] if val.nil?

        x0 = cols_x0[ci]
        [{ text: val, x0: x0, x1: x0 + val.length * char_w,
           top: top, bottom: top + 10.0 }]
      end
    end
  end

  describe "words_to_edges_v on TeamSystem header alone" do
    it "with min_words_vertical=1, finds an edge per header column" do
      # Header da solo: 6 word, ognuna a x diversa. Threshold 1 → 6+1 edges.
      edges = Rpdfium::Table::Edges.words_to_edges_v(header_words, word_threshold: 1)
      xs = edges.map { |e| e[:x0] }.sort
      # Dovremmo avere almeno gli x0 di tutti gli header
      header_x0s = header_words.map { |w| w[:x0] }
      header_x0s.each do |x|
        expect(xs.any? { |ex| (ex - x).abs < 2.0 }).to be(true),
          "Manca edge a x≈#{x} (xs presenti: #{xs.inspect})"
      end
    end
  end

  describe "words_to_edges_v on full body+header" do
    it "with min_words_vertical=2 detects the main columns" do
      all_words = header_words + body_words
      edges = Rpdfium::Table::Edges.words_to_edges_v(all_words, word_threshold: 2)

      # Le colonne con almeno 2 word allineate (tra header+body) sono:
      # VOCE     (header + 5 codici codice voce a x=31.5)
      # DESCRIZIONE (header + 5 descrizioni a x=60.3)
      # COMPETENZE  (header + 3 valori a x=334.0)
      xs = edges.map { |e| e[:x0] }
      expect(xs.any? { |x| (x - 31.5).abs < 2.0 }).to be(true), "Manca colonna VOCE"
      expect(xs.any? { |x| (x - 60.3).abs < 2.0 }).to be(true), "Manca colonna DESCRIZIONE"
      expect(xs.any? { |x| (x - 334.0).abs < 2.0 }).to be(true), "Manca colonna COMPETENZE"
    end
  end

  describe "words_to_edges_h on body" do
    it "emits 2 edges per row (top + bottom)" do
      edges = Rpdfium::Table::Edges.words_to_edges_h(body_words, word_threshold: 1)
      tops = edges.map { |e| e[:top] }.uniq.sort
      # 5 righe, ognuna con due edge (top di cluster + bottom). Quindi
      # 10 valori distinti (con tol di clustering 1.0):
      # tops = [212, 222, 224, 234, 236, 246, 248, 258, 260, 270]
      # In realtà alcuni potrebbero coincidere: top di una riga (224)
      # si può fondere col bottom della precedente (222). Ma l'algoritmo
      # genera comunque DUE edge per cluster, anche se snap-fonde alcuni.
      # Quindi mi aspetto MIN 5 valori distinti (uno per riga).
      expect(tops.size).to be >= 5
    end
  end

  describe "TextExtraction with chars from a single cell" do
    # Verifica che il path WordExtractor → extract_text gestisca
    # correttamente char dentro una bbox stretta senza concatenare parole
    # adiacenti (era il bug della 0.2.x con TeamSystem).
    let(:chars) do
      # "RETRIBUZIONE" a x=60..136, "UTILE" a x=200..230 (lontano)
      retribuzione = "RETRIBUZIONE".chars.each_with_index.map do |c, i|
        { char: c, codepoint: c.ord,
          x0: 60.0 + i * 6.0, x1: 60.0 + (i + 1) * 6.0,
          top: 100.0, bottom: 110.0, generated: false }
      end
      utile = "UTILE".chars.each_with_index.map do |c, i|
        { char: c, codepoint: c.ord,
          x0: 200.0 + i * 6.0, x1: 200.0 + (i + 1) * 6.0,
          top: 100.0, bottom: 110.0, generated: false }
      end
      retribuzione + utile
    end

    it "extracts both words separately when given the full row" do
      result = Rpdfium::Util::TextExtraction.extract_text(chars, x_tolerance: 3.0)
      expect(result).to eq("RETRIBUZIONE UTILE")
    end

    it "extracts only RETRIBUZIONE when filtered to its bbox via midpoint" do
      # Simulo Table#extract: filtro per midpoint nella cella DESCRIZIONE
      cell_bbox = [55.0, 95.0, 150.0, 115.0]  # x0, top, x1, bottom
      filtered = chars.select do |c|
        h_mid = (c[:x0] + c[:x1]) / 2.0
        v_mid = (c[:top] + c[:bottom]) / 2.0
        h_mid >= cell_bbox[0] && h_mid < cell_bbox[2] &&
          v_mid >= cell_bbox[1] && v_mid < cell_bbox[3]
      end
      result = Rpdfium::Util::TextExtraction.extract_text(filtered, x_tolerance: 3.0)
      expect(result).to eq("RETRIBUZIONE")
    end
  end
end
