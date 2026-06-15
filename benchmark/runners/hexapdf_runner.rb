#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark runner for hexapdf (pure-Ruby comparison).
#
#   ruby hexapdf_runner.rb <text|tables> <file.pdf>
#
# text   — HexaPDF::Content::Processor + show_text callbacks (canonical).
# tables — the minimal lines-based extractor in
#          benchmark/examples/hexapdf_table_extraction.rb, which builds a
#          pdfplumber-style pipeline on hexapdf's own primitives (per-glyph
#          boxes via decode_text_with_positioning + stroked path segments).
#          hexapdf has no built-in table-extraction API, but it exposes
#          everything needed to write one — this measures that.
#
# Emits a single JSON line on stdout, same shape as rpdfium_runner.rb.

require 'json'
require 'set'
require 'ffi'
require 'hexapdf'
require_relative '../examples/hexapdf_table_extraction'

# Same peak-RSS reader as rpdfium_runner.rb, so the two Ruby runners report
# memory the same way (getrusage ru_maxrss = true peak, not current RSS).
module Rusage
  extend FFI::Library
  ffi_lib FFI::Library::LIBC
  attach_function :getrusage, [:int, :pointer], :int

  # ru_maxrss is the third field of struct rusage, after two struct timeval
  # (16 bytes each on linux x86_64/aarch64 and darwin): offset 32.
  def self.max_rss_kb
    buf = FFI::MemoryPointer.new(:char, 256)
    getrusage(0, buf)
    raw = buf.get_long(32)
    RUBY_PLATFORM.include?('darwin') ? raw / 1024 : raw # darwin reports bytes
  end
end

class TextCollector < HexaPDF::Content::Processor
  attr_reader :text

  def initialize
    super
    @text = +''
  end

  def show_text(str)
    @text << decode_text(str)
  end
  alias show_text_with_positioning show_text
end

task, path = ARGV
abort 'usage: hexapdf_runner.rb <text|tables> <file.pdf>' unless %w[text tables].include?(task) && path

expected = JSON.parse(File.read(File.join(File.dirname(path), 'expected.json')))
              .fetch(File.basename(path), {})

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
case task
when 'text'
  extracted = +''
  HexaPDF::Document.open(path) do |doc|
    doc.pages.each do |page|
      collector = TextCollector.new
      page.process_contents(collector)
      extracted << collector.text << "\n"
    end
  end
when 'tables'
  cells = HexaTable.extract(path).flatten.compact
end
time_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)

if task == 'text'
  haystack = extracted.gsub(/\s+/, '')
  truth = expected.fetch('text_sentinels', [])
  found = truth.count { |t| haystack.include?(t) }
  value = extracted.size
else
  cellset = cells.map { |c| c.gsub(/\s+/, '') }.to_set
  truth = expected.fetch('table_cells', [])
  found = truth.count { |t| cellset.include?(t.gsub(/\s+/, '')) }
  value = cells.size
end
correctness = truth.empty? ? nil : (found.to_f / truth.size).round(4)

puts JSON.generate(library: 'hexapdf', task: task, time_ms: time_ms,
                   peak_rss_kb: Rusage.max_rss_kb,
                   correctness: correctness, value: value)
