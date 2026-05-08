# frozen_string_literal: true

# Estrai tutte le immagini embedded di un PDF.
# - Le immagini con filtro DCTDecode (JPEG) vengono salvate come .jpg
#   senza ricodifiche (passthrough byte-perfect).
# - Le altre vengono renderizzate (con maschere e matrice applicate)
#   e salvate come .png via il writer puro Ruby integrato.
#
# Uso: ruby extract_images.rb file.pdf out_dir

require "rpdfium"
require "fileutils"

input  = ARGV[0] or abort "Usage: ruby extract_images.rb file.pdf out_dir"
outdir = ARGV[1] or abort "missing output dir"
FileUtils.mkdir_p(outdir)

n = 0
Rpdfium.open(input) do |doc|
  doc.each do |page|
    page.images.each_with_index do |img, i|
      meta = img.metadata
      ext  = img.filters == ["DCTDecode"] ? "jpg" : "png"
      path = File.join(outdir, format("p%04d_i%02d.%s", page.index + 1, i, ext))
      img.save(path)
      n += 1
      puts "#{path}  #{meta[:width]}×#{meta[:height]} #{meta[:colorspace]}"
    end
  end
end
puts "Extracted #{n} images"
