# frozen_string_literal: true

# Generates:
#   * the 4 benchmark PDFs (pdfs/01..04, increasing complexity) plus the
#     ground-truth manifest pdfs/expected.json used for the correctness metric
#   * the sample PDFs referenced by the documentation site (one per topic)
#
# Requires the hexapdf gem (generation only — not a dependency of rpdfium):
#
#   gem install hexapdf
#   ruby benchmark/generate_pdfs.rb
#
# All content is synthetic placeholder data. Output is deterministic except
# for the PDF creation timestamps.

require "hexapdf"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../lib/rpdfium/io/png" # standalone pure-Ruby PNG writer

PDF_DIR = File.expand_path("pdfs", __dir__)
SITE_ASSETS_DIR = File.expand_path("../site/assets/pdfs", __dir__)
FileUtils.mkdir_p(PDF_DIR)
FileUtils.mkdir_p(SITE_ASSETS_DIR)

LOREM = <<~TEXT.gsub(/\s+/, " ").strip
  Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod
  tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim
  veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea
  commodo consequat. Duis aute irure dolor in reprehenderit in voluptate
  velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint
  occaecat cupidatat non proident, sunt in culpa qui officia deserunt
  mollit anim id est laborum.
TEXT

PAGE_W = 595
PAGE_H = 842
MARGIN = 50
COLS = [70, 200, 40, 70, 70].freeze # Codice, Descrizione, Q.ta, Prezzo, Totale
HEADER = ["Codice", "Descrizione", "Q.ta", "Prezzo", "Totale"].freeze

# ----------------------------------------------------------------------------
# Ground-truth manifest. For each benchmark PDF we record:
#   * text_sentinels — unique tokens embedded in the running text; the text
#     task scores the fraction recovered by each library
#   * table_cells   — unique cell values of the ruled tables; the tables task
#     scores the fraction recovered as table cells
# ----------------------------------------------------------------------------
MANIFEST = Hash.new { |h, k| h[k] = { "pages" => 0, "text_sentinels" => [], "table_cells" => [] } }

def sentinel(pdf_key, seq)
  token = format("TKN-%s-%04d", pdf_key, seq)
  MANIFEST["0#{pdf_key}"]["text_sentinels"] << token
  token
end

def invoice_row(i)
  qty = (i % 7) + 1
  unit = 10.0 + (i * 3.17 % 90)
  [format("SKU-%05d", i), "Servizio di esempio n. #{i}", qty.to_s,
   format("%.2f", unit), format("%.2f", qty * unit)]
end

# --- low-level canvas helpers ------------------------------------------------

def wrap_text(text, max_chars)
  words = text.split(" ")
  lines = [+""]
  words.each do |w|
    if lines.last.empty?
      lines.last << w
    elsif lines.last.size + 1 + w.size <= max_chars
      lines.last << " " << w
    else
      lines << w.dup
    end
  end
  lines
end

def draw_paragraph(canvas, y, text, size: 9, leading: 12)
  canvas.font("Helvetica", size: size)
  wrap_text(text, 100).each do |line|
    canvas.text(line, at: [MARGIN, y])
    y -= leading
  end
  y - 6
end

def draw_heading(canvas, y, text, size: 14)
  canvas.font("Helvetica", size: size, variant: :bold)
  canvas.text(text, at: [MARGIN, y])
  y - size - 10
end

# Ruled table: real grid lines (every cell stroked) + cell text.
def draw_ruled_table(canvas, y, rows, row_h: 16)
  x_edges = COLS.each_with_object([MARGIN + 0.5]) { |w, acc| acc << acc.last + w }
  top = y
  bottom = y - row_h * (rows.size + 1)
  # vertical lines
  x_edges.each { |x| canvas.line(x, top, x, bottom).stroke }
  # horizontal lines + text
  all_rows = [HEADER] + rows
  all_rows.each_with_index do |row, ri|
    ry = top - ri * row_h
    canvas.line(x_edges.first, ry, x_edges.last, ry).stroke
    canvas.font("Helvetica", size: 8, variant: ri.zero? ? :bold : :none)
    row.each_with_index do |cell, ci|
      canvas.text(cell, at: [x_edges[ci] + 4, ry - row_h + 5])
    end
  end
  canvas.line(x_edges.first, bottom, x_edges.last, bottom).stroke
  bottom - 16
