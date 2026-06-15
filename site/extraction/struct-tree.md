---
title: Struct tree (Tagged PDF)
parent: Data extraction
nav_order: 4
---

# Struct tree (Tagged PDF)
{: .no_toc }

1. TOC
{:toc}

---

{: .note }
> No sample PDF for this guide: tagged PDFs require accessibility-aware
> authoring tools. Export any document from Word, LibreOffice, or InDesign
> with accessibility tags enabled and run the snippets against it.

For tagged PDFs (PDF/UA, accessibility-friendly exports from
Word/LibreOffice/InDesign), `Page#struct_tree` exposes the document's logical
structure (Document → P, H1, Table, TR, TH, TD, Figure, ...) independently of
the visual layout. This gives **zero-geometry** extraction with semantic typing
(TH vs TD, RowSpan, ColSpan, Lang).

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
```

## API summary

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

## Three possible states

| PDF type | `page.struct_tree` returns |
| --- | --- |
| Not tagged (most line-of-business and scanned PDFs) | `nil` |
| Tagged but empty (placeholder `StructTreeRoot`) | `Tree` with `empty? == true` |
| Properly tagged (accessibility export) | Navigable `Tree` |

{: .warning }
> Prefer the **block form** for deterministic cleanup. Never define a finalizer
> on a `FPDF_STRUCTTREE` handle: it segfaults if the page is closed first.
> The implicit (no-block) form leaves cleanup to `FPDF_CloseDocument` — no
> leak, the tree just stays in memory until the document is closed.
