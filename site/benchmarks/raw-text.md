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
of 3 runs after a warm-up. Reproduce with `ruby benchmark/run.rb`.

## Synthetic suite

| PDF | Library | Time | Peak RSS | Correctness |
| --- | --- | ---: | ---: | ---: |
| `01_simple.pdf` (1 pg) | rpdfium | 12 ms | 33 MB | 100% |
| | pypdfium2 | 12 ms | 36 MB | 100% |
| | pdfplumber | 17 ms | 42 MB | 100% |
| | hexapdf | 14 ms | 24 MB | 100% |
| `02_medium.pdf` (6 pg) | rpdfium | 14 ms | 33 MB | 100% |
| | pypdfium2 | 14 ms | 37 MB | 100% |
| | pdfplumber | 101 ms | 57 MB | 100% |
| | hexapdf | 19 ms | 24 MB | 100% |
| `03_complex.pdf` (16 pg) | rpdfium | 15 ms | 34 MB | 100% |
| | pypdfium2 | 16 ms | 38 MB | 100% |
| | pdfplumber | 182 ms | 72 MB | 100% |
| | hexapdf | 28 ms | 25 MB | 100% |
| `04_heavy.pdf` (60 pg) | rpdfium | **47 ms** | **35 MB** | 100% |
| | pypdfium2 | 50 ms | 40 MB | 100% |
| | pdfplumber | 2.41 s | 456 MB | 100% |
| | hexapdf | 145 ms | 26 MB | 100% |
| `05_academic.pdf` (520 pg) | rpdfium | **706 ms** | **69 MB** | 100% |
| | pypdfium2 | 755 ms | 104 MB | 100% |
| | pdfplumber | 57.15 s | 5537 MB | 100% |
| | hexapdf | 2.28 s | 43 MB | 100% |

Observations:

- **rpdfium tracks pypdfium2 within measurement noise** on time — the Ruby FFI
  layer adds no measurable overhead over raw PDFium — and from the heavy tier
  on it uses **less** memory than the raw binding (35 MB vs 40 MB on
  `04_heavy`; **69 MB vs 104 MB** on the 520-page `05_academic`), because
  `extract_text` streams pages and closes each one immediately, while the
  pypdfium2 runner holds them. Peak RSS no longer grows with the page count.
- **pdfplumber degrades super-linearly**: ~52× slower than rpdfium on the
  60-page tier, and on the 520-page academic paper it blows out to **57 s and
  5.5 GB** — ~81× slower than rpdfium and ~80× more memory.
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
