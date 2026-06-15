---
title: Raw text
parent: Benchmarks
nav_order: 1
---

# Raw text benchmark
{: .no_toc }

1. TOC
{:toc}

---

Extracts the plain text of every page and scores the fraction of embedded
sentinel tokens recovered (correctness). Apple M-series (arm64, macOS), best
of 5 runs after a warm-up. Reproduce with `ruby benchmark/run.rb`.

## Synthetic suite

| PDF | Library | Time | Peak RSS | Correctness |
| --- | --- | ---: | ---: | ---: |
| `01_simple.pdf` (1 pg) | rpdfium | 11 ms | 33 MB | 100% |
| | pypdfium2 | 12 ms | 36 MB | 100% |
| | pdfplumber | 16 ms | 42 MB | 100% |
| | hexapdf | 12 ms | 24 MB | 100% |
| `02_medium.pdf` (6 pg) | rpdfium | 13 ms | 34 MB | 100% |
| | pypdfium2 | 13 ms | 37 MB | 100% |
| | pdfplumber | 99 ms | 57 MB | 100% |
| | hexapdf | 18 ms | 24 MB | 100% |
| `03_complex.pdf` (16 pg) | rpdfium | 16 ms | 36 MB | 100% |
| | pypdfium2 | 16 ms | 37 MB | 100% |
| | pdfplumber | 181 ms | 72 MB | 100% |
| | hexapdf | 26 ms | 24 MB | 100% |
| `04_heavy.pdf` (60 pg) | rpdfium | **48 ms** | 59 MB | 100% |
| | pypdfium2 | 49 ms | 39 MB | 100% |
| | pdfplumber | **2.37 s** | **455 MB** | 100% |
| | hexapdf | 154 ms | 27 MB | 100% |

Observations:

- **rpdfium tracks pypdfium2 within measurement noise** on every tier — the
  Ruby FFI layer adds no measurable overhead over raw PDFium.
- **pdfplumber degrades super-linearly**: on the 60-page document it is ~48×
  slower than rpdfium and uses ~8× more memory.
- **hexapdf holds up well on these synthetic files** — lowest memory of the
  field and only ~3× slower than PDFium on the heavy tier. It uses less RAM
  for two reasons: (1) being pure Ruby it never maps the ~10 MB `libpdfium`
  native library (FreeType/ICU caches, C++ heaps); (2) `Content::Processor`
  computes layout **on demand while streaming** the content stream, whereas
  PDFium eagerly builds a full-page `FPDF_TEXTPAGE` model up front. hexapdf is
  *not* geometry-blind — `decode_text_with_positioning` exposes per-character
  bounding boxes and positioning, so word spacing and char boxes are
  available too; this runner just doesn't request them. Caveats on the
  numbers: text extraction is hand-rolled via `Content::Processor` (no public
  one-call API), this runner collects only strings (the cheapest path), and
  the correctness metric is whitespace-insensitive.
- **Memory is measured identically across all four runners** — peak RSS via
  `getrusage(ru_maxrss)` (FFI in Ruby, `resource` in Python), not "current
  RSS at exit". For text extraction RSS grows monotonically, so peak ≈ final
  anyway, but the runners are now apples-to-apples.
- Correctness is 100% across the board: every library recovers all sentinel
  tokens on these clean, generated PDFs. Real-world PDFs (broken ToUnicode
  maps, subset fonts, rotated text) are where extraction quality diverges.
