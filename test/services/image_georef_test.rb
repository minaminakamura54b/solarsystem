require "test_helper"

# 画像の位置（georef）の記録。合成のタグだけを使う
class ImageGeorefTest < ActiveSupport::TestCase
  RTK_TAGS = {
    "AbsoluteAltitude" => 67.6, "GimbalPitchDegree" => -90.0, "GimbalYawDegree" => 179.5, "GimbalRollDegree" => 180.0,
    "GpsStatus" => "RTK", "RtkFlag" => 50, "RtkStdLon" => 0.003, "RtkStdLat" => 0.002, "RtkStdHgt" => 0.006,
    "LRFStatus" => "Normal", "LRFTargetDistance" => 39.1, "LRFTargetAbsAlt" => 28.6
  }.freeze

  def image(tags = RTK_TAGS, camera_model: "DJI M4T", lat: 35.0, lng: 139.0)
    InspectionImage.new(camera_model: camera_model, gps_lat: lat, gps_lng: lng, width: 640, height: 512, metadata: tags)
  end

  test "RTK 固定解・真下向き・設定にあるカメラなら位置合わせに使える" do
    record = ImageGeoref.new(image).record

    assert record["usable"]
    assert_empty record["issues"]
    assert_equal 0.975, record["camera"]["ifov_mrad"]
    assert_equal "config", record["camera"]["ifov_source"]
    assert_in_delta 359.5, record["camera"]["image_up_azimuth_deg"], 1e-6
    assert_equal({ "distance_m" => 39.1, "target_abs_alt_m" => 28.6 }, record["lrf"])
    assert_equal LayoutOverlayConfig.current.version, record["version"]
  end

  test "使えない理由をすべて残す（失敗にはしない）" do
    tags = RTK_TAGS.merge("GimbalPitchDegree" => -60.0, "RtkFlag" => 16, "RtkStdLon" => 0.5).except("AbsoluteAltitude")
    record = ImageGeoref.new(image(tags, camera_model: "Other Cam", lat: nil)).record

    assert_not record["usable"]
    assert_equal %w[no_gps no_absolute_altitude not_nadir rtk_not_fixed rtk_std_large unknown_camera], record["issues"]
    assert_match "RTK が固定解ではありません", ImageGeoref.describe(record)
  end

  test "LRF が Normal でなければ使わない" do
    record = ImageGeoref.new(image(RTK_TAGS.merge("LRFStatus" => "TooFar"))).record

    assert_nil record["lrf"]
  end

  test "真下からのずれは設定の範囲（5°）まで許す" do
    assert ImageGeoref.new(image(RTK_TAGS.merge("GimbalPitchDegree" => -86.0))).record["usable"]
    assert_includes ImageGeoref.new(image(RTK_TAGS.merge("GimbalPitchDegree" => -84.0))).record["issues"], "not_nadir"
  end
end
