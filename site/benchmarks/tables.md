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
| `01_simple.pdf` (1 pg, 1 table) | rpdfium | **15 ms** | 34 MB | 100% |
| | pdfplumber | 17 ms | 42 MB | 100% |
| | hexapdf | 24 ms | 25 MB | 100% |
| `02_medium.pdf` (6 pg, 6 tables) | rpdfium | **38 ms** | 35 MB | 100% |
| | pdfplumber | 111 ms | 57 MB | 100% |
| | hexapdf | 54 ms | 25 MB | 100% |
| `03_complex.pdf` (16 pg, mixed) | rpdfium | 124 ms | 38 MB | 100% |
| | pdfplumber | 187 ms | 71 MB | 100% |
| | hexapdf | **88 ms** | 26 MB | 100% |
| `04_heavy.pdf` (60 pg, 60 tables) | rpdfium | **496 ms** | 39 MB | 100% |
| | pdfplumber | 3.05 s | 442 MB | 100% |
| | hexapdf | 779 ms | **29 MB** | 100% |
| `05_academic.pdf` (520 pg, ~104 ruled tables) | rpdfium | 15.46 s | 104 MB | 100% |
| | pdfplumber | 68.04 s | 5179 MB | 100% |
| | hexapdf | **13.22 s** | **37 MB** | 100% |

Observations:

- **All three recover 100% of the ruled-table cells** on every tier — these
  are clean generated grids, the easy case. Correctness diverges on
  real-world tables (dashed rules, partial borders, misaligned cells), which
  is exactly where rpdfium's snap/join tolerances and `:text` fallback earn
  their cost and the 120-line reference would start dropping cells.
- **rpdfium is the fastest up to the heavy tier** (496 ms vs hexapdf's 779 ms
  and pdfplumber's 3.05 s on `04_heavy`). Two layers earn this. First, the
  table/word pipeline pulls chars through a geometry-only fast path that skips
  the FFI reads and per-char allocation the cell filter never uses. Second, the
  batch helpers (`extract_tables`, `extract_text`) now **stream pages** — each
  page is closed the moment its data is read, freeing its native handles and
  char caches instead of retaining every visited page for the document's
  lifetime. Peak RSS on the heavy tier fell from 119 MB to **39 MB** and no
  longer grows with the page count.
- **On the 520-page academic tier the minimal hexapdf reference edges rpdfium
  out on time** (13.22 s vs 15.46 s). At that scale the full pipeline's
  per-page cost — borderless `:text` attempts, rectangle / multi-table search,
  annotation parsing on figure/footnote-heavy pages — dominates, while the
  `:lines`-only reference skips all of it. rpdfium still recovers the same
  cells and stays **~4.4× faster than pdfplumber while using ~50× less memory**
  (104 MB vs 5.2 GB). hexapdf also leads on `03_complex` (88 ms). A fair
  comparison only on clean ruled grids.
- **rpdfium stays linear and robust**: ~5.9× faster than pdfplumber on the
  heavy tier, ~4.4× on the academic tier, with ~11–50× less memory.
- `03_complex.pdf` also contains borderless tables and a prestamped form —
  neither counts toward the ground truth (recovering them needs the `:text`
  strategy or [font filtering](../extraction/filled-forms), not default
  settings).
