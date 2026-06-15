---
title: Images
parent: Basics
nav_order: 4
---

# Images

{: .note }
> Sample PDF for this guide:
> [example.pdf]({{ site.baseurl }}/assets/pdfs/example.pdf) — the invoice
> carries a small embedded logo image.

```ruby
require "rpdfium"

Rpdfium.open("example.pdf") do |doc|
  doc.page(0).images.each_with_index do |img, i|
    meta = img.metadata
    puts "#{meta[:width]}×#{meta[:height]} @ #{meta[:horizontal_dpi]} DPI, " \
         "#{meta[:colorspace]}, #{meta[:bits_per_pixel]} bpp"
    puts "filters: #{img.filters}"
    img.save("logo_#{i}.png")
  end
end
```

Output:

```
48×48 @ 96.0 DPI, devicergb, 24 bpp
filters: ["FlateDecode"]
```

## Save semantics

```ruby
# JPEG passthrough when filters == ["DCTDecode"]; otherwise rendered to PNG
img.save("img.jpg")

# Or get raw/decoded bytes for custom processing
img.raw_bytes      # as stored
img.decoded_bytes  # post-filters (raster)
```

{: .note }
> When an image's only filter is `DCTDecode`, `save` writes the original JPEG
> bytes unchanged (passthrough). Any other filter chain — like the
> `FlateDecode` logo above — is decoded and re-encoded to PNG.
