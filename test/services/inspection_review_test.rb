require "test_helper"

class InspectionReviewTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection(files: %w[thermal_plain_T.jpg lowres_T.jpg])
    @first, @second = @inspection.inspection_images.to_a
    @first.update_columns(analysis_status: "completed")
    @second.update_columns(analysis_status: "completed")
    @inspection.refresh_status!
  end

  def anomaly(image = @first, **attrs)
    image.anomalies.create!({ inspection: @inspection, anomaly_type: "hotspot", severity: "warning", review_status: "pending" }.merge(attrs))
  end

  def review = InspectionReview.new(@inspection)

  test "候補0件でも、すべての画像を確認したことを確認しないと完了しない。確認すれば normal で完了" do
    result = review.complete!(all_images_checked: false)
    assert_not result.completed?
    assert_includes result.errors, "「すべての画像を確認し、見逃しがない」ことを確認してください"
    assert_equal "needs_review", @inspection.reload.analysis_status

    assert review.complete!(all_images_checked: true).completed?
    @inspection.reload
    assert_equal [ "completed", "normal" ], [ @inspection.analysis_status, @inspection.severity ]
    assert @inspection.reviewed_at.present?
  end

  test "重要度は確定・修正した異常の最大重大度（修正後の値を使い、却下・未確定は含めない）" do
    anomaly(review_status: "confirmed", severity: "mild")
    anomaly(review_status: "corrected", severity: "mild", final_severity: "warning")
    anomaly(review_status: "rejected", severity: "critical")

    review.complete!(all_images_checked: true)

    assert_equal "warning", @inspection.reload.severity
  end

  test "確定済みが mild だけなら点検の重要度も mild（軽微）" do
    anomaly(review_status: "confirmed", severity: "mild")

    review.complete!(all_images_checked: true)

    assert_equal "mild", @inspection.reload.severity
    assert_equal "軽微", @inspection.severity_label
  end

  test "群は群の重大度で数え、構成パネルの異常は数えない" do
    group = @first.anomaly_groups.create!(inspection: @inspection, group_type: "panel_row_group", panel_count: 3,
                                          panel_indices: [ 1, 2, 3 ], severity: "critical", review_status: "confirmed")
    anomaly(anomaly_group: group, review_status: "confirmed", severity: "mild")

    review.complete!(all_images_checked: true)

    assert_equal "critical", @inspection.reload.severity
  end

  test "未確定の候補が残っていれば警告し、確認したときだけ完了する（残った候補は重要度に入れない）" do
    anomaly(review_status: "pending", severity: "critical")
    anomaly(review_status: "confirmed", severity: "mild")

    result = review.complete!(all_images_checked: true)
    assert_not result.completed?
    assert_match "未確定の候補が 1 件残っています", result.warnings.sole

    result = review.complete!(all_images_checked: true, acknowledge_pending: true)
    assert result.completed?
    assert_equal "mild", @inspection.reload.severity
  end

  test "要確認・失敗・解析中の画像が残っていれば完了できない（除外すれば完了できる）" do
    @second.update_columns(analysis_status: "needs_review", review_reason: "grid_required")

    result = review.complete!(all_images_checked: true)
    assert_not result.completed?
    assert_match "要確認の画像が 1 枚あります（画像 2", result.errors.first

    @second.update_columns(analysis_status: "excluded", exclusion_note: "パネルが写っていない")
    assert review.complete!(all_images_checked: true).completed?
  end

  test "完了後に再解析などで画像のステータスが変わると、レビュー待ちに戻り重要度を消す" do
    review.complete!(all_images_checked: true)
    @inspection.refresh_status!
    assert @inspection.reload.completed?, "画像が変わらなければ completed のまま"

    @first.update_columns(analysis_status: "analyzing")
    @inspection.refresh_status!

    @inspection.reload
    assert_equal [ "analyzing", nil, nil ], [ @inspection.analysis_status, @inspection.severity, @inspection.reviewed_at ]
  end
end
