---
title: Text & characters
parent: Basics
nav_order: 2
---

# Text & characters
{: .no_toc }

1. TOC
{:toc}

---

{: .note }
> Sample PDF for this guide:
> [text.pdf]({{ site.baseurl }}/assets/pdfs/text.pdf) — two pages of
> structured text with mixed fonts (Helvetica and Helvetica-Bold).

## Plain text

```ruby
require "rpdfium"

Rpdfium.open("text.pdf") do |doc|
  page = doc.page(0)
  puts page.text.lines.first(3).join
end
```

Output:

```
Relazione di esempio
Azienda S.R.L. — P.IVA 01234567890
Sezione 1
```

Restrict to a region of the page:

```ruby
page.text_in_bbox(left: 50, top: 100, right: 300, bottom: 150)
```

## Character-level metadata

Per-char data is essential for layout-aware processing — bounding box, font,
weight, origin, rotation angle, plus PDFium's "character provenance" flags:

```ruby
Rpdfium.open("text.pdf") do |doc|
  pp doc.page(0).chars.first
end
```

Output:

```ruby
{char: "R",
 codepoint: 82,
 x0: 50.0, x1: 62.99, top: 50.0, bottom: 66.65,
 origin_x: 50.0, origin_y: 62.92,
 angle: 0.0,                  # radians (rotated text)
 fontsize: 18.0,
 font: "Helvetica-Bold",
 weight: 700,
 render_mode: 0,              # 0=fill 1=stroke 2=both 3=invisible
 generated: false,            # true → inserted by PDFium (e.g. spaces)
 hyphen: false,               # true → soft-hyphen for line break
 unicode_error: false,        # true → couldn't map glyph to unicode
 advance: 12.99,
 text_obj_id: 44737295712,    # groups chars of the same text object (varies per run)
 text_obj_ends_with_space: false}
```

{: .tip }
> `generated` / `hyphen` / `unicode_error` are the **artefact recognition
> flags**. Distinguishing real characters from PDFium-synthesized ones is
> crucial when you don't want fake whitespace to widen a column.

Loose char boxes (proportional to font size, more stable for layout
algorithms):

```ruby
page.chars(loose: true)
```

## Words

Cluster chars into words automatically:

```ruby
Rpdfium.open("text.pdf") do |doc|
  words = doc.page(0).words(x_tolerance: 3.0, y_tolerance: 3.0)
  pp words.first(3).map { |w| w[:text] }
end
```

Output:

```ruby
["Relazione", "di", "esempio"]
```

Each word carries its own bbox, font, fontsize, and the underlying `chars`.

## Search

```ruby
page.search("esempio", match_case: false).each_match do |m|
  puts "found '#{m[:text]}' at #{m[:rects].first.inspect}"
end
```
