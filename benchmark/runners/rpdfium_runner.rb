#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark runner for rpdfium. Executed in its own process by run.rb so
# that peak RSS reflects a single measurement.
#
#   PDFIUM_LIBRARY_PATH=... ruby rpdfium_runner.rb <text|tables> <file.pdf>
#
# Emits a single JSON line on stdout:
#   {"library":"rpdfium","task":"text","time_ms":4.2,"peak_rss_kb":29000,
#    "correctness":1.0,"value":2721}
#
# Correctness is scored against pdfs/expected.json (ground truth written by
# generate_pdfs.rb): fraction of text sentinels found in the extracted text,
# or fraction of expected table cells recovered. The check runs OUTSIDE the
# timed section.

require "json"
require "set"
require "ffi"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "rpdfium"

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
    RUBY_PLATFORM.include?("darwin") ? raw / 1024 : raw # darwin reports bytes
  end
end

task, path = ARGV
abort "usage: rpdfium_runner.rb <text|tables> <file.pdf>" unless task && path

expected = JSON.parse(File.read(File.join(File.dirname(path), "expected.json")))
              .fetch(File.basename(path), {})

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
case task
when "text"
  extracted = Rpdfium.extract_text(path).join("\n")
when "tables"
  cells = Rpdfium.extract_tables(path).flat_map { |t| t[:rows].flatten }.compact
else
  abort "unknown task: #{task}"
end
time_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)

if task == "text"
  haystack = extracted.gsub(/\s+/, "")
  truth = expected.fetch("text_sentinels", [])
  found = truth.count { |t| haystack.include?(t) }
  value = extracted.size
else
  cellset = cells.map { |c| c.gsub(/\s+/, "") }.to_set
  truth = expected.fetch("table_cells", [])
  found = truth.count { |t| cellset.include?(t.gsub(/\s+/, "")) }
  value = cells.size
end
correctness = truth.empty? ? nil : (found.to_f / truth.size).round(4)

puts JSON.generate(library: "rpdfium", task: task, time_ms: time_ms,
                   peak_rss_kb: Rusage.max_rss_kb,
                   correctness: correctness, value: value)