end

# Borderless table: same data, aligned columns, no lines (:text strategy).
def draw_borderless_table(canvas, y, rows, row_h: 14)
  x_pos = COLS.each_with_object([MARGIN]) { |w, acc| acc << acc.last + w }
  ([HEADER] + rows).each_with_index do |row, ri|
    canvas.font("Helvetica", size: 8, variant: ri.zero? ? :bold : :none)
    row.each_with_index { |cell, ci| canvas.text(cell, at: [x_pos[ci], y]) }
    y -= row_h
  end
  y - 16
end

def stamped_form_canvas(canvas, courier_extra: nil)
  canvas.font("Helvetica", size: 14, variant: :bold)
  canvas.text("MODELLO DI ESEMPIO", at: [50, 800])

  labels = [
    ["CODICE FISCALE", 50, 760], ["DENOMINAZIONE", 250, 760],
    ["DOMICILIO FISCALE", 50, 710], ["PARTITA IVA", 350, 710],
    ["codice tributo", 50, 640], ["periodo", 150, 640], ["anno", 220, 640],
    ["importi a debito", 300, 640], ["importi a credito", 430, 640],
  ]
  canvas.font("Helvetica", size: 7)
  labels.each { |text, x, y| canvas.text(text, at: [x, y]) }

  data = [
    ["RSSMRA80A01H501Z", 50, 745], ["Azienda S.R.L.", 250, 745],
    ["CITTA XX VIA ESEMPIO 1", 50, 695], ["01234567890", 350, 695],
  ]
  rows = [
    ["1001", "11", "2021", "499,81", "0,00"],
    ["1712", "12", "2021", "32,46", "0,00"],
    ["1701", "11", "2021", "0,00", "295,89"],
    ["3812", "12", "2021", "236,38", "0,00"],
  ]
  canvas.font("Courier", size: 10)
  data.each { |text, x, y| canvas.text(text, at: [x, y]) }
  rows.each_with_index do |row, ri|
    y = 622 - ri * 16
    [50, 150, 220, 300, 430].each_with_index do |x, ci|
      canvas.text(row[ci], at: [x, y])
    end
  end
  canvas.text(courier_extra, at: [50, 540]) if courier_extra
end

# Registers the unique cells of `rows` in the manifest for the tables task.
def register_cells(manifest_key, rows)
  rows.each do |row|
    MANIFEST[manifest_key]["table_cells"] << row[0] # SKU code (unique)
    MANIFEST[manifest_key]["table_cells"] << row[4] # row total
  end
end

# --- academic-tier helpers (05_academic.pdf) --------------------------------
# Longer running text, so two condensed columns actually fill a page.
ACADEMIC_LOREM = ([LOREM] * 5).join(" ").freeze

# Deterministic synthetic "figure" PNG (a fake bar chart over a grid). Cached
# per seed in tmpdir; identical files are deduplicated to a single image
# XObject by hexapdf on write, so the page count does not bloat the file.
def academic_figure_png(seed)
  path = File.join(Dir.tmpdir, "rpdfium_fig_#{seed}.png")
  return path if File.exist?(path)

  w = 160
  h = 100
  palette = ["\x1f\x4e\x8c\xFF".b, "\x8c\x1f\x3e\xFF".b, "\x2e\x8c\x4f\xFF".b]
  rgba = String.new(capacity: w * h * 4, encoding: Encoding::ASCII_8BIT)
  h.times do |y|
    w.times do |x|
      bar_h = ((x * 7 + seed * 13) % h)
      on_grid = (y % 20).zero? || (x % 24).zero?
      rgba << if y >= h - bar_h
                palette[(x / 16 + seed) % palette.size]
              elsif on_grid
                "\xCC\xCC\xCC\xFF".b
              else
                "\xFF\xFF\xFF\xFF".b
              end
    end
  end
  Rpdfium::IO::PNG.write(path, w, h, rgba)
  path
