require "test_helper"

# レビュー画面と、確定・修正・却下・手動追加・レビュー完了の操作（docs/IMPROVEMENT_PLAN.md Phase 5）
class AnomalyReviewFlowTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
    @rule_set = load_initial_rule_set
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output)) { AnalyzeInspectionImageJob.perform_now(@image.id) }
    @anomaly = @image.anomalies.sole
  end

  def review_path(image = @image) = review_inspection_path(@inspection, image: image.sequence, site_id: @site.id)

  test "レビュー画面に候補・数値・判定に使った値・分類の根拠を表示する" do
    get review_path

    assert_response :success
    assert_select "[data-controller='review']"
    assert_select "#anomaly_#{@anomaly.id}"
    assert_match "判定: 正規化ΔT 20.0℃", response.body
    assert_match "ホットスポット", response.body
    assert_select "input[type=submit][value='確定（c）']"
    assert_select "input[type=submit][value='レビューを完了する']"
  end

  test "確定すると locked になり、レビュー画面に戻る" do
    patch confirm_inspection_anomaly_path(@inspection, @anomaly, site_id: @site.id), params: { causes: %w[cell_crack], note: "確認" }

    assert_redirected_to review_inspection_path(@inspection, image: 1, anchor: "anomaly_#{@anomaly.id}")
    assert_equal [ "confirmed", true, %w[cell_crack] ], [ @anomaly.reload.review_status, @anomaly.locked, @anomaly.selected_causes ]
  end

  test "critical の候補を確定するとアラートを1件作る" do
    assert_difference -> { Alert.count }, 1 do
      patch confirm_inspection_anomaly_path(@inspection, @anomaly, site_id: @site.id)
    end
  end

  test "種類と位置を修正して確定する" do
    patch correct_inspection_anomaly_path(@inspection, @anomaly, site_id: @site.id),
          params: { final_anomaly_type: "partial_module", final_severity: "warning", final_bbox: { x1: 0.2, y1: 0.3, x2: 0.4, y2: 0.5 }.to_json }

    @anomaly.reload
    assert_equal [ "corrected", "partial_module" ], [ @anomaly.review_status, @anomaly.final_anomaly_type ]
    assert_equal 0.2, @anomaly.final_bbox["x1"]
    assert_equal "hotspot", @anomaly.anomaly_type, "元の判定は残す"
  end

  test "却下は理由が無ければしない" do
    patch reject_inspection_anomaly_path(@inspection, @anomaly, site_id: @site.id), params: { rejection_reason: "" }
    assert_equal "pending", @anomaly.reload.review_status
    assert_equal "却下の理由を選んでください", flash[:alert]

    patch reject_inspection_anomaly_path(@inspection, @anomaly, site_id: @site.id), params: { rejection_reason: "shadow" }
    assert_equal [ "rejected", "shadow" ], [ @anomaly.reload.review_status, @anomaly.rejection_reason ]
  end

  test "パネルの割り当てと電気測定の入力" do
    patch assign_panel_inspection_anomaly_path(@inspection, @anomaly, site_id: @site.id), params: { panel_id: panels(:p003).id }
    patch electrical_inspection_anomaly_path(@inspection, @anomaly, site_id: @site.id), params: { method: "string_current", result: "他の約 60%" }

    @anomaly.reload
    assert_equal panels(:p003), @anomaly.panel
    assert_equal "A", @anomaly.evidence_level
  end

  test "見逃しを手動で追加する" do
    assert_difference -> { @image.anomalies.count }, 1 do
      post inspection_anomalies_path(@inspection, site_id: @site.id), params: {
        image_id: @image.id, anomaly_type: "multi_hotspot", severity: "warning", panel_index: 3,
        bbox: { x1: 0.6, y1: 0.6, x2: 0.62, y2: 0.63 }.to_json
      }
    end
    manual = @image.anomalies.find_by(detection: "manual")
    assert_equal [ "multi_hotspot", "warning", "confirmed" ], [ manual.anomaly_type, manual.severity, manual.review_status ]
  end

  test "範囲を指定しないと見逃しを追加しない" do
    assert_no_difference -> { Anomaly.count } do
      post inspection_anomalies_path(@inspection, site_id: @site.id), params: { image_id: @image.id, anomaly_type: "hotspot", severity: "mild", bbox: "" }
    end
    assert_match "範囲", flash[:alert]
  end

  test "群を確定すると構成パネルにも反映し、群から外す操作もできる" do
    group = @image.anomaly_groups.create!(inspection: @inspection, group_type: "panel_row_group", panel_count: 2,
                                          panel_indices: [ 1, 2 ], severity: "warning", threshold_basis: "normalized")
    members = [ 1, 2 ].map { |i| @image.anomalies.create!(inspection: @inspection, anomaly_type: "module_wide", panel_index_in_image: i, anomaly_group: group) }

    patch remove_from_group_inspection_anomaly_path(@inspection, members.last, site_id: @site.id)
    patch confirm_inspection_anomaly_group_path(@inspection, group, site_id: @site.id)

    assert_equal "confirmed", members.first.reload.review_status
    assert_equal "pending", members.last.reload.review_status
  end

  test "未確定の候補が残っていると、確認しない限りレビューを完了しない" do
    post complete_review_inspection_path(@inspection, site_id: @site.id), params: { all_images_checked: "1" }

    assert_redirected_to review_inspection_path(@inspection, anchor: "complete")
    assert_match "未確定の候補が 1 件残っています", flash[:alert]
    assert_equal "needs_review", @inspection.reload.analysis_status

    post complete_review_inspection_path(@inspection, site_id: @site.id), params: { all_images_checked: "1", acknowledge_pending: "1" }
    assert_redirected_to inspection_path(@inspection)
    assert_equal [ "completed", "normal" ], [ @inspection.reload.analysis_status, @inspection.severity ]
  end

  test "候補を確定してからレビューを完了すると、重要度が付き一覧に表示される" do
    patch confirm_inspection_anomaly_path(@inspection, @anomaly, site_id: @site.id)
    post complete_review_inspection_path(@inspection, site_id: @site.id), params: { all_images_checked: "1" }

    assert_match "レビューを完了しました（重要度: 重大）", flash[:notice]
    get inspections_path(site_id: @site.id)
    assert_select "tr#inspection_#{@inspection.id} .badge", text: "重大"
    assert_select "tr#inspection_#{@inspection.id} td", text: "1"
  end

  test "すべての画像を確認したことを確認しないとレビューを完了しない（候補0件でも）" do
    patch reject_inspection_anomaly_path(@inspection, @anomaly, site_id: @site.id), params: { rejection_reason: "glare" }

    post complete_review_inspection_path(@inspection, site_id: @site.id)

    assert_match "すべての画像を確認し", flash[:alert]
    assert_not @inspection.reload.completed?
  end
end
