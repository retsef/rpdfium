# frozen_string_literal: true

require "spec_helper"

# Integration tests for Rpdfium::Annotation. The PDF under test is built
# inline (no fixture file needed): one page with a single Link annotation
# carrying a URI action.
RSpec.describe Rpdfium::Annotation, :integration do
  # Minimal valid PDF with a /Link annotation pointing at `uri`.
  # The URI must not contain parentheses or backslashes (PDF literal
  # string delimiters are not escaped here).
  def minimal_link_pdf(uri)
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Annots [4 0 R] >>",
      "<< /Type /Annot /Subtype /Link /Rect [10 10 100 30] /Border [0 0 0] " \
        "/A << /Type /Action /S /URI /URI (#{uri}) >> >>",
    ]
    pdf = +"%PDF-1.4\n"
    offsets = []
    objects.each_with_index do |body, i|
      offsets << pdf.bytesize
      pdf << "#{i + 1} 0 obj\n#{body}\nendobj\n"
    end
    xref_pos = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.each { |o| pdf << format("%010d 00000 n \n", o) }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\n" \
           "startxref\n#{xref_pos}\n%%EOF\n"
    pdf
  end

  describe "#link_uri" do
    # Regression: FPDFAction_GetURIPath returns 7-bit ASCII bytes, unlike
    # most PDFium getters which return UTF-16LE. Decoding them as UTF-16
    # produced CJK garbage ("https://" came back as "瑨灴㩳⼯...").
    it "returns the URI verbatim, not mangled as UTF-16" do
      uri = "https://github.com/retsef/rpdfium"
      Rpdfium.open(minimal_link_pdf(uri)) do |doc|
        links = doc.page(0).links
        expect(links.size).to eq(1)
        expect(links.first.link_uri).to eq(uri)
      end
    end

    it "handles odd-length URIs (no truncation, no terminator residue)" do
      uri = "https://example.com/a" # odd byte count incl. terminator
      Rpdfium.open(minimal_link_pdf(uri)) do |doc|
        expect(doc.page(0).links.first.link_uri).to eq(uri)
      end
    end

    it "exposes the annotation as :link subtype with a bbox" do
      Rpdfium.open(minimal_link_pdf("https://example.com")) do |doc|
        annot = doc.page(0).annotations.first
        expect(annot.subtype).to eq(:link)
        expect(annot.bbox).to include(:x0, :x1, :top, :bottom)
      end
    end
  end
end
