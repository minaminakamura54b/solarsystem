require "test_helper"

# サーモの位置から RGB のおおよその位置を画角の比で求める（Phase 7）
class RgbCropMappingTest < ActiveSupport::TestCase
  setup do
    @config = LayoutOverlayConfig.new(
      version: "t", max_residual_panel_width_ratio: 0.25,
      georef: { max_off_nadir_deg: 5, require_rtk_fixed: true, max_rtk_std_m: 0.1 },
      cameras: { "CAM" => { ifov_mrad: 1.0, rgb_ifov_mrad: 0.4, rgb_reference_width: 4000 }, "THERMAL_ONLY" => { ifov_mrad: 1.0 } }
    )
    @image = InspectionImage.new(camera_model: "CAM", width: 640, height: 512)
  end

  test "中心は動かさず、画角の比で縮める（横 640 mrad / 1600 mrad、縦 512 mrad / 1200 mrad）" do
    mapping = RgbCropMapping.for(@image, config: @config)

    sx, sy = mapping.scales(4000, 3000)
    assert_in_delta 0.4, sx, 1e-9
    assert_in_delta 512.0 / 1200, sy, 1e-9
    box = mapping.to_rgb({ "x1" => 0.5, "x2" => 1.0, "y1" => 0.0, "y2" => 0.5 }, 4000, 3000)
    assert_in_delta 0.5, box["x1"], 1e-9
    assert_in_delta 0.7, box["x2"], 1e-9
    assert_in_delta 0.5 - 0.5 * 512.0 / 1200, box["y1"], 1e-9
  end

  test "RGB の解像度が違っても、画角は基準の値から決まる" do
    mapping = RgbCropMapping.for(@image, config: @config)

    assert_in_delta mapping.scales(4000, 3000)[0], mapping.scales(2000, 1500)[0], 1e-9
  end

  test "RGB の画角が設定に無いカメラ・画像の大きさが分からない画像は nil（呼び出し側は同じ正規化座標を使う）" do
    assert_nil RgbCropMapping.for(InspectionImage.new(camera_model: "THERMAL_ONLY", width: 640, height: 512), config: @config)
    assert_nil RgbCropMapping.for(InspectionImage.new(camera_model: "CAM"), config: @config)
  end

  test "設定ファイルの M4T には RGB の画角がある" do
    assert LayoutOverlayConfig.current.rgb_optics("DJI M4T")
  end
end
