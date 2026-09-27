require "test_helper"

# AnalyzePanelImageJob のテスト。
# ジョブ内部の ClaudePanelAnalyzer.new には with_fake_claude で偽クライアントを差し込む。
class AnalyzePanelImageJobTest < ActiveSupport::TestCase
  # テストでだけ、アラート作成の途中で例外を起こすジョブ（本番コードには仕掛けを入れない）
  class JobFailingOnAlert < AnalyzePanelImageJob
    private

    def upsert_alert(*)
      raise "アラート作成で障害"
    end
  end

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
    assert_nil @inspection.error_message
    assert_includes @inspection.report, "### 推奨アクション"
  end

  test "解析に成功すると全パネルの last_inspected_at を点検日時で更新する" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json)) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    assert @site.panels.reload.all? { |p| p.last_inspected_at == @inspection.conducted_at }
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

  test "異常があってもパネルの status は変えない（並び順による割り当てはしない）" do
    anomalies = [
      { "type" => "A", "location" => "?", "description" => "", "severity" => "critical" },
      { "type" => "B", "location" => "?", "description" => "", "severity" => "warning" }
    ]
    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "critical", anomalies: anomalies))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    assert_equal %w[normal normal normal], @site.panels.by_position.map(&:status)
  end

  # ── アラートの重複防止（1つの点検につき1件） ──────────────────────

  test "同じ点検を再解析してもアラートは1件のまま" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json)) do
      assert_difference -> { @inspection.alerts.count }, 1 do
        AnalyzePanelImageJob.perform_now(@inspection.id)
        AnalyzePanelImageJob.perform_now(@inspection.id)
      end
    end
  end

  test "再解析で重大度が上がったら、既存のアラートを更新して未読に戻す" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "warning"))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end
    alert = @inspection.alerts.sole
    alert.mark_as_read!

    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "critical"))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    alert.reload
    assert_equal alert, @inspection.alerts.sole
    assert_equal "critical", alert.severity
    assert_not alert.read?
  end

  test "再解析で重大度が変わらなければ、既読のままにする" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "warning"))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
      @inspection.alerts.sole.mark_as_read!
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    assert @inspection.alerts.sole.read?
  end

  test "再解析が失敗しても、既存のアラートは変更も削除もしない" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "critical"))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end
    alert = @inspection.alerts.sole
    alert.mark_as_read!
    before = alert.reload.attributes

    with_fake_claude(FakeAnthropicClient.raising(Anthropic::Error.new("overloaded"))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    assert_equal before, @inspection.alerts.sole.attributes
  end

  test "再解析で異常が0件になっても、既存のアラートは削除しない" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "warning"))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end
    before = @inspection.alerts.sole.attributes

    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "normal", anomalies: []))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    assert_equal before, @inspection.alerts.sole.attributes
  end

  # ── 失敗時の扱い ──────────────────────────────────────────

  test "壊れた JSON は failed になり、severity は nil で理由を error_message に保存する" do
    with_fake_claude(FakeAnthropicClient.replying('{"severity": "critical", "anomalies": [ }')) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    @inspection.reload
    assert_equal "failed", @inspection.analysis_status
    assert_nil @inspection.severity
    assert_equal "応答の JSON を解析できませんでした", @inspection.error_message
  end

  test "API エラーは failed になり、severity は nil で理由を error_message に保存する" do
    with_fake_claude(FakeAnthropicClient.raising(Anthropic::Error.new("overloaded"))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    @inspection.reload
    assert_equal "failed", @inspection.analysis_status
    assert_nil @inspection.severity
    assert_equal "Claude API エラー: overloaded", @inspection.error_message
  end

  test "解析に失敗したらパネル・アラートを一切変更しない" do
    with_fake_claude(FakeAnthropicClient.raising(Anthropic::Error.new("overloaded"))) do
      assert_no_difference -> { Alert.count } do
        AnalyzePanelImageJob.perform_now(@inspection.id)
      end
    end

    panels = @site.panels.reload
    assert panels.all? { |p| p.last_inspected_at.nil? }
    assert panels.all? { |p| p.status == "normal" }
  end

  test "画像なしは failed・severity nil で、パネルを変更しない" do
    inspection = inspections(:analyzing)

    with_fake_claude(FakeAnthropicClient.replying(claude_json)) do |client|
      AnalyzePanelImageJob.perform_now(inspection.id)
      assert_empty client.requests
    end

    inspection.reload
    assert_equal "failed", inspection.analysis_status
    assert_nil inspection.severity
    assert_equal "画像が添付されていません", inspection.error_message
    assert inspection.site.panels.reload.all? { |p| p.last_inspected_at.nil? }
  end

  test "failed にするときは updated_at も更新する" do
    @inspection.update_columns(updated_at: 1.day.ago)

    with_fake_claude(FakeAnthropicClient.raising(Anthropic::Error.new("overloaded"))) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    assert_in_delta Time.current, @inspection.reload.updated_at, 5.seconds
  end

  test "再解析を始めるときに前回の error_message を消す" do
    @inspection.update_columns(analysis_status: "failed", error_message: "前回の失敗")

    with_fake_claude(FakeAnthropicClient.replying(claude_json)) do
      AnalyzePanelImageJob.perform_now(@inspection.id)
    end

    assert_nil @inspection.reload.error_message
  end

  # ── トランザクション（途中で失敗したら何も残さない） ──────────────────

  test "保存処理の途中で例外が起きたら、結果・パネル・アラートを何も残さず failed にする" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json(severity: "critical"))) do
      assert_no_difference -> { Alert.count } do
        JobFailingOnAlert.perform_now(@inspection.id)
      end
    end

    @inspection.reload
    assert_equal "failed", @inspection.analysis_status, "analyzing のまま残らない"
    assert_nil @inspection.severity
    assert_equal 0, @inspection.anomaly_count, "結果の保存はロールバックされる"
    assert_nil @inspection.report
    assert_equal "解析中にエラーが発生しました: アラート作成で障害", @inspection.error_message
    assert @site.panels.reload.all? { |p| p.last_inspected_at.nil? }, "パネル更新もロールバックされる"
  end
end
