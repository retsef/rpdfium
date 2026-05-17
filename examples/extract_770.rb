# frozen_string_literal: true

# Extract Modello 770 — QUADRO ST, SV, SX  (using rpdfium)
#
# Usage:
#   ruby extract_770.rb input.pdf [output.csv]
#
# Writes one CSV section per sheet-equivalent (ST Sez.I Mod1, SV Sez.SV Mod1, SX, …).
#
# Layout per ogni record (STn / SVn):
#   Row A data:  top ≈ label_top - 6..8  (periodo + ritenute + importo)
#   Row A hdr:   top ≈ label_top - 13    (campo numbers 1,2,6,7,8) — excluded
#   label:       top = label_top
#   Row B hdr:   top ≈ label_top + 9..21 (campo numbers 9,10,11,14…) — excluded
#   Row B data:  top ≈ label_top + 17..28 (codice tributo + data versamento)
#
# X ranges calibrated to exclude campo-number labels:
#   "11" at x=250.8 → cod_trib starts from x=252
#   "14" at x=301.2 → data_giorno starts from x=305
#   "6"  at x=294.0 → ritenute ends at x=293
#   "8"  at x=466.8 → importo ends at x=465
#   "1"  at x=128.4 → per_mese starts from x=134
#   "2"  at x=207.6 → per_anno ends at x=204

require "rpdfium"
require "csv"

PDF = ARGV[0] or abort "Usage: ruby extract_770.rb file.pdf [output.csv]"
OUT = ARGV[1] || "770_tabelle.csv"

# ── Column X ranges ───────────────────────────────────────────────────────────

ROW_A = {
  per_mese: [134, 156],  # excludes "1" at x=128.4; "0","7" join without space
  per_anno: [156, 204],  # year after mese
  ritenute: [233, 293],  # excludes "6" at x=294
  importo:  [405, 465],  # excludes "8" at x=466.8
}.freeze

ROW_B_I = {             # Sezione I (erario) and SV (comunale)
  cod_trib: [252, 295], # excludes "11" at x=250.8
  data_g:   [305, 326], # excludes "14" at x=301.2
  data_m:   [325, 348],
  data_a:   [346, 390],
}.freeze

ROW_B_II = {            # Sezione II (addizionale regionale)
  cod_trib: [248, 292],
  cod_reg:  [316, 348],
  data_g:   [349, 373],
  data_m:   [370, 394],
  data_a:   [391, 426],
}.freeze

# ── Helpers ───────────────────────────────────────────────────────────────────

def page_quadro(words)
  fx = Rpdfium::Util::FormExtractor.new(words)

  return [:SX, :SX] if fx.has_label?(/^SX\d+$/)
  return [:SV, :SV] if fx.has_label?(/^SV\d+$/)

  if fx.has_label?(/^ST\d+$/)
    # Sez.II has campo "13" (codice regione) in the row-B header at x≈301-315
    has_13 = fx.find_label(/^13$/, 295, 315)
    return [:ST, (has_13 ? :II : :I)]
  end

  [nil, nil]
end

def has_real_data?(records)
  records.any? { |r| r[:ritenute_operate]&.length&.positive? || r[:codice_tributo]&.length&.positive? }
end

# Joins only the parts that are pure digits, separated by "/".
# Filters out "giorno", "mese", "anno" label text captured from Row B headers.
def only_digits(*parts)
  parts.select { |p| p && p.match?(/^\d+$/) }.join("/")
end

# ── Record extraction ─────────────────────────────────────────────────────────

