# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "zlib"

RSpec.describe Rpdfium::IO::PNG do
  it "writes a valid PNG signature and IHDR" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tiny.png")
      # 2×1 pixel: rosso opaco, verde semitrasparente
      rgba = [255, 0, 0, 255, 0, 255, 0, 128].pack("C*")
      described_class.write(path, 2, 1, rgba)

      data = File.binread(path)
      # Signature
      expect(data[0, 8]).to eq("\x89PNG\r\n\x1a\n".b)
      # Primo chunk dopo la signature deve essere IHDR
      ihdr_len = data[8, 4].unpack1("N")
      expect(ihdr_len).to eq(13)
      expect(data[12, 4]).to eq("IHDR")
      width  = data[16, 4].unpack1("N")
      height = data[20, 4].unpack1("N")
      bit_depth, color_type, compression, filter, interlace =
        data[24, 5].unpack("C5")
      expect([width, height, bit_depth, color_type, compression, filter, interlace])
        .to eq([2, 1, 8, 6, 0, 0, 0])
    end
  end

  it "computes correct CRC32 for chunks" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tiny.png")
      rgba = ([255] * 16).pack("C*")  # 4 pixel bianchi
      described_class.write(path, 2, 2, rgba)

      data = File.binread(path)
      # Cammina i chunk e verifica i CRC
      offset = 8
      while offset < data.bytesize
        len = data[offset, 4].unpack1("N")
        type = data[offset + 4, 4]
        chunk_data = data[offset + 8, len]
        crc_stored = data[offset + 8 + len, 4].unpack1("N")
        crc_actual = Zlib.crc32(type + chunk_data)
        expect(crc_actual).to eq(crc_stored), "CRC mismatch on chunk #{type}"
        offset += 12 + len
      end
    end
  end
end
