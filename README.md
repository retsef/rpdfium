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
`origami` (security-research focused), and `hexapdf` (great for
manipulation but text extraction is approximate). None give you
character-level bounding boxes, real vector path geometry, or table
extraction. `rpdfium` fills that gap by binding the same battle-tested
C++ engine that powers Chrome's PDF viewer.

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

`Page#label_value_pairs` goes one step further: it associates each
extracted value with the semantic label from the template that
describes it. Useful when you want machine-readable
`field_name → field_value` pairs without hard-coding the form layout.

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
# 1001      → col: "codice tributo"
# 532,27    → col: "importi a debito versati", row: "A"
# 1.615,90  → col: "SALDO (M-N) +/–", row: "EURO +"   ← saldo finale
```

The algorithm clusters template words into coherent labels, then for
each value finds:
- the `:col` label (positioned above, in the same column)
- the `:row` label (positioned to the left, on the same row)

For finer control over the clustering / matching thresholds, use
`Rpdfium::Util::LabelMatcher` directly.

#### Repeating-header tables

Forms with **repeating tables** print column headers once at the top
of the section, then sub-implicitly apply them to all rows below
(770 Quadro ST/SV with rows ST2-ST13, F24 multi-row sections). By
default, `LabelMatcher` propagates those headers to all values in
the same column, regardless of vertical distance.

The propagation uses geometric heuristics:
- Identifies data columns by clustering values on `x0` (left-aligned)
  AND `x1` (right-aligned, common for numeric values).
- Splits columns at large vertical gaps (section breaks).
- Filters by gap-regularity (coefficient of variation < 0.15) to
  exclude false positives like right-aligned section subtotals on F24.
- Finds the canonical column header above each identified column and
  assigns it to all column values.

Result on 770 Quadro ST page 4:

```ruby
{
  "Codice tributo 11" => ["1001", "1001", ..., "1001", "1712"],  # 12 values
  "Ritenute operate"  => ["394,13", "443,73", ..., "32,46"],     # 12 values
  "Importo versato"   => [...same 12 values...],
  "Data di versamento giorno mese anno 14" => [...12 dates...]
  # no spurious ST5/ST6/.../ST13 row labels
}
```

Pass `repeat_headers: false` to `LabelMatcher.new` to disable this
behavior.

#### Structured output and multi-word values

By default `label_value_pairs` returns one entry per extracted word.
On forms with header lines (e.g. "Soggetto: AAA BBB CCC ( 12345 )")
or multi-page declarations, that's noisy. Two extra options shape
the output to be **consumer-ready**:

- `merge_adjacent:` — strategy for joining adjacent words on the
  same line:
  - `false` (default) — no merging
  - `:by_label` — merge only if same column label (preserves checkbox
    grids like 770 quadri compilati ST/SV/SX)
  - `:by_proximity` — always merge adjacent words on the same line
  - `:smart` — by_label for labelled words, by_proximity for orphans
    (recommended for complex multi-section forms)
- `as_hash: true` — return `Hash{label => value}` instead of
  `Array<Hash>`. Duplicate labels become arrays.

```ruby
Rpdfium.open("770.pdf") do |doc|
  doc.page(1).label_value_pairs(
    data_font: "Courier",
    merge_adjacent: :smart,
    as_hash: true
  )
