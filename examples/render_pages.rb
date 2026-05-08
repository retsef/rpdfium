# frozen_string_literal: true

# Renderizza ogni pagina di un PDF in PNG.
#
# Uso: ruby render_pages.rb file.pdf out_dir [scale]

require "rpdfium"

input  = ARGV[0] or abort "Usage: ruby render_pages.rb file.pdf out_dir [scale]"
outdir = ARGV[1] or abort "missing output dir"
scale  = (ARGV[2] || 2.0).to_f

Rpdfium.render_to_pngs(input, output_dir: outdir, scale: scale).each do |path|
  puts "wrote #{path}"
end
