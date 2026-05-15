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
| 🚧 | XFA form support |
| 🚧 | Structure tree traversal (PDF tagged → semantic tables) |
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
