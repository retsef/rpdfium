---
title: Rendering
parent: Basics
nav_order: 6
---

# Rendering

{: .note }
> Sample PDF for this guide:
> [example.pdf]({{ site.baseurl }}/assets/pdfs/example.pdf).

```ruby
require "rpdfium"

Rpdfium.open("example.pdf") do |doc|
  page = doc.page(0)

  # Pure-Ruby PNG writer, zero deps:
  page.render_to_png("page.png", scale: 2.0, include_annotations: true,
                     include_forms: true)

  # Or get raw RGBA/BGRA/Gray bytes:
  w, h, bytes, stride = page.render(scale: 2.0, output: :rgba)
  puts "w=#{w} h=#{h} stride=#{stride} bytes=#{bytes.size}"
end
```

Output:

```
w=1191 h=1684 stride=4764 bytes=8022576
```

(A4 at `scale: 2.0` → 595×2 × 842×2 pixels; `stride` is the row length in
bytes, `width × 4` for RGBA.)

To render every page of a document to PNG files in one call:

```ruby
Rpdfium.render_to_pngs("example.pdf", output_dir: "out", scale: 2.0)
```

{: .note }
> The PNG writer is pure Ruby with no native dependencies beyond PDFium itself,
> so rendering works anywhere the gem loads.
