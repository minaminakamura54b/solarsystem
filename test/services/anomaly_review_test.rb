require "test_helper"

class AnomalyReviewTest < ActiveSupport::TestCase
  setup do
    @rule_set = load_initial_rule_set
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
    @image.update_columns(analysis_status: "completed")
  end

  def candidate(**attrs)
    @image.anomalies.create!({ inspection: @inspection, anomaly_type: "hotspot", detection: "local", measure: "region_max",
                               delta_t: 6, normalized_delta_t: 6, threshold_basis: "normalized", severity: "warning",
                               bbox: { "x1" => 0.3, "y1" => 0.4, "x2" => 0.32, "y2" => 0.43 }, panel_index_in_image: 7,
                               evidence_level: "C", rule_set: @rule_set, rule_version: @rule_set.version }.merge(attrs))
  end

  test "確定すると locked になり、元の判定値は残る" do
    record = candidate

    AnomalyReview.new(record).confirm!(causes: %w[cell_crack bogus], note: "セルの割れを目視で確認")

    record.reload
    assert_equal [ "confirmed", true ], [ record.review_status, record.locked ]
    assert_equal %w[cell_crack], record.selected_causes, "定義済みの原因候補だけ保存する"
    assert_equal [ "hotspot", "warning" ], [ record.anomaly_type, record.severity ]
    assert record.reviewed_at.present?
  end

  test "RGB を確認して確定したときだけ証拠レベル B（RGB が添付されていない・確認していないなら C のまま）" do
    no_check = candidate
    AnomalyReview.new(no_check).confirm!(rgb_checked: false)
    assert_equal "C", no_check.reload.evidence_level

    no_rgb = candidate
    AnomalyReview.new(no_rgb).confirm!(rgb_checked: true)
    assert_equal "C", no_rgb.reload.evidence_level, "RGB が添付されていなければ確認できない"

    @image.rgb.attach(io: file_fixture("rgb_V.jpg").open, filename: "rgb_V.jpg")
    checked = candidate
    AnomalyReview.new(checked.reload).confirm!(rgb_checked: true)
    assert_equal "B", checked.reload.evidence_level
  end

  test "指標が違う種類（region_max → region_mean）に修正するときは、人が選んだ重大度を使い、選ばなければエラー" do
    record = candidate(normalized_delta_t: 20.0, severity: "critical") # hotspot は region_max

    assert_raises(AnomalyReview::Error) { AnomalyReview.new(record).correct!(final_anomaly_type: "partial_module") }
    assert_equal "pending", record.reload.review_status

    AnomalyReview.new(record).correct!(final_anomaly_type: "partial_module", final_severity: "warning")
    assert_equal [ "corrected", "warning" ], [ record.reload.review_status, record.final_severity ]
  end

  test "指標が同じ種類に修正するときは、人が選んだ重大度ではなく判定基準で付け直す" do
    record = candidate(normalized_delta_t: 4.0, severity: "mild")

    AnomalyReview.new(record).correct!(final_anomaly_type: "multi_hotspot", final_severity: "critical")

    assert_equal "warning", record.reload.final_severity, "multi_hotspot（1/2.5/7.5）の閾値で付け直す"
  end

  test "手動追加（数値なし）の異常の種類を修正するときは、人が重大度を選ぶ" do
    manual = AnomalyReview.add_manual!(@image, anomaly_type: "hotspot", severity: "mild", bbox: { "x1" => 0.5, "y1" => 0.5, "x2" => 0.52, "y2" => 0.53 })

    AnomalyReview.new(manual).correct!(final_anomaly_type: "module_wide", final_severity: "critical")

    assert_equal "critical", manual.reload.final_severity
  end

  test "種類・位置を修正すると final_* に保存し、重大度は判定時のルールセットで修正後の種類の閾値で付け直す" do
    record = candidate(normalized_delta_t: 4.0, severity: "mild") # hotspot（2/5/15）では mild

    AnomalyReview.new(record).correct!(final_anomaly_type: "multi_hotspot", final_bbox: { "x1" => 0.31, "y1" => 0.41, "x2" => 0.29, "y2" => 0.44 })

    record.reload
    assert_equal "corrected", record.review_status
    assert_equal "multi_hotspot", record.final_anomaly_type
    assert_equal "warning", record.final_severity, "multi_hotspot（1/2.5/7.5）では warning"
    assert_equal({ "x1" => 0.29, "y1" => 0.41, "x2" => 0.31, "y2" => 0.44 }, record.final_bbox)
    assert_equal [ "hotspot", "mild" ], [ record.anomaly_type, record.severity ], "元の判定値は残す"
  end

  test "却下には理由が必要で、却下した異常は locked" do
    record = candidate

    assert_raises(AnomalyReview::Error) { AnomalyReview.new(record).reject!(reason: "") }
    AnomalyReview.new(record).reject!(reason: "glare")

    assert_equal [ "rejected", "glare", true ], [ record.reload.review_status, record.rejection_reason, record.locked ]
  end

  test "確定・修正した critical の異常にはアラートを作り、却下では作らない" do
    assert_difference -> { Alert.count }, 1 do
      AnomalyReview.new(candidate(severity: "critical")).confirm!
    end
    assert_no_difference -> { Alert.count } do
      AnomalyReview.new(candidate(severity: "critical")).reject!(reason: "glare")
    end
  end

  test "群は群単位で確定・却下し、構成パネルにも反映する。群から外したパネルは単独になる" do
    group = @image.anomaly_groups.create!(inspection: @inspection, group_type: "panel_row_group", panel_count: 3,
                                          panel_indices: [ 1, 2, 3 ], severity: "warning", threshold_basis: "normalized")
    members = (1..3).map { |i| candidate(anomaly_type: "module_wide", panel_index_in_image: i, anomaly_group: group) }

    AnomalyReview.new(members.last).remove_from_group!
    assert_equal [ 1, 2 ], group.reload.panel_indices
    assert_nil members.last.reload.anomaly_group_id

    AnomalyReview.new(group).confirm!
    assert_equal %w[confirmed confirmed], group.anomalies.map(&:review_status)
    assert group.reload.locked?
    assert_equal "pending", members.last.reload.review_status, "外したパネルは群の確定に含まれない"
  end

  test "電気測定を入力すると証拠レベル A" do
    record = candidate

    AnomalyReview.new(record).record_electrical!(method: "iv_curve", result: "Isc 低下", measured_on: "2026-10-01")

    assert_equal "A", record.reload.evidence_level
    assert_equal "iv_curve", record.electrical_evidence["method"]
  end

  test "パネルの割り当ては同じ発電所のパネルだけ。ロックしない" do
    record = candidate

    AnomalyReview.new(record).assign_panel!(panels(:p002))
    assert_equal panels(:p002), record.reload.panel
    assert_not record.locked?

    other = Panel.create!(site: sites(:east), number: "E1", position_x: 0, position_y: 0)
    assert_raises(AnomalyReview::Error) { AnomalyReview.new(record).assign_panel!(other) }
  end

  test "完了済みの点検でパネルを割り当て直しても、レビュー待ちに戻さず、変更前・変更後のパネル番号と日時を履歴に残す" do
    record = candidate(review_status: "confirmed", locked: true, panel: panels(:p001))
    @inspection.refresh_status!
    assert InspectionReview.new(@inspection).complete!(all_images_checked: true).completed?
    before = @inspection.reload.attributes.slice("analysis_status", "severity", "reviewed_at")

    travel_to Time.zone.parse("2026-10-19 10:00:00") do
      AnomalyReview.new(record).assign_panel!(panels(:p002))
    end
    AnomalyReview.new(record.reload).assign_panel!(nil)

    assert_equal before, @inspection.reload.attributes.slice("analysis_status", "severity", "reviewed_at")
    history = record.reload.panel_assignment_history
    assert_equal({ "reason" => "assigned", "from_panel_number" => "P001", "to_panel_number" => "P002",
                   "changed_at" => Time.zone.parse("2026-10-19 10:00:00").iso8601 }, history.first)
    assert_equal [ "P002", nil ], history.last.values_at("from_panel_number", "to_panel_number")
    assert_nil record.panel
    assert_equal [ "confirmed", "warning", true ], [ record.review_status, record.severity, record.locked ]
  end

  test "同じパネルを割り当てても履歴を増やさない" do
    record = candidate(panel: panels(:p001))

    AnomalyReview.new(record).assign_panel!(panels(:p001))

    assert_empty record.reload.panel_assignment_history
  end

  test "見逃しを手動で追加すると、人が判断した異常（確定・locked・detection manual）になる" do
    anomaly = AnomalyReview.add_manual!(@image, anomaly_type: "hotspot", severity: "critical",
                                        bbox: { "x1" => 0.5, "y1" => 0.5, "x2" => 0.52, "y2" => 0.53 }, panel_index: "12")

    assert_equal [ "manual", "confirmed", true, 12 ], [ anomaly.detection, anomaly.review_status, anomaly.locked, anomaly.panel_index_in_image ]
    assert Alert.exists?(anomaly: anomaly), "critical なのでアラートを作る"
    assert_raises(AnomalyReview::Error) { AnomalyReview.add_manual!(@image, anomaly_type: "hotspot", severity: "mild", bbox: nil) }
  end

  test "完了済みの点検でレビュー操作をすると、レビュー待ちに戻す" do
    record = candidate
    @inspection.update_columns(analysis_status: "completed", severity: "warning", reviewed_at: Time.current)

    AnomalyReview.new(record).reject!(reason: "other")

    @inspection.reload
    assert_equal [ "needs_review", "review_pending", nil, nil ], [ @inspection.analysis_status, @inspection.review_reason, @inspection.severity, @inspection.reviewed_at ]
  end
end