end

# Two condensed text columns (small font, negative char spacing, horizontal
# scaling < 100% — the "condensed text / tight spacing" artifact). Lines that
# overflow the available height are dropped (the text is intentionally over-
# provided so both columns fill).
def draw_two_columns(canvas, top, lines, size: 7.5, leading: 9.5,
                     hscale: 82, cspacing: -0.2, bottom: 60)
  gutter = 18
  col_w = (PAGE_W - 2 * MARGIN - gutter) / 2.0
  x = [MARGIN, MARGIN + col_w + gutter]
  rows_per_col = ((top - bottom) / leading).floor
  canvas.font("Helvetica", size: size)
  canvas.character_spacing(cspacing)
  canvas.horizontal_scaling(hscale)
  lines.first(rows_per_col * 2).each_slice(rows_per_col).each_with_index do |chunk, col|
    yy = top
    chunk.each do |line|
      canvas.text(line, at: [x[col], yy])
      yy -= leading
    end
  end
  canvas.character_spacing(0)
  canvas.horizontal_scaling(100)
  bottom
end

# Small footnote rule + tiny note at the page foot (academic artifact).
def draw_footnote(canvas, text)
  canvas.line(MARGIN, 56, MARGIN + 140, 56).stroke
  canvas.font("Helvetica", size: 6)
  canvas.text(text, at: [MARGIN, 46])
end

def add_link_annot(doc, page, rect, uri)
  annot = doc.add({Type: :Annot, Subtype: :Link, Rect: rect, Border: [0, 0, 0],
                   A: {Type: :Action, S: :URI, URI: uri}})
  (page[:Annots] ||= []) << annot
end

def add_highlight_annot(doc, page, rect, contents)
  x0, y0, x1, y1 = rect
  annot = doc.add({Type: :Annot, Subtype: :Highlight, Rect: rect,
                   QuadPoints: [x0, y1, x1, y1, x0, y0, x1, y0],
                   C: [1.0, 0.9, 0.2], Contents: contents})
  (page[:Annots] ||= []) << annot
end

def add_text_note_annot(doc, page, rect, contents)
  annot = doc.add({Type: :Annot, Subtype: :Text, Rect: rect, Name: :Note,
                   Open: false, Contents: contents})
  (page[:Annots] ||= []) << annot
end

# ============================================================================
# Benchmark PDFs — 4 tiers of increasing complexity
# ============================================================================

# --- 01_simple.pdf — 1 page: short text + one small ruled table -------------
HexaPDF::Document.new.tap do |doc|
  key = "1_simple"
  canvas = doc.pages.add(:A4).canvas
  y = draw_heading(canvas, 790, "Documento semplice")
  2.times { |i| y = draw_paragraph(canvas, y, "Paragrafo #{i + 1} #{sentinel('S', i)}. #{LOREM}") }
  rows = (1..6).map { |i| invoice_row(i) }
  register_cells("01_simple.pdf", rows)
  draw_ruled_table(canvas, y, rows)
  MANIFEST["01_simple.pdf"]["text_sentinels"] = MANIFEST.delete("0S")["text_sentinels"]
  MANIFEST["01_simple.pdf"]["pages"] = 1
  doc.write(File.join(PDF_DIR, "01_simple.pdf"), optimize: true)
end

