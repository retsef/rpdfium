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
| | pypdfium2 | 11 ms | 36 MB | 100% |
| | pdfplumber | 16 ms | 41 MB | 100% |
| | hexapdf | 12 ms | 23 MB | 100% |
| `02_medium.pdf` (6 pg) | rpdfium | 14 ms | 34 MB | 100% |
| | pypdfium2 | 13 ms | 36 MB | 100% |
| | pdfplumber | 97 ms | 57 MB | 100% |
| | hexapdf | 18 ms | 24 MB | 100% |
| `03_complex.pdf` (16 pg) | rpdfium | 15 ms | 36 MB | 100% |
| | pypdfium2 | 16 ms | 37 MB | 100% |
| | pdfplumber | 184 ms | 72 MB | 100% |
| | hexapdf | 25 ms | 25 MB | 100% |
| `04_heavy.pdf` (60 pg) | rpdfium | **49 ms** | 59 MB | 100% |
| | pypdfium2 | 49 ms | 39 MB | 100% |
| | pdfplumber | **2.37 s** | **455 MB** | 100% |
| | hexapdf | 147 ms | 27 MB | 100% |

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

## Real-world corpus

Larger, denser documents (not redistributable). Versions: `rpdfium 0.3.13`,
`pdfplumber 0.11.9`, `pypdfium2 5.6.0` (hexapdf not measured on this corpus).

| Corpus | rpdfium | pypdfium2 | pdfplumber | speedup vs pdfplumber |
| --- | ---: | ---: | ---: | ---: |
| sample.pdf (1 pg, 18 KB) | 4 ms | 4 ms | 75 ms | **21×** |
| form.pdf (1 pg, 107 KB) | 12 ms | 13 ms | 538 ms | **44×** |
| complex.pdf (85 pg, 60 MB) | 190 ms | 183 ms | 7.76 s | **41×** |
| report.pdf (226 pg, 322 KB) | 412 ms | 397 ms | 23.26 s | **56×** |

Peak RSS on the same corpus:

| Corpus | rpdfium | pypdfium2 | pdfplumber | pdfplumber / rpdfium |
| --- | ---: | ---: | ---: | ---: |
| sample.pdf | 29 MB | 20 MB | 40 MB | 1.4× |
| form.pdf | 32 MB | 22 MB | 45 MB | 1.4× |
| complex.pdf | 106 MB | 69 MB | 535 MB | **5.0×** |
| report.pdf | 136 MB | 41 MB | 1003 MB | **7.4×** |

On a 226-page document pdfplumber uses ~1 GB; rpdfium stays under 140 MB. For
server-side batch processing this is the difference between a 256 MB container
and a 2 GB one.
