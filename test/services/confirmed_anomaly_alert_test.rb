require "test_helper"

class ConfirmedAnomalyAlertTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
  end

  def anomaly(**attrs)
    @image.anomalies.create!({ inspection: @inspection, anomaly_type: "hotspot", measure: "region_max", delta_t: 16,
                               normalized_delta_t: 20, threshold_basis: "normalized", severity: "critical",
                               panel_index_in_image: 7 }.merge(attrs))
  end

  test "確定した critical の異常にアラートを1件作る" do
    record = anomaly(review_status: "confirmed", locked: true)

    alert = ConfirmedAnomalyAlert.call(record)

    assert_equal "critical", alert.severity
    assert_equal record, alert.anomaly
    assert_match "ホットスポット", alert.title
  end

  test "同じ異常には重複して作らない" do
    record = anomaly(review_status: "confirmed")

    ConfirmedAnomalyAlert.call(record)
    assert_no_difference -> { Alert.count } do
      assert_nil ConfirmedAnomalyAlert.call(record)
    end
  end

  test "未確定の候補にはアラートを作らない（生ΔT で判定した critical でも）" do
    assert_nil ConfirmedAnomalyAlert.call(anomaly(review_status: "pending"))
    assert_nil ConfirmedAnomalyAlert.call(anomaly(review_status: "pending", threshold_basis: "raw", normalized_delta_t: nil))
  end

  test "critical 以外にはアラートを作らない（修正後の重大度で判定する）" do
    assert_nil ConfirmedAnomalyAlert.call(anomaly(review_status: "confirmed", severity: "warning"))
    assert_nil ConfirmedAnomalyAlert.call(anomaly(review_status: "corrected", severity: "critical", final_severity: "warning"))
    assert ConfirmedAnomalyAlert.call(anomaly(review_status: "corrected", severity: "warning", final_severity: "critical"))
  end

  test "群の構成パネルの異常ごとには作らず、群として1件" do
    group = @image.anomaly_groups.create!(inspection: @inspection, group_type: "panel_row_group", panel_count: 3,
                                          panel_indices: [ 1, 2, 3 ], delta_t: 6, normalized_delta_t: 7.5,
                                          threshold_basis: "normalized", severity: "critical", review_status: "confirmed")
    member = anomaly(anomaly_type: "module_wide", anomaly_group: group, review_status: "confirmed")

    assert_nil ConfirmedAnomalyAlert.call(member)
    alert = ConfirmedAnomalyAlert.call(group)
    assert_equal group, alert.anomaly_group
    assert_match "隣接パネル群（3枚）", alert.title
  end
end
