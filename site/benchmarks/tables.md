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

Apple M-series (arm64, macOS), best of 5 runs after a warm-up. Reproduce
with `ruby benchmark/run.rb`.

## Synthetic suite

| PDF | Library | Time | Peak RSS | Correctness |
| --- | --- | ---: | ---: | ---: |
| `01_simple.pdf` (1 pg, 1 table) | rpdfium | **15 ms** | 33 MB | 100% |
| | pdfplumber | 18 ms | 42 MB | 100% |
| | hexapdf | 23 ms | 25 MB | 100% |
| `02_medium.pdf` (6 pg, 6 tables) | rpdfium | **40 ms** | 35 MB | 100% |
| | pdfplumber | 111 ms | 57 MB | 100% |
| | hexapdf | 55 ms | 26 MB | 100% |
| `03_complex.pdf` (16 pg, mixed) | rpdfium | 125 ms | 38 MB | 100% |
| | pdfplumber | 188 ms | 71 MB | 100% |
| | hexapdf | **87 ms** | 26 MB | 100% |
| `04_heavy.pdf` (60 pg, 60 tables) | rpdfium | **493 ms** | 39 MB | 100% |
| | pdfplumber | 2.90 s | 442 MB | 100% |
| | hexapdf | 727 ms | **28 MB** | 100% |

Observations:

- **All three recover 100% of the ruled-table cells** on every tier — these
  are clean generated grids, the easy case. Correctness diverges on
  real-world tables (dashed rules, partial borders, misaligned cells), which
  is exactly where rpdfium's snap/join tolerances and `:text` fallback earn
  their cost and the 120-line reference would start dropping cells.
- **rpdfium is the fastest on the heavy tier** (493 ms vs hexapdf's 727 ms and
  pdfplumber's 2.90 s). Two layers earn this. First, the table/word pipeline
  pulls chars through a geometry-only fast path that skips the FFI reads and
  per-char allocation the cell filter never uses. Second, the batch helpers
  (`extract_tables`, `extract_text`) now **stream pages** — each page is closed
  the moment its data is read, freeing its native handles and char caches
  instead of retaining every visited page for the document's lifetime. Peak
  RSS on the heavy tier fell from 119 MB to **39 MB** and no longer grows with
  the page count.
- **The minimal hexapdf extractor stays remarkably light** — ~28 MB on the
  heavy tier — but rpdfium is now within ~11 MB of it (39 MB) despite mapping
  the ~10 MB native `libpdfium` and running the full tolerance / rectangle /
  multi-table pipeline. hexapdf still leads on `03_complex` (87 ms). A fair
  comparison only on clean grids.
- **rpdfium stays linear and robust**: ~5.9× faster than pdfplumber on the
  heavy tier while using ~11× less memory.
- `03_complex.pdf` also contains borderless tables and a prestamped form —
  neither counts toward the ground truth (recovering them needs the `:text`
  strategy or [font filtering](../extraction/filled-forms), not default
  settings).
