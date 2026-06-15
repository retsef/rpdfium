---
title: Form-aware extraction
parent: Data extraction
nav_order: 3
---

# Form-aware extraction (font filtering)
{: .no_toc }

1. TOC
{:toc}

---

{: .note }
> Sample PDF for this guide:
> [form.pdf]({{ site.baseurl }}/assets/pdfs/form.pdf) — a prestamped form:
> template labels in Helvetica, "entered" data in Courier monospace.

Some PDFs are "filled-out forms" — payment slips, tax declarations, government
forms — where the form template **and** the entered data both exist as static
graphics text on the page (no AcroForm fields, no tagged structure). On these
PDFs the [table pipeline](tables) picks up the template labels as noise
alongside the data.

The robust strategy is to separate chars by **role** using their font: the
template typically uses proportional fonts (Futura, Times, Helvetica) while the
data layer uses a single font (often Courier monospace, or Helvetica at a
specific size).

## Step 1 — discover the fonts

```ruby
require "rpdfium"

Rpdfium.open("form.pdf") do |doc|
  doc.page(0).font_inventory.first(3).each do |g|
    puts "#{g[:font].ljust(16)} h=#{g[:height]} | #{g[:count]} chars | #{g[:sample][0, 30]}"
  end
end
```

Output:

```
Helvetica        h=6.5 | 142 chars | CODICE FISCALEDENOMINAZIONEDOM
Courier          h=7.9 | 142 chars | RSSMRA80A01H501ZAzienda S.R.L.
Helvetica-Bold   h=9.3 |  41 chars | RISERVATO ALL'UFFICIO (campi c
```

The data layer is the monospace **Courier**; the template is Helvetica.

{: .note }
> `font_inventory` groups by `(font, height, weight)`, clustering near-equal
> heights so a round glyph whose loose box overshoots the cap line by a
> fraction of a point (`O`, `S`, `C`) stays with the rest of its size instead
> of splitting off. The `sample` concatenates the group's chars with no word
> spacing — it's an inventory for orientation, not an extraction tool.

## Step 2 — extract the data, line by line

```ruby
Rpdfium.open("form.pdf") do |doc|
  doc.page(0).lines(font: "Courier").each { |l| puts l }
end
```

Output:

```
RSSMRA80A01H501Z  Azienda  S.R.L.
CITTA  XX  VIA  ESEMPIO  1  01234567890
1001  11  2021  499,81  0,00
1712  12  2021  32,46  0,00
1701  11  2021  0,00  295,89
3812  12  2021  236,38  0,00
```

Template noise is gone — only the entered data remains.

Three primitives compose this pipeline:

- **`Page#font_inventory`** — distribution by `(font, height, weight)`, with
  counts and samples for inspection.
- **`Page#chars_where(font:, height:, weight:, bbox:, where:)`** — filter chars
  by any combination of criteria.
- **`Page#lines(font:, ...)`** — high-level helper: filter + word extraction +
  line clustering, returns `Array<String>`.

## Step 3 — label–value pairing

`Page#label_value_pairs` associates each extracted value with the semantic
label from the template that describes it — machine-readable
`field_name → field_value` pairs without hard-coding the form layout:

```ruby
Rpdfium.open("form.pdf") do |doc|
  pairs = doc.page(0).label_value_pairs(
    data_font: "Courier",
    template_font: "Helvetica",
    data_filter: ->(t) { t.match?(/\A[\d.,]{2,}\z/) }
  )
  pairs.first(6).each do |p|
    puts "#{p[:value].ljust(11)} → #{p[:labels][:col]}"
  end
end
```

Output:

```
01234567890 → PARTITA IVA
1001        → codice tributo
11          → periodo
2021        → anno
499,81      → importi a debito
0,00        → importi a credito
```

The column headers are printed **once** on the template, yet every one of the
four data rows gets the right label — the matcher clusters template words into
coherent labels, then pairs each value with the `:col` label above it (and the
`:row` label to its left, when the form has row headers).

## Composable primitives for complex forms

For complex forms with repeating tables, boxed-layout cells, or multi-word
values, compose three primitives.

**`Util::WordMerger`** — join adjacent words on the same line:

```ruby
merger = Rpdfium::Util::WordMerger.new(x_gap: 20.0, y_tol: 3.0)
merged = merger.merge_by_proximity(words)
# or, with labels mapping to preserve checkbox grids:
merged = merger.merge_by_label(words, label_per_word)
# or, only merge orphans (no label assigned):
merged = merger.merge_unlabeled(words, label_per_word)
```

**`Util::ColumnInference`** — identify data columns by alignment:

```ruby
inference = Rpdfium::Util::ColumnInference.new(
  x_tolerance: 3.0,
  min_size: 3,
  cv_threshold: 0.15
)
columns = inference.infer(words)
# => [[word1, word2, ..., word12], ...]
```

Algorithm: cluster by `x0` (left-align) **and** `x1` (right-align), split
columns at large vertical gaps, filter by gap-regularity (coefficient of
variation < 0.15) to exclude false positives.

**`Util::LabelMatcher`** with column inference enables header propagation for
repeating tables (rows sharing column headers printed once at the top):

```ruby
matcher = Rpdfium::Util::LabelMatcher.new(
  column_inference: Rpdfium::Util::ColumnInference.new
)
pairs = page.label_value_pairs(data_font: "Courier", matcher: matcher)
```

For boxed-layout forms (cells separated by ~10pt with template graphics for
decimals), pass `inject_spaces: false, x_tolerance: 15.0` to
`label_value_pairs` and `row_max_dx: 400.0` to the matcher.

{: .note }
> Form-specific logic lives in **user-side adapters**, not in the gem itself.
> rpdfium is a generalist library exposing primitives. See `examples/adapters/`
> in the repository for complete working reference adapters to copy and adapt.
