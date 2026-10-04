require "test_helper"

class SeverityRuleEngineTest < ActiveSupport::TestCase
  setup do
    @rule_set = load_initial_rule_set
    @engine = SeverityRuleEngine.new(@rule_set)
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
  end

  def anomaly(**attrs)
    @image.anomalies.build({ inspection: @inspection, anomaly_type: "hotspot", measure: "region_max",
                             delta_t: 6.0, normalized_delta_t: 6.0, threshold_basis: "normalized" }.merge(attrs))
  end

  test "閾値で mild / warning / critical を付ける（hotspot: 2 / 5 / 15）" do
    assert_equal "mild", @engine.apply(anomaly(normalized_delta_t: 3)).severity
    assert_equal "warning", @engine.apply(anomaly(normalized_delta_t: 5)).severity
    assert_equal "critical", @engine.apply(anomaly(normalized_delta_t: 15)).severity
  end

  test "threshold_basis が raw なら生ΔT と生ΔT 用の閾値で判定する" do
    record = @engine.apply(anomaly(threshold_basis: "raw", delta_t: 16, normalized_delta_t: nil))

    assert_equal "critical", record.severity
  end

  test "判定に使ったルールセットと閾値のコピーを保存する" do
    record = @engine.apply(anomaly)

    assert_equal @rule_set, record.rule_set
    assert_equal "2026-09-initial", record.rule_version
    assert_equal 15.0, record.rule_snapshot["normalized_critical"]
    assert_equal "hotspot", record.rule_snapshot["anomaly_type"]
  end

  test "異常群は group_type の閾値で判定する（panel_row_group: 1.5 / 2 / 5）" do
    group = @image.anomaly_groups.build(inspection: @inspection, group_type: "panel_row_group", panel_count: 3,
                                        delta_t: 3.0, normalized_delta_t: 3.0, threshold_basis: "normalized")

    assert_equal "warning", @engine.apply(group).severity
  end

  test "locked の異常は変えない" do
    record = anomaly(normalized_delta_t: 20, locked: true, severity: "mild")

    assert_equal "mild", @engine.apply(record).severity
    assert_nil record.rule_set
  end

  test "再判定は未確定の異常だけを、新しいルールセットで判定し直す" do
    pending_record = @engine.apply(anomaly(normalized_delta_t: 6)).tap(&:save!)
    locked_record = @engine.apply(anomaly(normalized_delta_t: 6)).tap { |a| a.update!(locked: true, review_status: "confirmed") }
    stricter = @rule_set.duplicate(version: "stricter")
    stricter.rule_for("hotspot").assign_attributes(normalized_mild: 1, normalized_warning: 3, normalized_critical: 5.5)
    stricter.save!

    count = SeverityRuleEngine.new(stricter).rejudge!(@inspection)

    assert_equal 1, count
    assert_equal [ "critical", "stricter" ], [ pending_record.reload.severity, pending_record.rule_version ]
    assert_equal [ "warning", "2026-09-initial" ], [ locked_record.reload.severity, locked_record.rule_version ], "確定済みは変わらない"
  end

  test "mild を上げて判定し直すと mild 未満は重大度なし（nil）" do
    record = anomaly(normalized_delta_t: 2.5)
    stricter = @rule_set.duplicate(version: "higher-mild")
    stricter.rule_for("hotspot").assign_attributes(normalized_mild: 3)
    stricter.save!

    assert_nil SeverityRuleEngine.new(stricter).apply(record).severity
  end
end
