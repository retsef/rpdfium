---
title: Annotations & links
parent: Basics
nav_order: 5
---

# Annotations & links
{: .no_toc }

1. TOC
{:toc}

---

{: .note }
> Sample PDF for this guide:
> [example.pdf]({{ site.baseurl }}/assets/pdfs/example.pdf) — the invoice
> footer contains a clickable link annotation.

## Annotations

```ruby
require "rpdfium"

Rpdfium.open("example.pdf") do |doc|
  doc.page(0).annotations.each do |a|
    puts "#{a.subtype}: #{a.bbox.inspect}"
  end
end
```

Output:

```
link: {x0: 50.0, x1: 250.0, top: 766.88, bottom: 781.88}
```

Annotation dictionary values are reachable with `[]` (e.g. `a[:Contents]`
for comment text on `:text`/`:highlight` annotations).

## Links

```ruby
Rpdfium.open("example.pdf") do |doc|
  doc.page(0).links.each do |link|
    puts link.link_uri || "→ page #{link.link_dest_page}"
  end
end
```

Output:

```
https://github.com/retsef/rpdfium
```

`link_uri` is set for external URI actions; internal GoTo links report the
target page through `link_dest_page` instead.

For bookmarks (outline) and file attachments, see
[Documents & pages](documents).