# --- 02_medium.pdf — 6 pages: text + one ruled table per page ---------------
HexaPDF::Document.new.tap do |doc|
  sku = 0
  6.times do |pg|
    canvas = doc.pages.add(:A4).canvas
    y = draw_heading(canvas, 790, "Sezione #{pg + 1}")
    2.times do |i|
      y = draw_paragraph(canvas, y, "Paragrafo #{pg + 1}.#{i + 1} #{sentinel('M', pg * 2 + i)}. #{LOREM}")
    end
    rows = (1..10).map { |_| invoice_row(sku += 1) }
    register_cells("02_medium.pdf", rows)
    draw_ruled_table(canvas, y, rows)
  end
  MANIFEST["02_medium.pdf"]["text_sentinels"] = MANIFEST.delete("0M")["text_sentinels"]
  MANIFEST["02_medium.pdf"]["pages"] = 6
  doc.write(File.join(PDF_DIR, "02_medium.pdf"), optimize: true)
end

# --- 03_complex.pdf — 16 pages cycling text / ruled / borderless / form -----
# Mixed layouts stress different code paths: line geometry, text-alignment
# clustering, font filtering. Borderless cells are NOT counted in the tables
# ground truth (recovering them requires the :text strategy; the task measures
# default-settings behaviour).
HexaPDF::Document.new.tap do |doc|
  sku = 10_000
  sent = 0
  16.times do |pg|
    canvas = doc.pages.add(:A4).canvas
    case pg % 4
    when 0 # text page
      y = draw_heading(canvas, 790, "Capitolo #{pg / 4 + 1}")
      4.times do |i|
        y = draw_paragraph(canvas, y, "Paragrafo #{pg + 1}.#{i + 1} #{sentinel('C', sent += 1)}. #{LOREM}")
      end
    when 1 # ruled table page
      y = draw_heading(canvas, 790, "Dettaglio fattura #{pg / 4 + 1}")
      y = draw_paragraph(canvas, y, "Righe di dettaglio #{sentinel('C', sent += 1)}.")
      rows = (1..18).map { |_| invoice_row(sku += 1) }
      register_cells("03_complex.pdf", rows)
      draw_ruled_table(canvas, y, rows)
    when 2 # borderless table page
      y = draw_heading(canvas, 790, "Distinta #{pg / 4 + 1} (senza bordi)")
      y = draw_paragraph(canvas, y, "Colonne allineate #{sentinel('C', sent += 1)}.")
      rows = (1..15).map { |_| invoice_row(sku += 1) }
      draw_borderless_table(canvas, y, rows)
    when 3 # stamped form page (Helvetica template + Courier data)
      stamped_form_canvas(canvas, courier_extra: sentinel("C", sent += 1))
    end
  end
  MANIFEST["03_complex.pdf"]["text_sentinels"] = MANIFEST.delete("0C")["text_sentinels"]
  MANIFEST["03_complex.pdf"]["pages"] = 16
  doc.write(File.join(PDF_DIR, "03_complex.pdf"), optimize: true)
end

# --- 04_heavy.pdf — 60 pages: dense text + a ruled table on every page ------
HexaPDF::Document.new.tap do |doc|
  sku = 50_000
  60.times do |pg|
    canvas = doc.pages.add(:A4).canvas
    y = draw_heading(canvas, 790, "Pagina #{pg + 1}")
    3.times do |i|
      y = draw_paragraph(canvas, y, "Paragrafo #{pg + 1}.#{i + 1} #{sentinel('H', pg * 3 + i)}. #{LOREM} #{LOREM}")
    end
    rows = (1..12).map { |_| invoice_row(sku += 1) }
    register_cells("04_heavy.pdf", rows)
    draw_ruled_table(canvas, y, rows)
  end
  MANIFEST["04_heavy.pdf"]["text_sentinels"] = MANIFEST.delete("0H")["text_sentinels"]
  MANIFEST["04_heavy.pdf"]["pages"] = 60
  doc.write(File.join(PDF_DIR, "04_heavy.pdf"), optimize: true)
end

