# frozen_string_literal: true

require_relative "lib/rpdfium/version"

Gem::Specification.new do |spec|
  spec.name          = "rpdfium"
  spec.version       = Rpdfium::VERSION
  spec.authors       = ["Your Name"]
  spec.email         = ["you@example.com"]

  spec.summary       = "Ruby bindings for PDFium with table extraction"
  spec.description   = <<~DESC
    FFI bindings to Google's PDFium library, the same engine that powers
    Chrome's PDF viewer. Provides text extraction with character-level
    metadata (font, weight, origin, angle), vector path access, image
    extraction, annotations, AcroForm fields, page rendering, and
    pdfplumber-style table detection. Inspired by pypdfium2 and pdfplumber.
  DESC
  spec.homepage      = "https://github.com/yourname/rpdfium"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri"   => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb"] +
               %w[README.md CHANGELOG.md LICENSE].select { |f| File.exist?(f) }
  spec.require_paths = ["lib"]

  # Solo dipendenza obbligatoria. PDFium nativo è caricato a runtime via
  # ENV["PDFIUM_LIBRARY_PATH"] o dalla gemma sorella `rpdfium-binary`.
  spec.add_dependency "ffi", "~> 1.16"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake",  "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.60"
end
