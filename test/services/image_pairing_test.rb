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

  test "DJI の名前は、番号が同じで撮影時刻の差が設定の秒数以内なら組にする" do
    result = ImagePairing.pair(files("DJI_20260716171623_0052_T.JPG", "DJI_20260716171624_0052_V.JPG",
                                     "DJI_20260716171625_0053_T.JPG", "DJI_20260716171625_0053_V.JPG"))

    assert_equal %w[DJI_20260716171624_0052_V.JPG DJI_20260716171625_0053_V.JPG], result.pairs.map { |p| p.rgb.filename }
    assert_empty result.unpaired_rgb
  end

  test "差の秒数は設定（pairing_max_time_gap_seconds）で、境目の秒数ちょうどは組にする" do
    names = files("DJI_20260716171623_0052_T.JPG", "DJI_20260716171625_0052_V.JPG")

    assert_equal "DJI_20260716171625_0052_V.JPG", ImagePairing.pair(names, max_gap_seconds: 2).pairs.sole.rgb.filename
    assert_nil ImagePairing.pair(names, max_gap_seconds: 1).pairs.sole.rgb
  end

  test "番号が同じでも撮影時刻が設定を超えてずれていれば組にせず、時刻のずれとして返す" do
    result = ImagePairing.pair(files("DJI_20260716171623_0052_T.JPG", "DJI_20260716180000_0052_V.JPG", "DJI_20260716171700_0099_V.JPG"),
                               max_gap_seconds: 2)

    assert_nil result.pairs.sole.rgb
    assert_equal %w[DJI_20260716180000_0052_V.JPG DJI_20260716171700_0099_V.JPG], result.unpaired_rgb.map(&:filename)
    assert_equal %w[DJI_20260716180000_0052_V.JPG], result.mismatched_rgb.map(&:filename)
  end

  test "同じ番号の RGB が複数あれば、時刻の差が小さいものと 1 対 1 で組にする" do
    result = ImagePairing.pair(files("DJI_20260716171623_0052_T.JPG", "DJI_20260716171624_0052_V.JPG",
                                     "DJI_20260716171622_0052_V.JPG", "DJI_20260716171623_0052_V.JPG"))

    assert_equal "DJI_20260716171623_0052_V.JPG", result.pairs.sole.rgb.filename
    assert_equal 2, result.unpaired_rgb.size
  end

  test "名前の末尾が「 (2)」などの複製は、サーモ・RGB とも登録せず duplicates に入れる" do
    result = ImagePairing.pair(files("DJI_20260716171623_0052_T.JPG", "DJI_20260716171623_0052_V.JPG",
                                     "DJI_20260716171623_0052_V (2).JPG", "DJI_20260716171623_0052_T (3).JPG"))

    assert_equal "DJI_20260716171623_0052_V.JPG", result.pairs.sole.rgb.filename
    assert_equal [ "DJI_20260716171623_0052_V (2).JPG", "DJI_20260716171623_0052_T (3).JPG" ], result.duplicates.map(&:filename)
    assert_empty result.unpaired_rgb
  end
end
