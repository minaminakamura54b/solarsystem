require "test_helper"

class DatasetExporterTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection(files: %w[thermal_plain_T.jpg lowres_T.jpg])
    @first, @second = @inspection.inspection_images.to_a
    @inspection.inspection_images.each { |i| i.update_columns(analysis_status: "completed", captured_at: Time.utc(2026, 9, 20, 1, 15)) }
    @out = Rails.root.join("tmp", "dataset_test_#{Process.pid}")
  end

  teardown { FileUtils.rm_rf(@out) }

  def anomaly(image, **attrs)
    image.anomalies.create!({ inspection: @inspection, anomaly_type: "hotspot", severity: "warning", delta_t: 6,
                              bbox: { "x1" => 0.2, "y1" => 0.3, "x2" => 0.3, "y2" => 0.5 } }.merge(attrs))
  end

  test "確定・修正した異常を YOLO 形式のラベルにし、却下だけの画像は負例（空のラベル）にする" do
    anomaly(@first, review_status: "confirmed", locked: true)
    anomaly(@first, review_status: "corrected", locked: true, final_anomaly_type: "module_wide",
            final_bbox: { "x1" => 0.5, "y1" => 0.5, "x2" => 0.7, "y2" => 0.6 })
    anomaly(@second, review_status: "rejected", locked: true, rejection_reason: "glare")

    result = DatasetExporter.new(@out).export!

    assert_equal [ 2, 2, 1 ], [ result.images, result.labels, result.negatives ]
    assert_equal Anomaly::ANOMALY_TYPES, File.read(@out.join("classes.txt")).split("\n")
    first_label = Dir[@out.join("labels", "*_0001_*.txt")].sole
    assert_equal [ "0 0.250000 0.400000 0.100000 0.200000", "3 0.600000 0.550000 0.200000 0.100000" ], File.read(first_label).split("\n").sort
    assert_equal "", File.read(Dir[@out.join("labels", "*_0002_*.txt")].sole), "却下だけの画像は空のラベル"
    assert_equal 2, Dir[@out.join("images", "*.jpg")].size
  end

  test "manifest.csv に画像ごとの撮影条件と数値、labels_detail.csv にラベル・却下した候補の数値を出す" do
    anomaly(@first, review_status: "confirmed", locked: true, normalized_delta_t: 7.5, threshold_basis: "normalized")
    anomaly(@second, review_status: "rejected", locked: true, rejection_reason: "shadow")

    DatasetExporter.new(@out).export!

    manifest = CSV.read(@out.join("manifest.csv"), headers: true)
    assert_equal 2, manifest.size
    row = manifest.find { |r| r["image_sequence"] == "1" }
    assert_equal [ "800.0", "poa", "1", "0", "false" ], row.values_at("irradiance_w_m2", "irradiance_type", "labels", "rejected", "negative")
    assert_equal "2026-09-20T10:15:00+09:00", row["captured_at"]
    detail = CSV.read(@out.join("labels_detail.csv"), headers: true)
    assert_equal %w[confirmed rejected], detail.map { |r| r["review_status"] }.sort
    assert_equal "shadow", detail.find { |r| r["review_status"] == "rejected" }["rejection_reason"]
  end

  test "未確定の候補が残っている画像・解析が終わっていない画像は含めない" do
    anomaly(@first, review_status: "pending")
    @second.update_columns(analysis_status: "needs_review")

    result = DatasetExporter.new(@out).export!

    assert_equal [ 0, 1 ], [ result.images, result.skipped_pending ]
    assert_empty Dir[@out.join("labels", "*")]
  end

  test "異常の無い解析済みの画像も負例として含める" do
    result = DatasetExporter.new(@out).export!

    assert_equal [ 2, 2 ], [ result.images, result.negatives ]
  end
end
