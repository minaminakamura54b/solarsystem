require "test_helper"

class ImageMetadataExtractorTest < ActiveSupport::TestCase
  test "DJI の R-JPEG のタグから属性を取り出す" do
    attrs = ImageMetadataExtractor.new(dji_thermal_tags).attributes

    assert_equal "DJI M3T", attrs[:camera_model]
    assert_equal 640, attrs[:width]
    assert_equal 512, attrs[:height]
    assert_equal BigDecimal("35.6625"), attrs[:gps_lat]
    assert_equal BigDecimal("30.1"), attrs[:altitude_m]
    assert_equal BigDecimal("-90.0"), attrs[:gimbal_pitch]
    assert_equal true, attrs[:is_radiometric]
    assert_equal %w[ThermalData Emissivity], attrs[:metadata]["radiometric_tags_found"]
    assert_not attrs[:metadata].key?("ThermalData"), "バイナリのタグは保存しない"
  end

  test "撮影時刻はタイムゾーンが無ければ設定のタイムゾーン（Asia/Tokyo）の現地時刻として解釈する" do
    attrs = ImageMetadataExtractor.new(dji_thermal_tags).attributes

    assert_equal Time.utc(2026, 9, 20, 1, 15, 30), attrs[:captured_at]
  end

  test "OffsetTimeOriginal があればそれを使う" do
    attrs = ImageMetadataExtractor.new(dji_thermal_tags(OffsetTimeOriginal: "+00:00")).attributes

    assert_equal Time.utc(2026, 9, 20, 10, 15, 30), attrs[:captured_at]
  end

  test "撮影時刻が読めなければ nil" do
    attrs = ImageMetadataExtractor.new(dji_thermal_tags(DateTimeOriginal: "0000:00:00 00:00:00")).attributes

    assert_nil attrs[:captured_at]
  end

  test "温度データのタグが無ければ is_radiometric は false" do
    tags = dji_thermal_tags.except("ThermalData", "Emissivity")

    assert_equal false, ImageMetadataExtractor.new(tags).attributes[:is_radiometric]
  end

  test "南緯・西経は負の値にする" do
    tags = dji_thermal_tags(GPSLatitude: 33.9, GPSLatitudeRef: "S", GPSLongitude: 151.2, GPSLongitudeRef: "W")
    attrs = ImageMetadataExtractor.new(tags).attributes

    assert_equal BigDecimal("-33.9"), attrs[:gps_lat]
    assert_equal BigDecimal("-151.2"), attrs[:gps_lng]
  end

  test "RelativeAltitude が無ければ GPSAltitude を使う" do
    tags = dji_thermal_tags(GPSAltitude: 812.5).except("RelativeAltitude")

    assert_equal BigDecimal("812.5"), ImageMetadataExtractor.new(tags).attributes[:altitude_m]
  end
end
