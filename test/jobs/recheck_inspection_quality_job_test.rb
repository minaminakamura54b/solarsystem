require "test_helper"

class RecheckInspectionQualityJobTest < ActiveSupport::TestCase
  setup do
    @inspection = create_session_inspection(files: %w[thermal_plain_T.jpg lowres_T.jpg])
    @first, @second = @inspection.inspection_images.to_a
    with_fake_exif(tags: dji_thermal_tags) do
      [ @first, @second ].each { |image| ProcessInspectionImageJob.perform_now(image.id) }
    end
  end

  test "気象データを追加したら、全画像に割り当て直して品質チェックをやり直す" do
    assert_equal "missing_irradiance", @first.reload.quality_report["checks"].find { |c| c["result"] == "warning" && c["key"] == "missing_irradiance" }&.dig("key")

    @inspection.weather_readings.create!(observed_at: jst("2026-09-20 10:15"), irradiance_w_m2: 450, irradiance_type: "poa")
    RecheckInspectionQualityJob.perform_now(@inspection.id)

    assert_equal "low_irradiance", @first.reload.review_reason
    assert_equal "needs_review", @inspection.reload.analysis_status
  end

  test "除外済みの画像はやり直さない" do
    @second.update_columns(analysis_status: "excluded", exclusion_note: "不要")
    @inspection.weather_readings.create!(observed_at: jst("2026-09-20 10:15"), irradiance_w_m2: 450, irradiance_type: "poa")

    RecheckInspectionQualityJob.perform_now(@inspection.id)

    assert @second.reload.excluded?
    assert_nil @second.irradiance_w_m2
  end
end
