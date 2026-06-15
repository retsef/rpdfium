---
title: Getting started
nav_order: 2
---

# Getting started
{: .no_toc }

1. TOC
{:toc}

---

## Installation

`rpdfium` requires Ruby ≥ 3.0 and has a single runtime dependency,
`ffi ~> 1.16`. The gem itself ships only Ruby code; the native PDFium
library is provided separately.

The recommended setup pairs `rpdfium` with the
[`rpdfium-binary`](https://github.com/retsef/rpdfium-binary) companion gem,
which ships precompiled PDFium binaries for major platforms:

```ruby
# Gemfile
gem "rpdfium"
gem "rpdfium-binary"
```

```bash
bundle install
# or, without Bundler:
gem install rpdfium rpdfium-binary
```

RubyGems picks the right platform-specific gem automatically. Supported
platforms include `x86_64-linux`, `aarch64-linux`, `x86_64-linux-musl`,
`aarch64-linux-musl`, `arm64-darwin`, `x86_64-darwin`, `x64-mingw-ucrt`,
`x86-mingw32`, and `aarch64-mingw-ucrt`.

### Pointing at your own PDFium build

In containers, CI, or when you need a specific PDFium build, set
`PDFIUM_LIBRARY_PATH` instead — it has the highest priority in the library
lookup (env var → `rpdfium-binary` → system `libpdfium`):

```bash
# macOS arm64 example
curl -L https://github.com/bblanchon/pdfium-binaries/releases/latest/download/pdfium-mac-arm64.tgz | tar xz
export PDFIUM_LIBRARY_PATH=$PWD/lib/libpdfium.dylib
```

Verify the install:

```bash
ruby -e 'require "rpdfium"; puts Rpdfium::VERSION'
```

## Usage

The examples throughout this documentation use a small synthetic invoice —
download [example.pdf]({{ site.baseurl }}/assets/pdfs/example.pdf) to follow
along. Open it, read its text, and pull out the line-items table:

```ruby
require "rpdfium"

Rpdfium.open("example.pdf") do |doc|
  page = doc.page(0)

  puts page.text.lines.first(3).join

  Rpdfium::Table::Extractor.new(page).extract.each do |table|
    table.first(3).each { |row| p row }
  end
end
```

Output:

```
Azienda S.R.L.
CITTA XX VIA ESEMPIO 1 — P.IVA 01234567890
Fattura n. 2026-042 del 15/05/2026
["Codice", "Descrizione", "Q.ta", "Prezzo", "Totale"]
["SKU-0001", "Servizio di esempio n. 1", "2", "13.17", "26.34"]
["SKU-0002", "Servizio di esempio n. 2", "3", "16.34", "49.02"]
```

For one-liners, top-level helpers open, process, and close in a single call:

```ruby
Rpdfium.extract_text("example.pdf")    # => Array<String>, one per page
Rpdfium.extract_tables("example.pdf")  # => all tables with page index
Rpdfium.render_to_pngs("example.pdf", output_dir: "out", scale: 2.0)
```

## Feature overview

- Text extraction with **per-character metadata** — bounding boxes, font,
  weight, rotation angle, and PDFium artefact flags
- **Word clustering** and layout-aware text flow
- **Vector path geometry** — real line segments, not just bounding boxes
- **Embedded image** extraction (raw, decoded, or rendered)
- **Annotations and links**, bookmarks, file attachments
- **Interactive form** field reading (AcroForm, XFA detection)
- **pdfplumber-style table detection** with `:lines`, `:text`, and
  `:explicit` strategies plus a visual debugger
- **Form-aware extraction** from prestamped forms via font filtering and
  label–value pairing
- **Tagged-PDF struct tree** traversal for zero-geometry semantic extraction
- **Page rendering** to PNG (pure-Ruby writer) or raw RGBA/BGRA/Gray bytes
- Matches `pypdfium2` speed; **up to ~49× faster than `pdfplumber`** — see
  [Benchmarks](benchmarks)

## How this documentation is organized

The documentation is topic-based, so you can jump straight to what you need:

- **[Basics](basics)** — documents and pages, text and characters, vector
  paths, images, annotations, rendering. Start here after installing.
- **[Data extraction](extraction)** — the higher-level pipelines: tables,
  interactive forms, form-aware extraction from prestamped templates, and
  Tagged-PDF structure.
- **[Benchmarks](benchmarks)** — reproducible performance comparisons
  against `pypdfium2` and `pdfplumber`, with the sample files and harness in
  the repository's `benchmark/` directory.
- **[Architecture](architecture)** — the three-layer design and memory-safety
  model, for contributors or anyone dropping down to the raw FFI layer.

Use the search box at the top of the page to find specific methods or topics.