def extract_records(words, quadro, section)
  fx      = Rpdfium::Util::FormExtractor.new(words)
  pat     = /^#{quadro}\d+$/
  skip    = /^#{quadro}1$/       # ST1/SV1 are form header records, not data

  labels  = fx.records(pat, skip: skip)
  return [] if labels.empty?

  first_y = labels.first[:top]
  records = []

  labels.each do |lbl|
    ly = lbl[:top]

    # Row A: narrow band immediately above the label.
    # Using (ly-9, ly-3) excludes the campo-number header row at ~ly-13.
    ra = fx.band(ly - 9, ly - 3)

    # Row B: first record on the page has its data lower (ly+28) because
    # the page header takes space above it; subsequent records sit at ly+17.
    rb = if ly == first_y
           fx.band(ly + 24, ly + 32)
         else
           fx.band(ly + 13, ly + 22)
         end

    per_mese = fx.join_digits(ra, *ROW_A[:per_mese])
    per_anno = fx.pick(ra,        *ROW_A[:per_anno])
    ritenute = fx.pick(ra,        *ROW_A[:ritenute])
    importo  = fx.pick(ra,        *ROW_A[:importo])

    rec = { record: lbl[:text] }

    if section == :I || section == :SV
      cod_trib = fx.pick(rb, *ROW_B_I[:cod_trib])
      data_g   = fx.pick(rb, *ROW_B_I[:data_g])
      data_m   = fx.pick(rb, *ROW_B_I[:data_m])
      data_a   = fx.pick(rb, *ROW_B_I[:data_a])
      rec.merge!(
        periodo:          per_mese.empty? ? "" : "#{per_mese}/#{per_anno}",
        ritenute_operate: ritenute,
        importo_versato:  importo,
        codice_tributo:   cod_trib,
        data_versamento:  only_digits(data_g, data_m, data_a)
      )
    else # :II
      cod_trib = fx.pick(rb, *ROW_B_II[:cod_trib])
      cod_reg  = fx.pick(rb, *ROW_B_II[:cod_reg])
      data_g   = fx.pick(rb, *ROW_B_II[:data_g])
      data_m   = fx.pick(rb, *ROW_B_II[:data_m])
      data_a   = fx.pick(rb, *ROW_B_II[:data_a])
      rec.merge!(
        periodo:          per_mese.empty? ? "" : "#{per_mese}/#{per_anno}",
        ritenute_operate: ritenute,
        importo_versato:  importo,
        codice_tributo:   cod_trib,
        codice_regione:   cod_reg,
        data_versamento:  only_digits(data_g, data_m, data_a)
      )
    end

    # Skip records with no useful data (empty template rows)
    next unless rec[:periodo]&.length&.positive? ||
                rec[:ritenute_operate]&.length&.positive? ||
                rec[:codice_tributo]&.length&.positive?

    records << rec
  end

  records
end

# ── QUADRO SX ─────────────────────────────────────────────────────────────────

def extract_sx(pages)
  all_words = []
  [13, 14].each do |idx|
    next if idx >= pages.length

    all_words.concat(pages[idx].words(x_tolerance: 3, y_tolerance: 3))
  end

  fx   = Rpdfium::Util::FormExtractor.new(all_words)
  seen = {}
  results = []

  fx.records(/^SX\d+$/).each do |lbl|
    next if seen[lbl[:text]]

    ly   = lbl[:top]
    area = fx.band(ly - 8, ly + 25)
    vals = area.select { |w| w[:text].match?(/^\d[\d.]*,\d+$/) }
               .sort_by { |w| w[:x0] }
               .map { |w| w[:text] }
               .uniq

    next unless vals.any?

    results << { campo: lbl[:text], valori: vals.join(" | ") }
    seen[lbl[:text]] = true
  end

  results
end

# ── Main ──────────────────────────────────────────────────────────────────────

all_results = {}       # [quadro, section, mod] => Array<Hash>
seen_sx     = false
mod_counter = Hash.new(0)

Rpdfium.open(PDF) do |doc|
  pages = doc.to_a

  pages.each_with_index do |page, i|
    words          = page.words(x_tolerance: 3, y_tolerance: 3)
    quadro, section = page_quadro(words)
    next unless quadro

    if section == :SX
      unless seen_sx
        recs = extract_sx(pages)
        all_results[[:SX, :SX, 1]] = recs
        seen_sx = true
      end
      next
    end

    recs = extract_records(words, quadro.to_s, section)
    next unless has_real_data?(recs)

    key = [quadro, section]
    mod_counter[key] += 1
    mod = mod_counter[key]

    recs.each { |r| r[:mod] = mod }
    all_results[[quadro, section, mod]] = recs
    warn "  Pag #{i + 1}: #{quadro} Sez.#{section} Mod.#{mod} → #{recs.length} record"
  end
end

# ── Output ────────────────────────────────────────────────────────────────────

CSV.open(OUT, "w") do |csv|
  all_results.sort.each do |key, recs|
    quadro, section, mod = key
    label = section == :SX ? "QUADRO SX" : "#{quadro}_Sez#{section}_Mod#{mod}"

    warn ""
    warn "=" * 60
    warn "  #{label}"
    warn "=" * 60

    next if recs.empty?

    headers = recs.first.keys
    csv << ["# #{label}"]
    csv << headers.map(&:to_s)
    recs.each { |r| csv << headers.map { |h| r[h] } }
    csv << []

    col_w = headers.map { |h| [h.to_s.length, recs.map { |r| r[h].to_s.length }.max].max }
    warn headers.each_with_index.map { |h, i| h.to_s.ljust(col_w[i]) }.join("  ")
    recs.each do |r|
      warn headers.each_with_index.map { |h, i| r[h].to_s.ljust(col_w[i]) }.join("  ")
    end
  end
end

warn ""
warn "Salvato: #{OUT}"
