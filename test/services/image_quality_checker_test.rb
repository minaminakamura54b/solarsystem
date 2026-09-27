require "test_helper"

class ImageQualityCheckerTest < ActiveSupport::TestCase
  def image(**attrs)
    InspectionImage.new({
      is_radiometric: true, width: 640, height: 512, captured_at: Time.current,
      gps_lat: 35.6, gps_lng: 138.5, irradiance_w_m2: 750, irradiance_type: "poa"
    }.merge(attrs))
  end

  def check_result(report, key)
    report["checks"].find { |c| c["key"] == key }&.dig("result")
  end

  test "すべての条件を満たせば ok" do
    report = ImageQualityChecker.new(image).report

    assert_equal "ok", report["status"]
    assert_nil report["review_reason"]
    assert_equal "2026-09-v1", report["config_version"]
  end

  test "温度データなしは rejected（no_radiometric）" do
    report = ImageQualityChecker.new(image(is_radiometric: false)).report

    assert_equal "rejected", report["status"]
    assert_equal "no_radiometric", report["review_reason"]
  end

  test "温度データの有無を判定できなければ rejected（metadata_unreadable）" do
    report = ImageQualityChecker.new(image(is_radiometric: nil)).report

    assert_equal "metadata_unreadable", report["review_reason"]
  end

  test "解像度が 640×512 未満なら rejected（low_resolution）" do
    report = ImageQualityChecker.new(image(width: 320, height: 256)).report

    assert_equal "low_resolution", report["review_reason"]
  end

  test "撮影時刻が無ければ rejected（missing_captured_at）" do
    report = ImageQualityChecker.new(image(captured_at: nil)).report

    assert_equal "missing_captured_at", report["review_reason"]
  end

  test "GPS が無ければ warning（解析は止めない）" do
    report = ImageQualityChecker.new(image(gps_lat: nil)).report

    assert_equal "warning", report["status"]
    assert_equal "warning", check_result(report, "missing_gps")
  end

  test "日射量が未入力なら warning" do
    report = ImageQualityChecker.new(image(irradiance_w_m2: nil, irradiance_type: nil)).report

    assert_equal "warning", report["status"]
    assert_equal "warning", check_result(report, "missing_irradiance")
  end

  test "POA 日射量が 600 W/m² 未満なら rejected（low_irradiance）" do
    report = ImageQualityChecker.new(image(irradiance_w_m2: 599)).report

    assert_equal "low_irradiance", report["review_reason"]
  end

  test "POA 日射量が 600 W/m² ちょうどなら ok" do
    assert_equal "ok", ImageQualityChecker.new(image(irradiance_w_m2: 600)).report["status"]
  end

  test "GHI の日射量は低くても rejected にせず、正規化しない旨の warning" do
    report = ImageQualityChecker.new(image(irradiance_w_m2: 300, irradiance_type: "ghi")).report

    assert_equal "warning", report["status"]
    assert_equal "warning", check_result(report, "irradiance_not_poa")
  end

  test "rejected が複数あるときは最初の項目を理由にする" do
    report = ImageQualityChecker.new(image(is_radiometric: false, width: 100)).report

    assert_equal "no_radiometric", report["review_reason"]
    assert_equal 2, report["checks"].count { |c| c["result"] == "rejected" }
  end
end