# --- 05_academic.pdf — 520 pages: a dense academic paper -------------------
# The heaviest tier, more onerous than 04_heavy on every axis. A simulated
# journal article whose pages cycle through five layouts, each packing a
# different artifact:
#   * condensed two-column body text (small font, negative char spacing,
#     horizontal scaling < 100%) + footnotes + highlight annotations
#   * ruled tables (counted in the ground truth) + caption + citation link
#   * embedded figure images (PNG XObjects) + caption + margin note
#   * very-condensed equation/derivation blocks (horizontal scaling 70%)
#   * borderless appendix tables (NOT counted) + condensed body
# Stresses page count, geometry clustering, font filtering, image XObjects and
# the annotation layer all at once.
HexaPDF::Document.new.tap do |doc|
  pages = 520
  sku = 90_000
  sent = 0
  next_sent = -> { sentinel("A", sent += 1) }
  body = -> (reps) { wrap_text(([ACADEMIC_LOREM] * reps).join(" "), 72) }

  # Title / abstract page (institution logo image + a margin review note).
  page = doc.pages.add(:A4)
  canvas = page.canvas
  y = draw_heading(canvas, 800,
                   "Composable Primitives for Robust PDF Extraction", size: 18)
  canvas.font("Helvetica", size: 10, variant: :bold)
  canvas.text("Azienda S.R.L. — Research Division", at: [MARGIN, y])
  y -= 24
  canvas.image(academic_figure_png(0), at: [MARGIN, y - 80], width: 120)
  y -= 100
  y = draw_heading(canvas, y, "Abstract", size: 12)
  draw_two_columns(canvas, y, body.call(4), size: 9, leading: 12, hscale: 90)
  add_text_note_annot(doc, page, [540, 800, 555, 820], "Review copy — do not cite.")

  (1...pages).each do |pg|
    page = doc.pages.add(:A4)
    canvas = page.canvas
    head_y = draw_heading(canvas, 800, "Section #{pg}", size: 12)

    case (pg - 1) % 5
    when 0 # condensed two-column body + footnote + highlight
      lead = draw_paragraph(canvas, head_y, "#{next_sent.call}.", size: 8)
      draw_two_columns(canvas, lead, body.call(8))
      draw_footnote(canvas, "1. #{LOREM[0, 110]}")
      add_highlight_annot(doc, page, [MARGIN, lead - 9, MARGIN + 130, lead + 2],
                          "key claim")
    when 1 # ruled table (counted) + caption + citation link
      ty = draw_paragraph(canvas, head_y,
                          "Table #{pg}: experimental measurements #{next_sent.call}.", size: 8)
      rows = (1..10).map { |_| invoice_row(sku += 1) }
      register_cells("05_academic.pdf", rows)
      after = draw_ruled_table(canvas, ty, rows)
      draw_two_columns(canvas, after, body.call(4))
      add_link_annot(doc, page, [MARGIN, 70, MARGIN + 190, 84],
                     "https://github.com/retsef/rpdfium")
    when 2 # embedded figure + caption + condensed body + margin note
      canvas.image(academic_figure_png(pg % 3 + 1), at: [MARGIN, head_y - 110],
                   width: 180)
      cap_y = head_y - 122
      canvas.font("Helvetica", size: 8, variant: :bold)
      canvas.text("Figure #{pg}: synthetic results #{next_sent.call}.", at: [MARGIN, cap_y])
      draw_two_columns(canvas, cap_y - 14, body.call(5))
      add_text_note_annot(doc, page, [540, cap_y, 555, cap_y + 15], "figure regenerated")
    when 3 # very-condensed equation / derivation block
      y2 = draw_paragraph(canvas, head_y, "Derivation #{next_sent.call}.", size: 8)
      eqns = (["x_i = sum_{j=0}^{n} a_{ij} b_j + e_i"] * 6).join("  ")
      draw_two_columns(canvas, y2, wrap_text("#{eqns} #{ACADEMIC_LOREM} #{ACADEMIC_LOREM}", 92),
                       size: 7, leading: 8.5, hscale: 70, cspacing: -0.4)
    when 4 # borderless appendix table (NOT counted) + condensed body
      y2 = draw_paragraph(canvas, head_y, "Appendix listing #{next_sent.call}.", size: 8)
      rows = (1..12).map { |_| invoice_row(sku += 1) }
      after = draw_borderless_table(canvas, y2, rows)
      draw_two_columns(canvas, after, body.call(4))
    end
  end

  MANIFEST["05_academic.pdf"]["text_sentinels"] = MANIFEST.delete("0A")["text_sentinels"]
  MANIFEST["05_academic.pdf"]["pages"] = pages
  doc.write(File.join(PDF_DIR, "05_academic.pdf"), optimize: true)
