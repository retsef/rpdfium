---
title: Tables
parent: Data extraction
nav_order: 1
---

# Tables
{: .no_toc }

1. TOC
{:toc}

---

{: .note }
> Sample PDF for this guide:
> [table.pdf]({{ site.baseurl }}/assets/pdfs/table.pdf) — page 1 has a table
> drawn with ruling lines, page 2 the same data as borderless aligned columns.

## Ruled tables (`:lines` strategy)

The default strategy detects tables from the actual drawn lines:

```ruby
require "rpdfium"

Rpdfium.open("table.pdf") do |doc|
  tables = Rpdfium::Table::Extractor.new(doc.page(0)).extract
  puts "tables=#{tables.size}"
  tables.first.first(3).each { |row| p row }
end
```

Output:

```ruby
tables=1
["Codice", "Descrizione", "Q.ta", "Prezzo", "Totale"]
["SKU-0001", "Servizio di esempio n. 1", "2", "13.17", "26.34"]
["SKU-0002", "Servizio di esempio n. 2", "3", "16.34", "49.02"]
```

## Borderless tables (`:text` strategy)

Page 2 has no lines at all — columns are inferred from text alignment:

```ruby
Rpdfium.open("table.pdf") do |doc|
  extractor = Rpdfium::Table::Extractor.new(doc.page(1),
                                            vertical_strategy:   :text,
                                            horizontal_strategy: :text)
  pp extractor.extract.first[2] # third row
end
```

Output:

```ruby
["Codice", "Descrizione", "", "Q.ta", "Prezzo", "Totale"]
```

With `auto_fallback: true` (the default) you don't even have to pick: a
`:lines` run that finds nothing automatically retries with `:text`.

## All the knobs

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

The pipeline mirrors `pdfplumber.TableFinder` 1:1 and uses the same algorithms
for words-to-edges, intersections-to-cells, and cells-to-tables.

| Strategy | When to use |
| --- | --- |
| `:lines` | Tables drawn with visible ruling lines |
| `:lines_strict` | As `:lines`, ignoring rectangle fills |
| `:text` | Borderless tables — infer columns from text alignment |
| `:explicit` | You supply the line coordinates yourself |

## Visual debugger

Saves a PNG with an overlay: red lines, green intersections, blue table fills.

```ruby
Rpdfium::Table::Debugger.visualize(page, "debug.png",
                                   vertical_strategy: :lines)
```

{: .tip }
> When extraction misses or splits a table, run the debugger first. Seeing the
> detected edges and intersections usually points straight at the
> `snap_tolerance` / `join_tolerance` value that needs adjusting.
