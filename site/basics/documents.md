---
title: Documents & pages
parent: Basics
nav_order: 1
---

# Documents & pages
{: .no_toc }

1. TOC
{:toc}

---

{: .note }
> Sample PDF for this guide:
> [example.pdf]({{ site.baseurl }}/assets/pdfs/example.pdf) — a one-page
> invoice with metadata, a logo image, a ruled table, and a link annotation.

## Opening a document

The block form opens the PDF, yields a `Document`, and closes it
automatically:

```ruby
require "rpdfium"

Rpdfium.open("example.pdf") do |doc|
  p doc.metadata
  page = doc.page(0)
  puts "pages=#{doc.page_count} width=#{page.width.round(1)} height=#{page.height.round(1)}"
end
```

Output:

```
{title: "Fattura di esempio", author: "Azienda S.R.L.",
 producer: "HexaPDF version 1.9.1", moddate: "D:20260612104643+02'00'"}
pages=1 width=595.3 height=841.9
```

Without a block you own the handle and must close it yourself:

```ruby
doc = Rpdfium.open("example.pdf")
begin
  # ...
ensure
  doc.close
end
```

`Rpdfium.open` accepts a path, an `IO`, raw bytes, and an optional
`password:`.

## Iterating pages

```ruby
Rpdfium.open("example.pdf") do |doc|
  doc.each do |page|       # yields each Rpdfium::Page
    puts page.text
  end

  page = doc.page(0)       # zero-based random access
  puts page.width          # 595.27... (points)
  puts page.height         # 841.88...
  puts page.rotation       # 0 / 90 / 180 / 270
end
```

## Top-level convenience helpers

For one-liners that don't need fine control:

| Method | Description |
| --- | --- |
| `Rpdfium.open(path) { \|doc\| ... }` | Open a PDF, yield `Document`, auto-close |
| `Rpdfium.extract_text(path)` | All pages as `Array<String>` |
| `Rpdfium.extract_tables(path, keep_blank_rows: false)` | All tables with page index |
| `Rpdfium.render_to_pngs(path, output_dir:, scale: 2.0)` | Render pages to PNG files |

```ruby
Rpdfium.extract_text("example.pdf").first.lines.first(3).join
# => "Azienda S.R.L.\nCITTA XX VIA ESEMPIO 1 — P.IVA 01234567890\nFattura n. 2026-042 del 15/05/2026\n"
```

## Outline (bookmarks) & attachments

```ruby
Rpdfium::Outline.flatten(doc.outline) do |item, depth|
  puts "#{"  " * depth}- #{item.title} (page #{item.page_index})"
end

doc.attachments.each { |a| a.save("attached_#{a.name}") }
```
