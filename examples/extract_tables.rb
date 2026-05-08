# frozen_string_literal: true

# Estrai tutte le tabelle di un PDF in CSV, una sezione per tabella.
#
# Uso:
#   ruby extract_tables.rb invoice.pdf [output.csv] [--strategy text]
#
# Strategie:
#   lines (default) — usa segmenti vettoriali (PDF con tabelle bordate)
#   text            — clustering di parole (PDF senza linee, "tabular layout")

require "rpdfium"
require "csv"
require "optparse"

input  = ARGV[0] or abort "Usage: ruby extract_tables.rb file.pdf [out.csv] [--strategy lines|text]"
output = ARGV[1] || "tables.csv"

opts = { vertical_strategy: :lines, horizontal_strategy: :lines, auto_fallback: true }

OptionParser.new do |o|
  o.on("--strategy STRAT", %w[lines text]) do |s|
    opts[:vertical_strategy] = opts[:horizontal_strategy] = s.to_sym
  end
  o.on("--snap N", Float) { |n| opts[:snap_tolerance] = n }
  o.on("--min-words N", Integer) { |n| opts[:min_words_vertical] = n }
end.parse!(ARGV[2..] || [])

n_tables = 0
CSV.open(output, "w") do |csv|
  Rpdfium.open(input) do |doc|
    doc.each do |page|
      tables = Rpdfium::Table::Extractor.new(page, **opts).extract
      tables.each_with_index do |rows, i|
        n_tables += 1
        csv << ["# Page #{page.index + 1}, table #{i + 1}"]
        rows.each { |row| csv << row }
        csv << []
      end
    end
  end
end
puts "Wrote #{n_tables} tables to #{output}"
