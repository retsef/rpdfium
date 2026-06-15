---
title: Architecture
nav_order: 7
---

# Architecture
{: .no_toc }

1. TOC
{:toc}

---

## Three layers

Mirroring `pypdfium2`:

1. **`Rpdfium::Raw`** — pure FFI bindings, 1:1 with the C API (`FPDF_*`,
   `FPDFText_*`, `FPDFBitmap_*`, `FPDFPath_*`, `FPDFImageObj_*`, `FPDFAnnot_*`).
   Use directly if you need something the wrappers don't expose.
2. **Wrappers** — `Rpdfium::Document`, `::Page`, `::TextPage`,
   `::Image::Embedded`, `::Annotation`, `::Form::Field`, `::Search`,
   `::Outline`, `::Attachment`. RAII-style wrappers with
   `ObjectSpace.define_finalizer` so handles are released even if you forget
   `close`.
3. **`Rpdfium::Table::Extractor`** — table detection on top of layer 2, with
   `Rpdfium::Table::Debugger` for visual debugging.

## Memory safety

- `FPDF_LoadMemDocument64` does **not** copy the input bytes. The `Document`
  wrapper holds an FFI buffer reference for its lifetime so the GC can't free
  it early.
- Every PDFium handle (`*_Close*`) that owns memory independently is wired to
  `ObjectSpace.define_finalizer` so abandoned objects don't leak native memory.
- `FPDF_InitLibrary` is called once per process under a `Mutex`;
  `FPDF_DestroyLibrary` runs via `at_exit`.
- `Document#close` releases in cascade: form-fill env → cached pages →
  document handle.

{: .warning }
> Finalizers are only safe on handles whose parent cannot be closed out from
> under them. `FPDF_DOCUMENT` and `FPDF_PAGE` get finalizers; child handles
> like `FPDF_STRUCTTREE` do **not** — defining one there segfaults when the
> page closes first.

## Why not pure Ruby?

A correct PDF text extractor needs to interpret the content stream (operators,
font encodings including CMap-based CIDs, ToUnicode maps, ActualText overrides,
marked content). PDFium has ~15 years of edge-case fixes baked in.
Reimplementing it in Ruby would take years and still be slower. FFI is the
right call.
