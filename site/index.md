---
title: Home
layout: home
nav_order: 1
description: "rpdfium — Ruby FFI bindings for PDFium: text, tables, forms, rendering."
permalink: /
---

# rpdfium
{: .fs-9 }

Ruby bindings for [PDFium](https://pdfium.googlesource.com/pdfium/), the PDF
engine that powers Chrome's viewer. Text extraction with character-level
metadata, vector path access, image extraction, form fields, page rendering,
and pdfplumber-style table detection.
{: .fs-6 .fw-300 }

[Get started](getting-started){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[View on GitHub](https://github.com/retsef/rpdfium){: .btn .fs-5 .mb-4 .mb-md-0 }

---

Try it on the [example PDF]({{ site.baseurl }}/assets/pdfs/example.pdf) used
throughout these guides:

```ruby
require "rpdfium"

Rpdfium.open("example.pdf") do |doc|
  doc.each do |page|
    puts page.text
    Rpdfium::Table::Extractor.new(page).extract.each do |table|
      table.each { |row| puts row.inspect }
    end
  end
end
```

## Why rpdfium

The Ruby ecosystem has `pdf-reader` (text only, slow on complex docs),
`origami` (security-research focused), and `hexapdf` — a capable library that
extracts text with character-level positioning and exposes the vector-path
primitives you need to build table extraction yourself (the benchmark suite
ships a [~120-line reference](https://github.com/retsef/rpdfium/blob/main/benchmark/examples/hexapdf_table_extraction.rb)
that does exactly this); it is AGPL / commercially licensed. `rpdfium` is an
Apache-2.0 alternative that ships those higher-level pipelines out of the box —
pdfplumber-style table detection and page rendering on top of character
metadata — binding the same battle-tested C++ engine that powers Chrome's PDF
viewer, so it stays fast and light on large, complex documents.

In practice it matches the speed of Python's `pypdfium2` on text extraction
and is **up to ~52× faster than `pdfplumber`** while using **up to ~13× less
memory** on dense documents. See [Benchmarks](benchmarks) for the reproducible
suite.

## At a glance

| Capability | Where |
| --- | --- |
| Open documents, metadata, bookmarks, attachments | [Documents & pages](basics/documents) |
| Plain + bbox-bounded text, per-character metadata | [Text & characters](basics/text) |
| Vector path geometry (lines, segments) | [Vector paths](basics/paths) |
| Embedded image extraction | [Images](basics/images) |
| Annotations, links | [Annotations & links](basics/annotations) |
| Page rendering to PNG / raw bytes | [Rendering](basics/rendering) |
| pdfplumber-style table detection | [Tables](extraction/tables) |
| AcroForm / XFA fields | [Interactive forms](extraction/forms) |
| Data extraction from filled forms | [Form-aware extraction](extraction/filled-forms) |
| Tagged-PDF logical structure | [Struct tree](extraction/struct-tree) |
| Performance vs pypdfium2 / pdfplumber | [Benchmarks](benchmarks) |

## License

Apache-2.0, same as PDFium itself.