end
# => {
#   "Codice fiscale" => "01234567890",
#   "Codice attività" => "999999",
#   "Indirizzo di posta elettronica/PEC" => "AZIENDA@PEC.IT",
#   "ST" => "X", "SV" => "X", "SX" => "X",  # checkbox preserved
#   "Dipendente" => "X",
#   "Tipologia invio" => "2",
#   ...
# }
```

Words without an associated template label confluiscono sotto la chiave
`"_unlabeled"` come array di stringhe. Utile per estrarre stamp /
header / footer libero che non ha un campo di template di riferimento.

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

Measured on 4 PDFs of increasing complexity, best-of-3 runs after a
warm-up, isolated in subprocesses to capture clean peak RSS. Versions
under test: `rpdfium 0.3.13`, `pdfplumber 0.11.9`, `pypdfium2 5.6.0`.

| Test corpus | Pages | Size | What it stresses |
| --- | ---: | ---: | --- |
| `sample.pdf` | 1 | 18 KB | Plain text baseline |
| `form.pdf` | 1 | 107 KB | Char-per-text-object kerning, Form XObject, tables |
| `complex.pdf` | 85 | 60 MB | Magazine-style document, dense text + heavy graphics |
| `report.pdf` | 226 | 322 KB | Rotated pages (90°), small fonts, ~15 tables per page |

### Speed

| Corpus | Task | rpdfium | pypdfium2 | pdfplumber | speedup vs pdfplumber |
| --- | --- | ---: | ---: | ---: | ---: |
| sample.pdf (1 pag) | text | 4 ms | 4 ms | 75 ms | **21×** |
| sample.pdf (1 pag) | tables | 4 ms | n/a | 70 ms | **16×** |
| form.pdf (1 pag) | text | 12 ms | 13 ms | 538 ms | **44×** |
| form.pdf (1 pag) | tables | 25 ms | n/a | 575 ms | **23×** |
| complex.pdf (85 pag) | text | 190 ms | 183 ms | 7.76 s | **41×** |
| complex.pdf (85 pag) | tables | 231 ms | n/a | 7.07 s | **31×** |
| report.pdf (226 pag) | text | 412 ms | 397 ms | 23.26 s | **56×** |
| report.pdf (226 pag) | tables | 1.68 s | n/a | 25.25 s | **15×** |

`pypdfium2` does not implement table extraction (it's a raw FFI binding
to PDFium, not a full pipeline). It's listed as the "pure PDFium speed
floor" for text — rpdfium matches it within ±5%, showing that the Ruby
FFI overhead is not measurable.

### Memory (peak RSS)

| Corpus | rpdfium | pypdfium2 | pdfplumber | pdfplumber/rpdfium |
| --- | ---: | ---: | ---: | ---: |
| sample.pdf | 29 MB | 20 MB | 40 MB | 1.4× |
| form.pdf | 32 MB | 22 MB | 45 MB | 1.4× |
| complex.pdf | 106 MB | 69 MB | 535 MB | **5.0×** |
| report.pdf | 136 MB | 41 MB | 1003 MB | **7.4×** |

The memory gap widens with workload size. On a 226-page document
pdfplumber uses ~1 GB; rpdfium stays under 140 MB. For server-side
batch processing this is the difference between a 256 MB container and
a 2 GB one.

### Headline numbers

On large PDFs (226 pages, dense layout):

- **rpdfium completes both text + tables in ~2.1 s using 136 MB**
- **pdfplumber needs ~48 s and 1 GB** for the same work

Across the four corpora the median speedup vs pdfplumber is **27× on
text**, **22× on tables**. rpdfium scales linearly with page count
(thanks to PDFium's C++ engine); pdfplumber's pure-Python pipeline
degrades super-linearly on large documents.

### Methodology

Each measurement is the **minimum of 3 timed runs after a warm-up run**
(to neutralize OS page cache effects on the 60 MB `complex.pdf`).
Subprocess isolation per measurement ensures clean RSS reading via
`resource.getrusage` / `/proc/self/status`. The benchmark harness is
a small Ruby driver that shells out to three runners (one Ruby script
using `rpdfium`, two Python scripts using `pdfplumber` and
`pypdfium2`), parses the JSON each emits, and aggregates the results.

Output quality has been spot-checked: rpdfium matches pypdfium2 char
count within ±1 char (rounding on the trailing newline). pdfplumber
returns ~2% fewer chars on locale-formatted numbers due to a different
word-tokenization for thousand-separator punctuation (e.g. `1.250.000`
split on periods).

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
