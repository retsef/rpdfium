---
title: Tables
parent: Benchmarks
nav_order: 2
---

# Table benchmark
{: .no_toc }

1. TOC
{:toc}

---

Runs table detection on every page with **default settings** and scores the
fraction of known table cells (SKU codes and row totals from the ruled
tables) recovered. pypdfium2 has no table layer and is excluded.

hexapdf has no *built-in* table extraction, but it exposes the two primitives
the pipeline needs — per-glyph boxes (`decode_text_with_positioning`) and
stroked path segments (`Content::Processor`). The
[`benchmark/examples/hexapdf_table_extraction.rb`](https://github.com/retsef/rpdfium/blob/main/benchmark/examples/hexapdf_table_extraction.rb)
reference (~120 lines) builds a minimal lines-based extractor on them, and the
hexapdf row below uses it. It is a proof of concept — `:lines` only, a single
snap epsilon, no `:text` fallback or join tolerances — not a peer of
rpdfium's full pdfplumber port.

Apple M-series (arm64, macOS), best of 3 runs after a warm-up. Reproduce
with `ruby benchmark/run.rb`.

## Synthetic suite

| PDF | Library | Time | Peak RSS | Correctness |
| --- | --- | ---: | ---: | ---: |
| `01_simple.pdf` (1 pg, 1 table) | rpdfium | 15 ms | 34 MB | 100% |
| | pdfplumber | 17 ms | 41 MB | 100% |
| | hexapdf | 22 ms | 25 MB | 100% |
| `02_medium.pdf` (6 pg, 6 tables) | rpdfium | 45 ms | 43 MB | 100% |
| | pdfplumber | 111 ms | 56 MB | 100% |
| | hexapdf | 53 ms | 25 MB | 100% |
| `03_complex.pdf` (16 pg, mixed) | rpdfium | 151 ms | 54 MB | 100% |
| | pdfplumber | 185 ms | 71 MB | 100% |
| | hexapdf | 85 ms | 25 MB | 100% |
| `04_heavy.pdf` (60 pg, 60 tables) | rpdfium | 791 ms | 265 MB | 100% |
| | pdfplumber | **2.96 s** | 442 MB | 100% |
| | hexapdf | **752 ms** | **28 MB** | 100% |

Observations:

- **All three recover 100% of the ruled-table cells** on every tier — these
  are clean generated grids, the easy case. Correctness diverges on
  real-world tables (dashed rules, partial borders, misaligned cells), which
  is exactly where rpdfium's snap/join tolerances and `:text` fallback earn
  their cost and the 120-line reference would start dropping cells.
- **The minimal hexapdf extractor is fast and remarkably light** — on the
  heavy tier it edges out rpdfium on time (752 ms vs 791 ms) at a fraction of
  the memory (28 MB vs 265 MB). Two reasons: it streams without mapping the
  native `libpdfium`, and it does far less work than rpdfium's full pipeline
  (no tolerance passes, no rectangle-fill handling, no multi-table
  segmentation per page). It's a fair comparison only on clean grids.
- **rpdfium stays linear and robust**: ~4× faster than pdfplumber on the
  heavy tier, and the full pipeline handles the messy cases the minimal
  extractor cannot. The memory cost (265 MB on 60 pages of dense tables) is
  the `FPDF_TEXTPAGE` + cell-geometry model; still far under pdfplumber's
  442 MB.
- `03_complex.pdf` also contains borderless tables and a prestamped form —
  neither counts toward the ground truth (recovering them needs the `:text`
  strategy or [font filtering](../extraction/filled-forms), not default
  settings).

## Real-world corpus

Larger documents (not redistributable). Versions: `rpdfium 0.3.13`,
`pdfplumber 0.11.9`.

| Corpus | rpdfium | pdfplumber | speedup |
| --- | ---: | ---: | ---: |
| sample.pdf (1 pg) | 4 ms | 70 ms | **16×** |
| form.pdf (1 pg) | 25 ms | 575 ms | **23×** |
| complex.pdf (85 pg) | 231 ms | 7.07 s | **31×** |
| report.pdf (226 pg, ~15 tables/pg) | 1.68 s | 25.25 s | **15×** |

Across the corpus the median speedup vs pdfplumber is **27× on text** and
**22× on tables**. rpdfium scales linearly with page count thanks to PDFium's
C++ engine; pdfplumber's pure-Python pipeline degrades super-linearly on
large documents.
