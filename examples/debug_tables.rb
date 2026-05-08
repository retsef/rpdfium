# frozen_string_literal: true

# Genera un PNG di debug per ogni pagina con linee/intersezioni/tabelle
# rilevate sovrapposte. Equivalente di pdfplumber.debug_tablefinder().
#
# Uso:
#   ruby debug_tables.rb file.pdf out_dir [--strategy lines|text]

require "rpdfium"
require "fileutils"

input  = ARGV[0] or abort "Usage: ruby debug_tables.rb file.pdf out_dir [--strategy ...]"
outdir = ARGV[1] or abort "missing output dir"
FileUtils.mkdir_p(outdir)

opts = { vertical_strategy: :lines, horizontal_strategy: :lines, auto_fallback: true }
if (i = ARGV.index("--strategy")) && (s = ARGV[i + 1])
  opts[:vertical_strategy] = opts[:horizontal_strategy] = s.to_sym
end

Rpdfium.open(input) do |doc|
  doc.each do |page|
    out = File.join(outdir, format("debug_%04d.png", page.index + 1))
    Rpdfium::Table::Debugger.visualize(page, out, scale: 2.0, **opts)
    puts "wrote #{out}"
  end
end
