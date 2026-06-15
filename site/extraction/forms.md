---
title: Interactive forms
parent: Data extraction
nav_order: 2
---

# Interactive forms (read-only)

{: .note }
> Sample PDF for this guide:
> [form.pdf]({{ site.baseurl }}/assets/pdfs/form.pdf) — the
> "RISERVATO ALL'UFFICIO" box at the bottom contains real AcroForm fields.

```ruby
require "rpdfium"

Rpdfium.open("form.pdf") do |doc|
  puts doc.form_type      # :acroform / :xfa_full / :xfa_foreground / :none

  doc.page(0).form_fields.each do |f|
    h = f.to_h
    puts "#{h[:name].ljust(12)} #{h[:type].to_s.ljust(10)} => #{h[:value].inspect}"
  end
end
```

Output:

```
acroform
operatore    textfield  => "Mario Rossi"
protocollo   textfield  => "2026-001234"
verificato   checkbox   => "Yes"
```

`Field#to_h` exposes everything at once:

```ruby
{name: "operatore",
 type: :textfield,
 value: "Mario Rossi",
 readonly: false,
 required: false,
 bbox: {x0: 50.0, x1: 230.0, top: 466.88, bottom: 486.88}}
```

{: .note }
> These are interactive AcroForm/XFA fields embedded in the PDF. Many
> "filled-out" government forms have **no** form fields — the data is static
> graphics text painted on a template. The same `form.pdf` demonstrates that
> case too: see [Form-aware extraction](filled-forms).
