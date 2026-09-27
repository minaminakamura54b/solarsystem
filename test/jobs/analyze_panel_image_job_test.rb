require "test_helper"

# 現行の AnalyzePanelImageJob の挙動を記録するテスト。
# 「Phase 1 で変更」と書いたテストは、危険な現状の挙動をそのまま記録したもので、
# Phase 1 で期待値を反転させる（docs/IMPROVEMENT_PLAN.md の Phase 1 を参照）。
# ジョブ内部の ClaudePanelAnalyzer.new には with_fake_claude で偽クライアントを差し込む。
class AnalyzePanelImageJobTest < ActiveSupport::TestCase
  setup do
    @inspection = attach_panel_image(inspections(:pending))
    @site = @inspection.site
  end

  test "解析に成功すると completed になり、結果とレポートを保存する" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "critical"))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    @inspection.reload
    assert_equal "completed", @inspection.analysis_status
    assert_equal "critical", @inspection.severity
    assert_equal 1, @inspection.anomaly_count
    assert_equal "テスト用の概要", @inspection.result
    assert_includes @inspection.report, "### 推奨アクション"
  end

  test "異常があれば重大度に応じたアラートを1件作成する" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "critical"))) do
      assert_difference -> { @inspection.alerts.count }, 1 do
        AnalyzePanelImageJob.perform_now(@inspection.id)
      end
    end

    assert_equal "critical", @inspection.alerts.last.severity
  end

  test "異常がなければアラートを作成しない" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "normal", anomalies: []))) do
      assert_no_difference -> { Alert.count } do
        AnalyzePanelImageJob.perform_now(@inspection.id)
      end
    end
  end

  test "存在しない ID では何もしない" do
    assert_nothing_raised { AnalyzePanelImageJob.perform_now(0) }
  end

  test "現状: 異常の k 番目を並び順 k 番目のパネルに割り当てて status を変える（Phase 1 で削除）" do
    anomalies = [
      { "type" => "A", "location" => "?", "description" => "", "severity" => "critical" },
      { "type" => "B", "location" => "?", "description" => "", "severity" => "warning" }
    ]
    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "critical", anomalies: anomalies))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    assert_equal "error", panels(:p001).reload.status, "1件目の異常 → 並び順1番目のパネル"
    assert_equal "warning", panels(:p002).reload.status, "2件目の異常 → 並び順2番目のパネル"
    assert_equal "normal", panels(:p003).reload.status
  end

  test "現状: 同じ点検を再解析するとアラートが重複して作成される（Phase 1 で重複を防止）" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json)) do
      assert_difference -> { @inspection.alerts.count }, 2 do
        AnalyzePanelImageJob.perform_now(@inspection.id)
        AnalyzePanelImageJob.perform_now(@inspection.id)
      end
    end
  end

  test "現状: 壊れた JSON でも completed・normal・異常0件として保存される（Phase 1 で failed に変更）" do
    with_fake_claude(FakeAnthropicClient.replying('{"severity": "critical", "anomalies": [ }')) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    @inspection.reload
    assert_equal "completed", @inspection.analysis_status
    assert_equal "normal", @inspection.severity
    assert_equal 0, @inspection.anomaly_count
  end

  test "現状: API エラーは failed だが severity は normal のまま保存される（Phase 1 で nil に変更）" do
    with_fake_claude(FakeAnthropicClient.raising(Anthropic::Error.new("overloaded"))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    @inspection.reload
    assert_equal "failed", @inspection.analysis_status
    assert_equal "normal", @inspection.severity
    assert_equal "Claude API エラー: overloaded", @inspection.result
  end

  test "現状: 解析に失敗しても全パネルの last_inspected_at を更新する（Phase 1 で成功時のみに変更）" do
    assert @site.panels.all? { |p| p.last_inspected_at.nil? }

    with_fake_claude(FakeAnthropicClient.raising(Anthropic::Error.new("overloaded"))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    assert @site.panels.reload.all? { |p| p.last_inspected_at.present? }
  end

  test "現状: 画像なしでも failed・severity normal で、last_inspected_at は更新される（Phase 1 で変更）" do
    inspection = inspections(:analyzing)

    with_fake_claude(FakeAnthropicClient.replying(claude_json)) do |client|
      AnalyzePanelImageJob.perform_now(inspection.id)
      assert_empty client.requests
    end

    inspection.reload
    assert_equal "failed", inspection.analysis_status
    assert_equal "normal", inspection.severity
    assert inspection.site.panels.reload.all? { |p| p.last_inspected_at.present? }
  end
end
