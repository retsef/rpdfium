#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark driver. Runs every (pdf x task x library) combination in an
# isolated subprocess, takes the minimum of N timed runs after a warm-up run
# (to neutralize OS page-cache effects), and prints a Markdown results table.
#
# Libraries compared: rpdfium, pypdfium2, pdfplumber, hexapdf.
# Metrics: execution time (min of N), peak memory (RSS, max of N), and
# correctness — the fraction of ground-truth data (pdfs/expected.json)
# recovered by each library.
#
#   PDFIUM_LIBRARY_PATH=/path/to/libpdfium.so ruby benchmark/run.rb
#
#   ruby benchmark/run.rb --runs 5            # timed runs per combination
#   ruby benchmark/run.rb --only rpdfium      # comma-separated library filter
#   ruby benchmark/run.rb --json              # raw JSON instead of Markdown
#   ruby benchmark/run.rb 01_simple.pdf       # only the given pdfs (basename)
#
# Comparison runners need Python 3 with pdfplumber / pypdfium2 and the
# hexapdf gem; missing runners are skipped with a notice.

require "json"
require "open3"
require "optparse"

PDF_DIR = File.expand_path("pdfs", __dir__)
RUNNER_DIR = File.expand_path("runners", __dir__)

RUNNERS = {
  "rpdfium" => {
    cmd: ->(task, pdf) { [RbConfig.ruby, File.join(RUNNER_DIR, "rpdfium_runner.rb"), task, pdf] },
    tasks: %w[text tables],
    available: -> { true }, # library lookup: env var → rpdfium-binary → system
  },
  "pypdfium2" => {
    cmd: ->(task, pdf) { ["python3", File.join(RUNNER_DIR, "pypdfium2_runner.py"), task, pdf] },
    tasks: %w[text],
    available: -> { system("python3", "-c", "import pypdfium2", err: File::NULL) },
  },
  "pdfplumber" => {
    cmd: ->(task, pdf) { ["python3", File.join(RUNNER_DIR, "pdfplumber_runner.py"), task, pdf] },
    tasks: %w[text tables],
    available: -> { system("python3", "-c", "import pdfplumber", err: File::NULL) },
  },
  "hexapdf" => {
    cmd: ->(task, pdf) { [RbConfig.ruby, File.join(RUNNER_DIR, "hexapdf_runner.rb"), task, pdf] },
    tasks: %w[text tables], # tables via examples/hexapdf_table_extraction.rb
    available: -> { system(RbConfig.ruby, "-e", "require 'hexapdf'", err: File::NULL) },
  },
}.freeze

options = { runs: 3, only: nil, json: false }
pdf_filter = OptionParser.new do |op|
  op.on("--runs N", Integer) { |n| options[:runs] = n }
  op.on("--only LIBS", String) { |s| options[:only] = s.split(",") }
  op.on("--json") { options[:json] = true }
end.parse(ARGV)

pdfs = Dir[File.join(PDF_DIR, "*.pdf")].sort
pdfs.select! { |p| pdf_filter.include?(File.basename(p)) } unless pdf_filter.empty?
abort "No PDFs found — run `ruby benchmark/generate_pdfs.rb` first." if pdfs.empty?

libraries = RUNNERS.keys
libraries &= options[:only] if options[:only]
libraries = libraries.select do |lib|
  RUNNERS[lib][:available].call.tap do |ok|
    warn "skipping #{lib}: not available in this environment" unless ok
  end
end

def measure(cmd)
  out, err, status = Open3.capture3(*cmd)
  return nil unless status.success?

  JSON.parse(out)
rescue JSON::ParserError
  warn "unparsable runner output: #{out.inspect} #{err.inspect}"
  nil
end

results = []
pdfs.each do |pdf|
  %w[text tables].each do |task|
    libraries.each do |lib|
      next unless RUNNERS[lib][:tasks].include?(task)

      cmd = RUNNERS[lib][:cmd].call(task, pdf)
      measure(cmd) # warm-up, discarded
      runs = Array.new(options[:runs]) { measure(cmd) }.compact
      next if runs.empty?

      results << {
        "pdf" => File.basename(pdf),
        "task" => task,
        "library" => lib,
        "time_ms" => runs.map { |r| r["time_ms"] }.min,
        "peak_rss_kb" => runs.map { |r| r["peak_rss_kb"] }.max,
        "correctness" => runs.first["correctness"],
        "value" => runs.first["value"],
      }
      r = results.last
      warn format("%-16s %-7s %-11s %9.1f ms  %7d KB  corr=%s",
                  r["pdf"], task, lib, r["time_ms"], r["peak_rss_kb"],
                  r["correctness"].nil? ? "n/a" : format("%5.1f%%", r["correctness"] * 100))
    end
  end
end

if options[:json]
  puts JSON.pretty_generate(results)
  exit
end

puts
puts "| PDF | Task | Library | Time | Peak RSS | Correctness |"
puts "| --- | --- | --- | ---: | ---: | ---: |"
results.each do |r|
  time = r["time_ms"] >= 1000 ? format("%.2f s", r["time_ms"] / 1000.0) : format("%.0f ms", r["time_ms"])
  corr = r["correctness"].nil? ? "n/a" : format("%.1f%%", r["correctness"] * 100)
  puts format("| %s | %s | %s | %s | %d MB | %s |",
              r["pdf"], r["task"], r["library"], time, r["peak_rss_kb"] / 1024, corr)
end
