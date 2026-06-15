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
does extract text with character positioning, but is AGPL / commercially
licensed and has no table-detection pipeline or page rasterization. `rpdfium`
is an Apache-2.0 alternative that adds pdfplumber-style table extraction and
page rendering, and binds the same battle-tested C++ engine that powers
Chrome's PDF viewer — so it stays fast and light on large, complex documents.

In practice it matches the speed of Python's `pypdfium2` on text extraction
and is **15–56× faster than `pdfplumber`** while using **5–7× less memory** on
large documents. See [Benchmarks](benchmarks) for the reproducible suite.

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
