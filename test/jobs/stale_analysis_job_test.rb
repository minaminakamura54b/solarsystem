require "test_helper"

class StaleAnalysisJobTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection(files: %w[thermal_plain_T.jpg lowres_T.jpg])
    @old, @recent = @inspection.inspection_images.to_a
  end

  test "設定の時間を超えて analyzing のままの画像を failed（stale_analysis）にする" do
    @old.update_columns(analysis_status: "analyzing", updated_at: 11.minutes.ago)
    @recent.update_columns(analysis_status: "analyzing", updated_at: 1.minute.ago)

    StaleAnalysisJob.perform_now

    assert_equal [ "failed", "stale_analysis" ], [ @old.reload.analysis_status, @old.review_reason ]
    assert @recent.reload.analyzing?, "時間内のものはそのまま"
    assert_equal "analyzing", @inspection.reload.analysis_status, "解析中の画像が残っている"
  end

  test "品質チェック待ちのまま残った画像も failed（stale_quality_check）にする" do
    @old.update_columns(analysis_status: "pending", quality_report: nil, updated_at: 30.minutes.ago)
    @recent.update_columns(analysis_status: "needs_review", review_reason: "grid_required")

    StaleAnalysisJob.perform_now

    assert_equal "stale_quality_check", @old.reload.review_reason
    assert_equal "failed", @inspection.reload.analysis_status
  end

  test "パネル・アラートは変えない" do
    @old.update_columns(analysis_status: "analyzing", updated_at: 1.hour.ago)

    assert_no_difference -> { Alert.count } do
      StaleAnalysisJob.perform_now
    end
    assert @inspection.site.panels.all? { |p| p.status == "normal" && p.last_inspected_at.nil? }
  end

  test "旧方式で analyzing のまま残った点検も failed にする" do
    legacy = inspections(:analyzing)
    legacy.update_columns(updated_at: 1.hour.ago)

    StaleAnalysisJob.perform_now

    assert_equal "failed", legacy.reload.analysis_status
    assert_nil legacy.severity
  end
end
