---
title: Vector paths
parent: Basics
nav_order: 3
---

# Vector paths

{: .note }
> Sample PDF for this guide:
> [table.pdf]({{ site.baseurl }}/assets/pdfs/table.pdf) — page 1 contains a
> table drawn with real ruling lines.

Real path-segment iteration (not just bounding boxes), with a state machine
for `closepath`. Useful for table line detection, signatures, and form layout
analysis:

```ruby
require "rpdfium"

Rpdfium.open("table.pdf") do |doc|
  page = doc.page(0)
  puts "horizontal=#{page.horizontal_lines.size} vertical=#{page.vertical_lines.size}"
  pp page.horizontal_lines.first
end
```

Output:

```
horizontal=210 vertical=210
{y: 89.29, x0: 50.5, x1: 120.5, stroke_width: 1.0}
```

(The generator draws each table cell with its own border, so a 13×5 grid
produces many short segments — exactly what the table pipeline's
snap-and-join step is for.)

The generic accessor returns every segment with full geometry:

```ruby
page.line_segments
# [{ x0: 72.0, y0: 100.0, x1: 540.0, y1: 100.0, stroke_width: 0.5 }, ...]
```

These geometric primitives feed the `:lines` strategy of the
[table extractor](../extraction/tables) — but they are useful on their own
whenever you need the actual drawn geometry of a page.
