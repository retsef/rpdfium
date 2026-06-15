# rpdfium

Ruby bindings for [PDFium](https://pdfium.googlesource.com/pdfium/), the
PDF engine that powers Chrome's viewer. Provides text extraction with
character-level metadata, vector path access, image extraction, form
fields, page rendering, and pdfplumber-style table detection.

Inspired by [`pypdfium2`](https://github.com/pypdfium2-team/pypdfium2)
(bindings layout) and [`pdfplumber`](https://github.com/jsvine/pdfplumber)
(table heuristics).

```ruby
require "rpdfium"

Rpdfium.open("invoice.pdf") do |doc|
  puts doc.metadata[:title]

  doc.each do |page|
    puts page.text
    Rpdfium::Table::Extractor.new(page).extract.each do |table|
      table.each { |row| puts row.inspect }
    end
  end
end
```

## Why

The Ruby ecosystem has `pdf-reader` (text only, slow on complex docs),
`origami` (security-research focused), and `hexapdf` — a capable library that
does extract text with character positioning, but is AGPL / commercially
licensed and has no table-detection pipeline or page rasterization. I needed a
permissively licensed alternative that adds pdfplumber-style table extraction
and page rendering on top of character-level metadata. `rpdfium` fills that gap
by binding the same battle-tested C++ engine that powers Chrome's PDF viewer,
under Apache-2.0.

In practice it matches the speed of Python's `pypdfium2` on text
extraction and is **15-56× faster than `pdfplumber`** while using
**5-7× less memory** on large documents. See [Performance](#performance)
for details.

## Installing PDFium

`rpdfium` itself ships only Ruby code. The native library is loaded
from one of, in order:

- `ENV["PDFIUM_LIBRARY_PATH"]` (highest priority — point to a
  `libpdfium.{so,dylib,dll}` of your choice)
- the [`rpdfium-binary`](https://github.com/retsef/rpdfium-binary)
  companion gem (recommended), which ships precompiled PDFium binaries
  for major platforms via [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries)
- the system `libpdfium` (if installed via your package manager)

### Recommended: use `rpdfium-binary`

```bash
gem install rpdfium-binary
```

RubyGems picks the right platform-specific gem automatically. Supported
platforms include `x86_64-linux`, `aarch64-linux`, `x86_64-linux-musl`,
`aarch64-linux-musl`, `arm64-darwin`, `x86_64-darwin`, `x64-mingw-ucrt`,
`x86-mingw32`, `aarch64-mingw-ucrt`. For unsupported platforms the
generic Ruby-platform gem is installed and the binary is downloaded on
first use into the user data directory.

Add to your `Gemfile`:

```ruby
gem "rpdfium"
gem "rpdfium-binary"
```

### Alternative: manual `PDFIUM_LIBRARY_PATH`

Useful in containers, CI, or when you need a specific PDFium build:

```bash
# macOS arm64
curl -L https://github.com/bblanchon/pdfium-binaries/releases/latest/download/pdfium-mac-arm64.tgz | tar xz
export PDFIUM_LIBRARY_PATH=$PWD/lib/libpdfium.dylib
```

## Architecture

Three layers, mirroring `pypdfium2`:

1. **`Rpdfium::Raw`** — pure FFI bindings, 1:1 with the C API
   (`FPDF_*`, `FPDFText_*`, `FPDFBitmap_*`, `FPDFPath_*`,
   `FPDFImageObj_*`, `FPDFAnnot_*`). Use directly if you need something
   the wrappers don't expose.
2. **`Rpdfium::Document, ::Page, ::TextPage, ::Image::Embedded,
   ::Annotation, ::Form::Field, ::Search, ::Outline, ::Attachment`** —
   RAII-style wrappers with `ObjectSpace.define_finalizer` so handles
   are released even if you forget `close`.
3. **`Rpdfium::Table::Extractor`** — table detection on top of layer 2,
   with `Rpdfium::Table::Debugger` for visual debugging.

## What you can do

### Text

```ruby
page.text                       # plain string
page.text_in_bbox(left: 50, top: 100, right: 300, bottom: 150)
```

### Character-level metadata

Per-char data essential for layout-aware processing — bounding box,
font, weight, origin, rotation angle, plus PDFium's "character
provenance" flags:

```ruby
page.chars.first
# {
#   char:     "T",
#   codepoint: 84,
#   x0: 72.0, x1: 79.2, top: 100.5, bottom: 112.3,
#   origin_x: 72.0, origin_y: 110.8,
#   angle:    0.0,                  # radians (rotated text)
#   fontsize: 12.0,
#   font:     "Helvetica-Bold",
#   weight:   700,
#   render_mode: 0,                 # 0=fill 1=stroke 2=both 3=invisible
#   generated: false,               # true → inserted by PDFium (e.g. spaces)
#   hyphen:    false,               # true → soft-hyphen for line break
#   unicode_error: false            # true → couldn't map glyph to unicode
# }
```

`generated`/`hyphen`/`unicode_error` are the **artefact recognition
flags** — distinguishing real characters from PDFium-synthesized ones is
crucial when you don't want fake whitespace to widen a column.

Loose char boxes (proportional to font size, more stable for layout
algorithms):

```ruby
page.chars(loose: true)
```

Cluster chars into words automatically:

```ruby
page.words(x_tolerance: 3.0, y_tolerance: 3.0)
# [{ text: "Invoice", x0: 72.0, x1: 110.5, top: 100.5, bottom: 112.3,
#    fontsize: 12.0, font: "Helvetica-Bold", chars: [...] }, ...]
```

### Vector paths

Real path-segment iteration (not just bounding boxes), with state
machine for `closepath`. Useful for table line detection, signatures,
form layout analysis:

```ruby
page.line_segments
# [{ x0: 72.0, y0: 100.0, x1: 540.0, y1: 100.0, stroke_width: 0.5 }, ...]

page.horizontal_lines
page.vertical_lines
```

### Images

```ruby
page.images.each do |img|
  meta = img.metadata
  puts "#{meta[:width]}×#{meta[:height]} @ #{meta[:horizontal_dpi]} DPI, " \
         "#{meta[:colorspace]}"
  puts "filters: #{img.filters}"   # e.g. ["DCTDecode"] for JPEG

  # JPEG passthrough when filters == ["DCTDecode"]; otherwise rendered to PNG
  img.save("img_#{img.bbox[:x0].to_i}.jpg")

  # Or get raw/decoded bytes for custom processing
  img.raw_bytes      # as stored
  img.decoded_bytes  # post-filters (raster)
end
```

### Annotations & links

```ruby
page.annotations.each do |a|
  puts "#{a.subtype}: #{a[:Contents]} at #{a.bbox.inspect}"
end

page.links.each do |link|
  puts link.link_uri || "→ page #{link.link_dest_page}"
end
```

### Forms (read-only)

```ruby
doc = Rpdfium.open("form.pdf")
puts doc.form_type            # :acroform / :xfa_full / :xfa_foreground / :none

doc.each do |page|
  page.form_fields.each do |f|
    pp f.to_h
    # { name: "name", type: :textfield, value: "Mario Rossi",
    #   readonly: false, required: true, bbox: {...} }
  end
end
```

### Outline (bookmarks) & attachments

```ruby
Rpdfium::Outline.flatten(doc.outline) do |item, depth|
  puts "#{"  " * depth}- #{item.title} (page #{item.page_index})"
end

doc.attachments.each { |a| a.save("attached_#{a.name}") }
```

### Search

```ruby
page.search("totale", match_case: false).each_match do |m|
  puts "found '#{m[:text]}' at #{m[:rects].first.inspect}"
end
```

### Rendering

```ruby
# Pure-Ruby PNG writer, zero deps:
page.render_to_png("page.png", scale: 2.0, include_annotations: true,
                   include_forms: true)

# Or get raw RGBA/BGRA/Gray bytes:
w, h, bytes, stride = page.render(scale: 2.0, output: :rgba)
```

### Tables

`pdfplumber`-style settings — every parameter you'd recognize:

```ruby
extractor = Rpdfium::Table::Extractor.new(page,
                                          vertical_strategy:        :lines,    # :lines / :lines_strict / :text / :explicit
                                          horizontal_strategy:      :lines,
                                          snap_tolerance:           3.0,
                                          join_tolerance:           3.0,
                                          edge_min_length:          3.0,
                                          edge_min_length_prefilter: 1.0,
                                          intersection_tolerance:   3.0,
                                          min_words_vertical:       3,
                                          min_words_horizontal:     1,
                                          text_x_tolerance:         3.0,
                                          text_y_tolerance:         3.0,
                                          explicit_vertical_lines:  [],         # [Float] x-coords or [Hash{x:, top:, bottom:}]
                                          explicit_horizontal_lines: [],
                                          auto_fallback:            true        # try :text if :lines finds nothing
)

extractor.tables.each do |table|
  table.bbox             # => [x0, top, x1, bottom]
  table.rows             # => Array<Array<bbox|nil>>
  table.columns          # => Array<Array<bbox|nil>>
  table.extract          # => Array<Array<String>>
end

extractor.extract  # shortcut: => [[[String, ...], ...], ...]   (list of tables)
extractor.edges    # post-snap/join edges
extractor.intersections   # Hash{[x,y] => {v:[edges], h:[edges]}}
extractor.cells           # Array<bbox>
```

The pipeline mirrors `pdfplumber.TableFinder` 1:1 and uses the same
algorithms for words-to-edges, intersections-to-cells, cells-to-tables.

Visual debugger (saves PNG with overlay: red lines, green intersections,
blue table fills):

```ruby
Rpdfium::Table::Debugger.visualize(page, "debug.png",
                                   vertical_strategy: :lines)
```

### Form-aware extraction (font filtering)

Some PDFs are "filled-out forms" — F24, tax declarations, payment
slips, government forms — where the form template and the entered
data both exist as static graphics text on the page (no AcroForm
fields, no tagged structure). On these PDFs the table pipeline picks
up the template labels as noise alongside the data.

The robust strategy is to separate chars by **role** using their
font: the template typically uses proportional fonts (Futura, Times,
Helvetica) while the data layer uses a single font (often Courier
monospace, or Helvetica at a specific size).

```ruby
Rpdfium.open("f24.pdf") do |doc|
  page = doc.page(0)

  # Discover what fonts are on the page
  page.font_inventory.first(5).each do |g|
    puts "#{g[:font].ljust(20)} h=#{g[:height]} | #{g[:count]} chars | #{g[:sample][0,40]}"
  end
  # Futura-Light          h=8.3  |  946 chars | "cognome, denominazione o ragione sociale"
  # Courier               h=10.5 |  365 chars | "01234567890Azienda S.R.L.P"
  # Futura-Bold           h=10.4 |  249 chars | "CODICE FISCALEDATI ANAGRAFICI..."
  # ...

  # Extract just the entered data, line by line
  page.lines(font: "Courier").each { |l| puts l }
  # => "Soggetto:  Azienda S.R.L.  ( 01234567890 )"
  # => "1001  11  2021  499,81  0,00"
  # => "1712  12  2021  32,46  0,00"
  # => "1701  11  2021  0,00  295,89"
  # => "532,27  295,89  236,38"
  # => ...
end
```

Three primitives:

- `Page#font_inventory` — distribution by `(font, height, weight)`,
  with counts and samples for ispection
- `Page#chars_where(font:, height:, weight:, bbox:, where:)` —
  filter chars by any combination of criteria
- `Page#lines(font:, ...)` — high-level helper: filter + word
  extraction + line clustering, returns `Array<String>`

Works on F24 payment forms, VAT periodic communications, withholding
tax declarations, and similar government forms — anywhere the data
sits on a printed template as text.

#### Label-value pairing

`Page#label_value_pairs` associates each extracted value with the
semantic label from the template that describes it. Useful when you
want machine-readable `field_name → field_value` pairs without
hard-coding the form layout.

```ruby
Rpdfium.open("f24.pdf") do |doc|
  pairs = doc.page(0).label_value_pairs(
    data_font: "Courier",
    template_font: /^Futura/,
    data_filter: ->(t) { t.match?(/^[\d.,]+$/) }
  )
  pairs.each do |p|
    col = p[:labels][:col]
    row = p[:labels][:row]
    puts "#{p[:value].ljust(12)} → col: #{col}, row: #{row}"
  end
end
# 499,81    → col: "importi a debito versati"
# 1.615,90  → col: "SALDO (M-N) +/–", row: "EURO +"   ← saldo finale
```

The algorithm clusters template words into coherent labels, then for
each value finds the `:col` label (positioned above) and the `:row`
label (positioned to the left).

#### Composable primitives for complex forms

For complex forms with repeating tables, boxed-layout cells, or
multi-word values, compose three primitives:

**`Util::WordMerger`** — join adjacent words on the same line:

```ruby
merger = Rpdfium::Util::WordMerger.new(x_gap: 20.0, y_tol: 3.0)
merged = merger.merge_by_proximity(words)
# or, with labels mapping to preserve checkbox grids:
merged = merger.merge_by_label(words, label_per_word)
# or, only merge orphans (no label assigned):
merged = merger.merge_unlabeled(words, label_per_word)
```

**`Util::ColumnInference`** — identify data columns by alignment:

```ruby
inference = Rpdfium::Util::ColumnInference.new(
  x_tolerance: 3.0,
  min_size: 3,
  cv_threshold: 0.15
)
columns = inference.infer(words)
# => [[word1, word2, ..., word12], ...]
```

Algorithm: cluster by `x0` (left-align) AND `x1` (right-align), split
columns at large vertical gaps, filter by gap-regularity (coefficient
of variation < 0.15) to exclude false positives.

**`Util::LabelMatcher`** with column inference enables header
propagation for repeating tables (e.g. 770 Quadro ST with rows
ST2..ST13 sharing column headers printed once at the top):

```ruby
matcher = Rpdfium::Util::LabelMatcher.new(
  column_inference: Rpdfium::Util::ColumnInference.new
)
pairs = page.label_value_pairs(data_font: "Courier", matcher: matcher)
```

For boxed-layout forms (cells separated by ~10pt with template
graphics for decimals), pass `inject_spaces: false, x_tolerance: 15.0`
to `label_value_pairs` and `row_max_dx: 400.0` to the matcher.

See `examples/adapters/` for complete working adapters that compose
these primitives for specific Italian tax forms (Modello 770,
Comunicazione IVA).

### Struct tree (Tagged PDF)

For tagged PDFs (PDF/UA, accessibility-friendly exports from
Word/LibreOffice/InDesign), `Page#struct_tree` exposes the document's
logical structure (Document → P, H1, Table, TR, TH, TD, Figure, ...)
independently of the visual layout. This gives **zero-geometry**
extraction with semantic typing (TH vs TD, RowSpan, ColSpan, Lang).

```ruby
page.struct_tree do |tree|
  next if tree.nil? || tree.empty?

  tree.tables.each do |table|
    rows = table.children.select { |c| c.type == "TR" }
    rows.each do |row|
      cells = row.children.select { |c| %w[TH TD].include?(c.type) }
      puts cells.map(&:text).map(&:strip).inspect
    end
  end
end
# => ["Region", "Revenue", "Growth"]      (TH)
# => ["Italy", "1.250.000", "+12%"]       (TD)
# => ...
```

API summary:

```ruby
tree = page.struct_tree     # → Tree or nil (nil if not tagged)
tree.empty?                 # true for "tagged but placeholder" PDFs
tree.roots                  # → [Element, ...]
tree.walk { |el| ... }      # depth-first
tree.find_all(type: "P")
tree.tables                 # → [Element, ...] where type == "Table"

element.type                # "P", "Table", "TR", "TD", ...
element.children            # → [Element, ...]
element.parent              # → Element or nil
element.text                # text via MCID + ActualText override
element.actual_text         # /ActualText (for ligature/math resolution)
element.alt_text            # /Alt (Figure / Formula)
element.lang                # "it-IT", "en-US", ...
element.marked_content_ids  # → [Integer]
element.attributes          # → { name => value }
```

Three possible states of `page.struct_tree`:

| PDF type | returns |
| --- | --- |
| Not tagged (most PDFs from line-of-business software, scanned PDFs) | `nil` |
| Tagged but empty (some bank statements have placeholder StructTreeRoot) | `Tree` with `empty? == true` |
| Properly tagged (Word/LibreOffice/InDesign export with accessibility tags) | Navigable `Tree` |

Lifecycle: prefer the block form for deterministic close. The implicit
form (no block) leaves cleanup to `FPDF_CloseDocument` — no leak, just
the tree stays in memory until the document is closed.

## Performance

The full, reproducible benchmark suite — sample PDFs, runners, ground-truth
correctness scoring, and methodology — lives in
[`benchmark/`](benchmark/README.md). It compares **rpdfium** against
**pypdfium2** (the "pure PDFium speed floor"), **pdfplumber** (the reference
pure-Python pipeline) and **hexapdf** (pure Ruby) across four synthetic PDFs
of increasing complexity (1 → 60 pages), measuring **execution time**, **peak
memory (RSS)** and **correctness** (fraction of known ground-truth data
recovered). Run it yourself:

```bash
export PDFIUM_LIBRARY_PATH=/path/to/libpdfium.{so,dylib,dll}
pip install pdfplumber pypdfium2    # optional baselines
gem install hexapdf                 # optional baseline + table-extraction reference
ruby benchmark/run.rb
```

### Synthetic suite (Apple M-series, best of 3)

Text extraction — rpdfium tracks pypdfium2 within noise (FFI overhead not
measurable); pdfplumber degrades super-linearly:

| PDF | rpdfium | pypdfium2 | pdfplumber | hexapdf |
| --- | ---: | ---: | ---: | ---: |
| 01_simple (1 pg) | 12 ms / 33 MB | 11 ms / 36 MB | 16 ms / 41 MB | 12 ms / 23 MB |
| 02_medium (6 pg) | 14 ms / 34 MB | 13 ms / 36 MB | 97 ms / 57 MB | 18 ms / 24 MB |
| 03_complex (16 pg) | 15 ms / 36 MB | 16 ms / 37 MB | 184 ms / 72 MB | 25 ms / 25 MB |
| 04_heavy (60 pg) | 49 ms / 59 MB | 49 ms / 39 MB | **2.37 s / 455 MB** | 147 ms / 27 MB |

Table extraction (pypdfium2 has no table layer; the hexapdf column uses the
minimal lines-based reference in
[`benchmark/examples/hexapdf_table_extraction.rb`](benchmark/examples/hexapdf_table_extraction.rb)):

| PDF | rpdfium | pdfplumber | hexapdf |
| --- | ---: | ---: | ---: |
| 01_simple (1 pg) | 15 ms / 34 MB | 17 ms / 41 MB | 22 ms / 25 MB |
| 02_medium (6 pg) | 45 ms / 43 MB | 111 ms / 56 MB | 53 ms / 25 MB |
| 03_complex (16 pg) | 151 ms / 54 MB | 185 ms / 71 MB | 85 ms / 25 MB |
| 04_heavy (60 pg) | 791 ms / 265 MB | **2.96 s / 442 MB** | 752 ms / 28 MB |

Correctness is **100% for every library on every tier** — these are clean
generated grids, the easy case. Real-world tables (dashed rules, partial
borders, misaligned cells) are where rpdfium's snap/join tolerances and
`:text` fallback earn their cost; the 120-line hexapdf reference matches here
but would drop cells there. See
[`benchmark/README.md`](benchmark/README.md) for the full tables, task-support
matrix, correctness scoring and methodology.

### Real-world corpus

On larger, non-redistributable documents (`rpdfium 0.3.13`, `pdfplumber
0.11.9`, `pypdfium2 5.6.0`), the gap is wider: across a 1→226-page corpus the
median speedup vs pdfplumber is **27× on text** and **22× on tables**, with
peak RSS staying under 140 MB where pdfplumber reaches ~1 GB on 226 pages —
the difference between a 256 MB container and a 2 GB one.

## Memory safety

- `FPDF_LoadMemDocument64` does **not** copy the input bytes. The
  `Document` wrapper holds an FFI buffer reference for its lifetime so
  the GC can't free it early.
- Every PDFium handle (`*_Close*`) is wired to
  `ObjectSpace.define_finalizer` so abandoned objects don't leak native
  memory.
- `FPDF_InitLibrary` is called once per process under `Mutex`;
  `FPDF_DestroyLibrary` runs via `at_exit`.
- `Document#close` releases in cascade: form-fill env → cached pages →
  document handle.

## Roadmap

| Status | Feature |
|---|---|
| ✅ | Document open (path / IO / bytes / password) |
| ✅ | Document metadata, permissions, file version |
| ✅ | Page text + bbox-bounded text |
| ✅ | Per-character bounding boxes (tight & loose) |
| ✅ | Char metadata: font, weight, origin, angle, render mode |
| ✅ | PDFium-generated char detection (artefact filtering) |
| ✅ | Word clustering (layout-aware) |
| ✅ | Vector path segments (real geometry, not bbox) |
| ✅ | Image extraction (raw + decoded + rendered) |
| ✅ | Annotations + link URI/dest |
| ✅ | AcroForm field reading |
| ✅ | Bookmarks (outline) |
| ✅ | File attachments |
| ✅ | Internal text search |
| ✅ | Page rendering to RGBA/BGRA/Gray |
| ✅ | Pure-Ruby PNG writer (zero deps) |
| ✅ | Table extraction — `:lines` strategy |
| ✅ | Table extraction — `:text` strategy |
| ✅ | Table extraction — `:explicit` strategy |
| ✅ | Visual table debugger |
| ✅ | [`rpdfium-binary`](https://github.com/retsef/rpdfium-binary) companion gem with prebuilt PDFium |
| ✅ | Structure tree traversal (PDF tagged → semantic tables / `Page#struct_tree`) |
| ✅ | Form-aware extraction via font filtering (`Page#font_inventory`, `chars_where`, `lines`) |
| ✅ | Semantic label-value pairing on filled forms (`Page#label_value_pairs`, `Util::LabelMatcher`) |
| 🚧 | XFA form support |
| 🔮 | OCR fallback for scanned PDFs (via tesseract bindings) |
| 🔮 | Write APIs (we're read-only by design for now) |

## Why not pure-Ruby?

A correct PDF text extractor needs to interpret the content stream
(operators, font encodings including CMap-based CIDs, ToUnicode maps,
ActualText overrides, marked content). PDFium has ~15 years of
edge-case fixes baked in. Reimplementing it in Ruby would take years
and still be slower. FFI is the right call.

## License

Apache-2.0 (same as PDFium itself).
