require "test_helper"

class AnalyzeInspectionImageJobTest < ActiveSupport::TestCase
  setup do
    load_initial_rule_set
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
  end

  test "解析に成功すると異常を保存し、重大度を付け、画像を completed にする" do
    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output)) do |client|
      AnalyzeInspectionImageJob.perform_now(@image.id)

      kwargs = client.calls.sole.last
      assert_equal [ SAMPLE_GRID ], kwargs[:panel_grids]
      assert_equal 800.0, kwargs[:irradiance]
      assert_equal "poa", kwargs[:irradiance_type]
      assert_equal "2026-09-initial", kwargs[:rules]["version"]
      assert_equal({ "cell_layout" => nil, "substring_count" => 3, "bypass_pattern" => nil }, kwargs[:module_spec])
    end

    @image.reload
    assert_equal "completed", @image.analysis_status
    assert_equal "thermal_rules_v1", @image.analyzer_version
    assert_equal "2.1", @image.raw_analysis["schema_version"]
    anomaly = @image.anomalies.sole
    assert_equal [ "hotspot", "local", 7 ], [ anomaly.anomaly_type, anomaly.detection, anomaly.panel_index_in_image ]
    assert_equal "critical", anomaly.severity, "正規化ΔT 20 ≥ critical 15"
    assert_equal "pending", anomaly.review_status
    assert_equal "C", anomaly.evidence_level, "RGB が無ければ証拠レベル C"
  end

  test "すべての画像の解析が終わっても、点検は completed にせずレビュー待ち（候補0件でも）" do
    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output(anomalies: []))) do
      AnalyzeInspectionImageJob.perform_now(@image.id)
    end

    @inspection.reload
    assert_equal "needs_review", @inspection.analysis_status
    assert_equal "review_pending", @inspection.review_reason
    assert_nil @inspection.severity
  end

  test "群の構成パネル（module_wide）は群に紐付け、候補の件数は群を1件として数える" do
    anomalies = (1..3).map { |i| analyzer_anomaly(panel_index: i, anomaly_type: "module_wide", detection: "baseline", measure: "panel_mean", delta_t: 3.1, normalized_delta_t: 3.9) }
    groups = [ { "type" => "panel_row_group", "grid_index" => 0, "row" => 0, "panel_indices" => [ 1, 2, 3 ],
                 "measure" => "panel_mean", "delta_t" => 3.1, "normalized_delta_t" => 3.9, "threshold_basis" => "normalized" } ]

    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output(anomalies: anomalies, groups: groups))) do
      AnalyzeInspectionImageJob.perform_now(@image.id)
    end

    group = @image.anomaly_groups.sole
    assert_equal [ 1, 2, 3 ], group.panel_indices
    assert_equal "warning", group.severity
    assert_equal 3, group.anomalies.count
    assert_equal 1, @inspection.reload.candidate_count
  end

  test "substring_bypass の作動した帯の本数を保存する" do
    band = analyzer_anomaly(anomaly_type: "substring_bypass", detection: "baseline", active_bands: 2, measure: "region_mean", delta_t: 6, normalized_delta_t: 7.5)

    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output(anomalies: [ band ]))) do
      AnalyzeInspectionImageJob.perform_now(@image.id)
    end

    assert_equal 2, @image.anomalies.sole.active_bands
  end

  test "再解析では未確定の異常を作り直し、確定済み（locked）は残す" do
    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output)) { AnalyzeInspectionImageJob.perform_now(@image.id) }
    confirmed = @image.anomalies.sole.tap { |a| a.update!(locked: true, review_status: "confirmed") }
    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output)) { AnalyzeInspectionImageJob.perform_now(@image.id) }
    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output)) { AnalyzeInspectionImageJob.perform_now(@image.id) }

    assert_equal 2, @image.anomalies.count, "確定済み1件 + 新しい候補1件"
    assert confirmed.reload.locked?
  end

  test "グリッドが無ければ解析せず needs_review（grid_required）" do
    @image.update_columns(panel_grids: [])

    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output)) do |client|
      AnalyzeInspectionImageJob.perform_now(@image.id)
      assert_empty client.calls
    end

    assert_equal [ "needs_review", "grid_required" ], [ @image.reload.analysis_status, @image.review_reason ]
  end

  test "品質チェックに合格していなければ解析しない" do
    @image.update_columns(quality_report: { "status" => "rejected" }, analysis_status: "needs_review")

    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output)) do |client|
      AnalyzeInspectionImageJob.perform_now(@image.id)
      assert_empty client.calls
    end
  end

  test "温度データなし（終了コード 2）は needs_review で理由と出力を保存する" do
    output = analyzer_output(status: "needs_review", review_reason: "sdk_unavailable", anomalies: [], message: "SDK が見つかりません")

    with_fake_analyzer(analyze: analyzer_result(exit_code: 2, output: output)) { AnalyzeInspectionImageJob.perform_now(@image.id) }

    @image.reload
    assert_equal [ "needs_review", "sdk_unavailable" ], [ @image.analysis_status, @image.review_reason ]
    assert_equal "SDK が見つかりません", @image.error_message
    assert_empty @image.anomalies
  end

  test "基準パネル不足（終了コード 4）は needs_review（insufficient_baseline）" do
    output = analyzer_output(status: "needs_review", review_reason: "insufficient_baseline", anomalies: [])

    with_fake_analyzer(analyze: analyzer_result(exit_code: 4, output: output)) { AnalyzeInspectionImageJob.perform_now(@image.id) }

    assert_equal "insufficient_baseline", @image.reload.review_reason
  end

  test "時間切れは failed（timeout）で、パネル・アラートを変えない" do
    with_fake_analyzer(analyze: analyzer_result(exit_code: nil, error: "timeout")) do
      assert_no_difference -> { Alert.count } do
        AnalyzeInspectionImageJob.perform_now(@image.id)
      end
    end

    @image.reload
    assert_equal [ "failed", "timeout" ], [ @image.analysis_status, @image.review_reason ]
    assert_equal "解析エンジンが時間内に終わりませんでした", @image.error_message
    assert @inspection.site.panels.all? { |p| p.last_inspected_at.nil? && p.status == "normal" }
    assert_equal "failed", @inspection.reload.analysis_status
  end

  test "出力が約束どおりでなければ failed（invalid_output）" do
    with_fake_analyzer(analyze: analyzer_result(exit_code: 0, error: "invalid_output")) { AnalyzeInspectionImageJob.perform_now(@image.id) }

    assert_equal [ "failed", "invalid_output" ], [ @image.reload.analysis_status, @image.review_reason ]
  end

  test "有効なルールセットが無ければ failed（no_rule_set）" do
    RuleSet.update_all(active: false)

    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output)) { AnalyzeInspectionImageJob.perform_now(@image.id) }

    assert_equal [ "failed", "no_rule_set" ], [ @image.reload.analysis_status, @image.review_reason ]
  end

  test "異常の保存中にエラーが起きたら、何も残さず failed" do
    broken = analyzer_anomaly(anomaly_type: "unknown_type")

    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output(anomalies: [ analyzer_anomaly, broken ]))) do
      AnalyzeInspectionImageJob.perform_now(@image.id)
    end

    assert_equal "failed", @image.reload.analysis_status
    assert_empty @image.anomalies
  end
end
