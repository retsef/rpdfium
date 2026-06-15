---
title: Data extraction
nav_order: 5
has_children: true
---

# Data extraction

Higher-level pipelines for getting structured data out of PDFs: pdfplumber-style
table detection, interactive form fields, font-filtered extraction from
prestamped forms, and Tagged-PDF logical structure.

Each guide comes with a downloadable sample PDF and runnable examples with
real output:

| Your PDF | Guide | Sample |
| --- | --- | --- |
| Tables drawn with ruling lines or aligned text | [Tables](tables) | [table.pdf]({{ site.baseurl }}/assets/pdfs/table.pdf) |
| Interactive AcroForm/XFA fields | [Interactive forms](forms) | [form.pdf]({{ site.baseurl }}/assets/pdfs/form.pdf) |
| Data printed on a static form template (no fields) | [Form-aware extraction](filled-forms) | [form.pdf]({{ site.baseurl }}/assets/pdfs/form.pdf) |
| Tagged PDF (accessibility export) | [Struct tree](struct-tree) | — |