end

MANIFEST.each_value { |v| v["table_cells"].uniq!; v["text_sentinels"].uniq! }
File.write(File.join(PDF_DIR, "expected.json"), JSON.pretty_generate(MANIFEST))

# ============================================================================
# Documentation-site sample PDFs (one per topic) — unchanged content
# ============================================================================

def invoice_rows_legacy(count)
  (1..count).map do |i|
    qty = (i % 7) + 1
    unit = 10.0 + (i * 3.17 % 90)
    ["SKU-#{format('%04d', i)}", "Servizio di esempio n. #{i}", qty.to_s,
     format("%.2f", unit), format("%.2f", qty * unit)]
  end
end

def logo_png_path
  path = File.join(Dir.tmpdir, "rpdfium_doc_logo.png")
  size = 48
  rgba = +""
  size.times do |y|
    size.times do |x|
      inner = x.between?(12, 35) && y.between?(12, 35)
      rgba << (inner ? "\xFF\xFF\xFF\xFF".b : "\x1f\x4e\x8c\xFF".b)
    end
  end
  Rpdfium::IO::PNG.write(path, size, size, rgba)
  path
end

def borderless_table_canvas(canvas, title, rows)
  canvas.font("Helvetica", size: 12, variant: :bold)
  canvas.text(title, at: [50, 790])
  cols = [50, 130, 330, 400, 480]
  canvas.font("Helvetica", size: 9, variant: :bold)
  %w[Codice Descrizione Q.ta Prezzo Totale].each_with_index do |h, ci|
    canvas.text(h, at: [cols[ci], 760])
  end
  canvas.font("Helvetica", size: 9)
  rows.each_with_index do |row, ri|
    y = 745 - ri * 18
    row.each_with_index { |cell, ci| canvas.text(cell, at: [cols[ci], y]) }
  end
end

# --- text.pdf — 2 pages of structured text (Text & characters guide) --------
HexaPDF::Composer.create(File.join(SITE_ASSETS_DIR, "text.pdf"),
                         page_size: :A4, margin: 50) do |c|
  c.text("Relazione di esempio", font: ["Helvetica", variant: :bold],
         font_size: 18, margin: [0, 0, 4, 0])
  c.text("Azienda S.R.L. — P.IVA 01234567890", font: "Helvetica",
         font_size: 9, margin: [0, 0, 14, 0])
  4.times do |i|
    c.text("Sezione #{i + 1}", font: ["Helvetica", variant: :bold],
           font_size: 13, margin: [6, 0, 6, 0])
    3.times do
      c.text(LOREM, font: "Helvetica", font_size: 10, line_spacing: 1.35,
             margin: [0, 0, 8, 0])
    end
  end
end

# --- table.pdf — page 1 ruled table, page 2 borderless (Tables guide) -------
HexaPDF::Document.new.tap do |doc|
  HexaPDF::Composer.create(File.join(Dir.tmpdir, "rpdfium_doc_ruled.pdf"),
                           page_size: :A4, margin: 50) do |c|
    c.text("Fattura — righe con bordi", font: ["Helvetica", variant: :bold],
           font_size: 16, margin: [0, 0, 12, 0])
    header = [%w[Codice Descrizione Q.ta Prezzo Totale]]
    c.table(header + invoice_rows_legacy(12), column_widths: [70, 220, 40, 70, 70],
            header: ->(_tb) { header })
  end
  ruled = HexaPDF::Document.open(File.join(Dir.tmpdir, "rpdfium_doc_ruled.pdf"))
  doc.pages << doc.import(ruled.pages[0])
  borderless_table_canvas(doc.pages.add(:A4).canvas,
                          "Distinta — colonne senza bordi", invoice_rows_legacy(12))
  doc.write(File.join(SITE_ASSETS_DIR, "table.pdf"), optimize: true)
