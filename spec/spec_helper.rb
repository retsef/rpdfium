# frozen_string_literal: true

require "rpdfium"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand(config.seed)

  # Salta tutti i test che richiedono la libreria nativa se non è
  # disponibile. Utile in CI prima che `rpdfium-binary` esista.
  config.before(:suite) do
    begin
      Rpdfium.init!
    rescue ::LoadError, FFI::NotFoundError => e
      warn "PDFium native library not available: #{e.message}"
      warn "Skipping integration specs (set PDFIUM_LIBRARY_PATH to enable)."
      RSpec.configuration.filter_run_excluding(:integration)
    end
  end
end
