require "test_helper"

class ProcessInspectionImageJobTest < ActiveSupport::TestCase
  setup do
    @inspection = create_session_inspection
    @image = @inspection.inspection_images.first
  end

  test "受け入れ確認: 温度データの無い JPEG は needs_review（no_radiometric）になる（実際の exiftool を使用）" do
    ProcessInspectionImageJob.perform_now(@image.id)

    @image.reload
    assert_equal "needs_review", @image.analysis_status
    assert_equal "no_radiometric", @image.review_reason
    assert_equal false, @image.is_radiometric
    assert_equal "DJI TEST THERMAL", @image.camera_model
    assert_equal jst("2026-09-20 10:15:30"), @image.captured_at
    assert_equal "needs_review", @inspection.reload.analysis_status
    assert_nil @inspection.severity, "正常にはしない"
  end

  test "品質 ok でグリッドが無ければ needs_review（grid_required）にし、グリッドの提案を作る" do
    @inspection.weather_readings.create!(observed_at: jst("2026-09-20 10:10"), irradiance_w_m2: 750, irradiance_type: "poa")

    assert_enqueued_with(job: GridProposalJob, args: [ @image.id ]) do
      with_fake_exif(tags: dji_thermal_tags) do
        ProcessInspectionImageJob.perform_now(@image.id)
      end
    end

    @image.reload
    assert_equal "needs_review", @image.analysis_status
    assert_equal "grid_required", @image.review_reason
    assert_equal "ok", @image.quality_status
    assert_equal true, @image.is_radiometric
    assert_equal 750, @image.irradiance_w_m2
    assert_equal "poa", @image.irradiance_type
    assert_equal BigDecimal("-90.0"), @image.gimbal_pitch
    assert_not @inspection.reload.in_progress?
  end

  test "品質 ok でグリッドがあれば解析ジョブを登録する" do
    @image.update_columns(panel_grids: [ { "rows" => 2, "cols" => 3, "corners" => [ [ 0.1, 0.1 ], [ 0.5, 0.1 ], [ 0.5, 0.4 ], [ 0.1, 0.4 ] ] } ])

    assert_enqueued_with(job: AnalyzeInspectionImageJob, args: [ @image.id ]) do
      with_fake_exif(tags: dji_thermal_tags) do
        ProcessInspectionImageJob.perform_now(@image.id)
      end
    end

    assert_equal "pending", @image.reload.analysis_status
  end

  test "POA 日射量が 600 W/m² 未満なら needs_review（low_irradiance）" do
    @inspection.weather_readings.create!(observed_at: jst("2026-09-20 10:15"), irradiance_w_m2: 450, irradiance_type: "poa")

    with_fake_exif(tags: dji_thermal_tags) do
      ProcessInspectionImageJob.perform_now(@image.id)
    end

    assert_equal "low_irradiance", @image.reload.review_reason
  end

  test "メタデータを読めなければ needs_review（metadata_unreadable）で、正常にはしない" do
    with_fake_exif(error: "exiftool が見つかりません") do
      ProcessInspectionImageJob.perform_now(@image.id)
    end

    @image.reload
    assert_equal "needs_review", @image.analysis_status
    assert_equal "metadata_unreadable", @image.review_reason
    assert_nil @image.is_radiometric
  end

  test "処理中に例外が起きたら failed にして理由を保存する" do
    @image.thermal.blob.update_columns(key: "missing-key") # ストレージにファイルが無い状態

    ProcessInspectionImageJob.perform_now(@image.id)

    @image.reload
    assert_equal "failed", @image.analysis_status
    assert_match "画像の処理中にエラーが発生しました", @image.error_message
    assert_equal "failed", @inspection.reload.analysis_status
  end

  test "除外済みの画像は処理しない" do
    @image.update_columns(analysis_status: "excluded", exclusion_note: "不要")

    with_fake_exif(tags: dji_thermal_tags) do
      ProcessInspectionImageJob.perform_now(@image.id)
    end

    assert @image.reload.excluded?
    assert_nil @image.quality_report
  end

  test "存在しない ID では何もしない" do
    assert_nothing_raised { ProcessInspectionImageJob.perform_now(0) }
  end
end