end

# --- form.pdf — interactive AcroForm fields + stamped Courier data ----------
HexaPDF::Document.new.tap do |doc|
  page = doc.pages.add(:A4)
  canvas = page.canvas
  stamped_form_canvas(canvas)

  canvas.font("Helvetica", size: 10, variant: :bold)
  canvas.text("RISERVATO ALL'UFFICIO (campi compilabili)", at: [50, 400])
  canvas.font("Helvetica", size: 7)
  canvas.text("operatore", at: [50, 380])
  canvas.text("protocollo", at: [250, 380])
  canvas.text("verificato", at: [420, 380])

  form = doc.acro_form(create: true)
  operatore = form.create_text_field("operatore", font_size: 10)
  operatore.create_widget(page, Rect: [50, 355, 230, 375])
  operatore.field_value = "Mario Rossi"
  protocollo = form.create_text_field("protocollo", font_size: 10)
  protocollo.create_widget(page, Rect: [250, 355, 400, 375])
  protocollo.field_value = "2026-001234"
  verificato = form.create_check_box("verificato")
  verificato.create_widget(page, Rect: [420, 355, 440, 375])
  verificato.field_value = true

  doc.write(File.join(SITE_ASSETS_DIR, "form.pdf"), optimize: true)
end

# --- example.pdf — the invoice used in Getting started ----------------------
composer = HexaPDF::Composer.new(page_size: :A4, margin: 50)
composer.image(logo_png_path, width: 36, margin: [0, 0, 8, 0])
composer.text("Azienda S.R.L.", font: ["Helvetica", variant: :bold],
              font_size: 20)
composer.text("CITTA XX VIA ESEMPIO 1 — P.IVA 01234567890",
              font: "Helvetica", font_size: 9, margin: [2, 0, 16, 0])
composer.text("Fattura n. 2026-042 del 15/05/2026",
              font: ["Helvetica", variant: :bold], font_size: 12,
              margin: [0, 0, 12, 0])
header = [%w[Codice Descrizione Q.ta Prezzo Totale]]
composer.table(header + invoice_rows_legacy(8) +
                 [["", "", "", "Imponibile", "1.265,40"],
                  ["", "", "", "IVA 22%", "278,39"],
                  ["", "", "", "TOTALE", "1.543,79"]],
               column_widths: [70, 220, 40, 70, 70])
composer.text("Pagamento a 30 giorni data fattura. Condizioni complete su " \
              "https://github.com/retsef/rpdfium. #{LOREM}",
              font: "Helvetica", font_size: 8, line_spacing: 1.3,
              margin: [14, 0, 0, 0])
doc = composer.document
doc.trailer.info[:Title] = "Fattura di esempio"
doc.trailer.info[:Author] = "Azienda S.R.L."
link = doc.add({Type: :Annot, Subtype: :Link, Rect: [50, 60, 250, 75],
                Border: [0, 0, 0],
                A: {Type: :Action, S: :URI,
                    URI: "https://github.com/retsef/rpdfium"}})
(doc.pages[0][:Annots] ||= []) << link
doc.write(File.join(SITE_ASSETS_DIR, "example.pdf"), optimize: true)

puts "Generated:"
(Dir[File.join(PDF_DIR, "*")] + Dir[File.join(SITE_ASSETS_DIR, "*.pdf")]).sort.each do |f|
  puts format("  %-60s %8.1f KB", f.sub("#{File.expand_path('..', __dir__)}/", ""),
              File.size(f) / 1024.0)
end
