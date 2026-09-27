require "test_helper"

# 新方式の点検（複数画像）のステータス集計（docs/IMPROVEMENT_PLAN.md セクション2）
class InspectionSessionStatusTest < ActiveSupport::TestCase
  setup do
    @inspection = create_session_inspection(files: %w[thermal_plain_T.jpg lowres_T.jpg])
    @first, @second = @inspection.inspection_images.to_a
  end

  def set_statuses(first, second)
    @first.update_columns(analysis_status: first, quality_report: { "status" => "ok" })
    @second.update_columns(analysis_status: second, quality_report: { "status" => "ok" })
    @inspection.inspection_images.reset
  end

  test "作成直後は品質チェック待ちで analyzing、自動更新の対象" do
    assert_equal "analyzing", @inspection.aggregated_status
    assert @inspection.in_progress?
  end

  test "品質チェック済みで解析エンジン待ちの画像だけなら、自動更新の対象にしない" do
    set_statuses("pending", "pending")

    assert_not @inspection.in_progress?
    assert_equal 2, @inspection.images_waiting_for_analyzer
  end

  test "failed が needs_review より優先される" do
    set_statuses("failed", "needs_review")

    assert_equal "failed", @inspection.aggregated_status
  end

  test "needs_review があれば needs_review" do
    set_statuses("completed", "needs_review")

    assert_equal "needs_review", @inspection.aggregated_status
  end

  test "excluded の画像は集計から外す" do
    set_statuses("needs_review", "excluded")
    assert_equal "needs_review", @inspection.aggregated_status

    set_statuses("completed", "excluded")
    assert_equal "completed", @inspection.aggregated_status
  end

  test "すべて除外したら needs_review（人の判断が必要）" do
    set_statuses("excluded", "excluded")

    assert_equal "needs_review", @inspection.aggregated_status
  end

  test "refresh_status! は集計結果を保存する" do
    set_statuses("needs_review", "pending")
    set_statuses("needs_review", "needs_review")

    @inspection.refresh_status!

    assert_equal "needs_review", @inspection.reload.analysis_status
  end

  test "refresh_status! は completed にしない（severity の判定は Phase 4）" do
    set_statuses("completed", "completed")

    @inspection.refresh_status!

    assert_not_equal "completed", @inspection.reload.analysis_status
    assert_nil @inspection.severity
  end

  test "新方式の点検は旧方式（legacy）ではない" do
    assert_not @inspection.legacy?
    assert inspections(:completed_warning).legacy?
  end
end
