require "test_helper"

# 実際に exiftool を動かすテスト（CI では apt で exiftool を入れている）
class ExifReaderTest < ActiveSupport::TestCase
  test "EXIF のタグを読み取る" do
    result = ExifReader.read(file_fixture("thermal_plain_T.jpg"))

    assert result.ok?, result.error
    assert_equal "DJI", result.tags["Make"]
    assert_equal "TEST THERMAL", result.tags["Model"]
    assert_equal "2026:09:20 10:15:30", result.tags["DateTimeOriginal"]
    assert_equal 640, result.tags["ImageWidth"]
    assert_in_delta 35.6625, result.tags["GPSLatitude"], 0.0001
  end

  test "存在しないファイルはエラーを返す" do
    result = ExifReader.read(Rails.root.join("tmp/no_such_file.jpg"))

    assert_not result.ok?
    assert_match "exiftool", result.error
  end

  test "温度データの無い JPEG からは温度データのタグが見つからない" do
    tags = ExifReader.read(file_fixture("thermal_plain_T.jpg")).tags

    assert_equal false, ImageMetadataExtractor.new(tags).attributes[:is_radiometric]
  end
end
