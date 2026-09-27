require "test_helper"

class ImagePairingTest < ActiveSupport::TestCase
  FakeFile = Struct.new(:filename)

  def files(*names)
    names.map { |n| FakeFile.new(n) }
  end

  test "ファイル名の _T / _V でペアにする" do
    result = ImagePairing.pair(files("DJI_0001_T.JPG", "DJI_0001_V.JPG", "DJI_0002_T.JPG"))

    assert_equal 2, result.pairs.size
    assert_equal "DJI_0001_V.JPG", result.pairs.first.rgb.filename
    assert_nil result.pairs.last.rgb
    assert_empty result.unpaired_rgb
  end

  test "大文字・小文字を区別しない" do
    result = ImagePairing.pair(files("dji_0001_t.jpg", "DJI_0001_V.JPG"))

    assert_equal "DJI_0001_V.JPG", result.pairs.sole.rgb.filename
  end

  test "対になるサーモ画像が無い RGB は unpaired_rgb に入れる" do
    result = ImagePairing.pair(files("DJI_0001_T.JPG", "DJI_0009_V.JPG"))

    assert_equal [ "DJI_0009_V.JPG" ], result.unpaired_rgb.map(&:filename)
  end

  test "末尾に _T / _V が無いファイルはサーモ画像として扱う" do
    result = ImagePairing.pair(files("IMG_0001.JPG"))

    assert_equal "IMG_0001.JPG", result.pairs.sole.thermal.filename
  end

  test "番号の自然な順に並べる" do
    result = ImagePairing.pair(files("DJI_0010_T.JPG", "DJI_0002_T.JPG", "DJI_0001_T.JPG"))

    assert_equal %w[DJI_0001_T.JPG DJI_0002_T.JPG DJI_0010_T.JPG], result.pairs.map { |p| p.thermal.filename }
  end
end
