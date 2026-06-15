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
| `01_simple.pdf` (1 pg, 1 table) | rpdfium | **14 ms** | 33 MB | 100% |
| | pdfplumber | 17 ms | 42 MB | 100% |
| | hexapdf | 23 ms | 25 MB | 100% |
| `02_medium.pdf` (6 pg, 6 tables) | rpdfium | **38 ms** | 37 MB | 100% |
| | pdfplumber | 111 ms | 57 MB | 100% |
| | hexapdf | 53 ms | 25 MB | 100% |
| `03_complex.pdf` (16 pg, mixed) | rpdfium | 127 ms | 43 MB | 100% |
| | pdfplumber | 185 ms | 71 MB | 100% |
| | hexapdf | **83 ms** | 25 MB | 100% |
| `04_heavy.pdf` (60 pg, 60 tables) | rpdfium | **537 ms** | 119 MB | 100% |
| | pdfplumber | **2.98 s** | 442 MB | 100% |
| | hexapdf | 759 ms | **29 MB** | 100% |

Observations:

- **All three recover 100% of the ruled-table cells** on every tier — these
  are clean generated grids, the easy case. Correctness diverges on
  real-world tables (dashed rules, partial borders, misaligned cells), which
  is exactly where rpdfium's snap/join tolerances and `:text` fallback earn
  their cost and the 120-line reference would start dropping cells.
- **rpdfium is the fastest on the heavy tier** (537 ms vs hexapdf's 759 ms and
  pdfplumber's 2.98 s). The table/word pipeline pulls chars through a
  geometry-only fast path that skips the FFI reads and per-char allocation the
  cell filter never uses — which also cut peak RSS on the heavy tier from
  ~265 MB to 119 MB. The full pipeline still handles the messy cases the
  minimal hexapdf extractor cannot.
- **The minimal hexapdf extractor stays remarkably light** — ~29 MB on the
  heavy tier, a fraction of rpdfium's 119 MB, because it streams without
  mapping the native `libpdfium` and does far less work (no tolerance passes,
  no rectangle-fill handling, no multi-table segmentation per page). It also
  leads on `03_complex` (83 ms). A fair comparison only on clean grids.
- **rpdfium stays linear and robust**: ~5.5× faster than pdfplumber on the
  heavy tier while using ~3.7× less memory.
- `03_complex.pdf` also contains borderless tables and a prestamped form —
  neither counts toward the ground truth (recovering them needs the `:text`
  strategy or [font filtering](../extraction/filled-forms), not default
  settings).
