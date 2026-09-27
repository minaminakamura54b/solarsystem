require "test_helper"

# 現行の ClaudePanelAnalyzer の挙動を記録するテスト。
# 「Phase 1 で変更」と書いたテストは、危険な現状の挙動をそのまま記録したもので、
# Phase 1 で期待値を反転させる（docs/IMPROVEMENT_PLAN.md の Phase 1 を参照）。
class ClaudePanelAnalyzerTest < ActiveSupport::TestCase
  setup do
    @inspection = attach_panel_image(inspections(:pending))
  end

  test "正しい JSON の応答から重大度・異常一覧・概要を取り出す" do
    client = FakeAnthropicClient.replying(claude_json(severity: "critical"))

    result = ClaudePanelAnalyzer.new(@inspection, client: client).analyze

    assert_nil result[:error]
    assert_equal "critical", result[:severity]
    assert_equal 1, result[:anomaly_count]
    assert_equal "ホットスポット", result[:anomalies].first["type"]
    assert_equal "テスト用の概要", result[:summary]
    assert_equal "テスト用の推奨アクション", result[:recommendation]
  end

  test "コードブロックで囲まれた JSON も取り出す" do
    client = FakeAnthropicClient.replying("```json\n#{claude_json}\n```")

    result = ClaudePanelAnalyzer.new(@inspection, client: client).analyze

    assert_nil result[:error]
    assert_equal "warning", result[:severity]
  end

  test "リクエストに画像を Base64 で添付し、max_tokens は 1024" do
    client = FakeAnthropicClient.replying(claude_json)

    ClaudePanelAnalyzer.new(@inspection, client: client).analyze

    request = client.requests.sole
    assert_equal 1024, request[:max_tokens]
    image = request[:messages].first[:content].find { |c| c[:type] == "image" }
    assert_equal "image/png", image[:source][:media_type]
    assert_equal Base64.strict_encode64(file_fixture("panel.png").binread), image[:source][:data]
  end

  test "default_client を設定すると new(inspection) だけでも偽クライアントが使われる" do
    with_fake_claude(FakeAnthropicClient.replying(claude_json)) do |client|
      ClaudePanelAnalyzer.new(@inspection).analyze
      assert_equal 1, client.requests.size
    end
    assert_nil ClaudePanelAnalyzer.default_client
  end

  test "現状: 壊れた JSON は error なしの normal・異常0件になる（Phase 1 で failed に変更）" do
    # { と } はあるが JSON として不正 → JSON::ParserError の経路
    client = FakeAnthropicClient.replying('{"severity": "critical", "anomalies": [ }')

    result = ClaudePanelAnalyzer.new(@inspection, client: client).analyze

    assert_nil result[:error], "現状はエラー扱いにならない"
    assert_equal "normal", result[:severity]
    assert_equal 0, result[:anomaly_count]
  end

  test "現状: 途中で切れた応答は error 付きだが severity は normal（Phase 1 で severity を nil に変更）" do
    # max_tokens で打ち切られた想定。閉じ括弧がないため正規表現に一致しない
    client = FakeAnthropicClient.replying('{"severity": "critical", "anomalies": [')

    result = ClaudePanelAnalyzer.new(@inspection, client: client).analyze

    assert_equal "JSON形式の応答が得られませんでした", result[:error]
    assert_equal "normal", result[:severity]
  end

  test "現状: JSON を含まない応答は error 付きだが severity は normal（Phase 1 で severity を nil に変更）" do
    client = FakeAnthropicClient.replying("画像を解析できませんでした。")

    result = ClaudePanelAnalyzer.new(@inspection, client: client).analyze

    assert_equal "JSON形式の応答が得られませんでした", result[:error]
    assert_equal "normal", result[:severity]
  end

  test "現状: severity が欠けた JSON は normal で補われる（Phase 1 で failed に変更）" do
    json = { "anomaly_count" => 2, "anomalies" => [ {}, {} ], "summary" => "x" }.to_json
    client = FakeAnthropicClient.replying(json)

    result = ClaudePanelAnalyzer.new(@inspection, client: client).analyze

    assert_nil result[:error]
    assert_equal "normal", result[:severity]
    assert_equal 2, result[:anomaly_count]
  end

  test "現状: API エラーは error 付きだが severity は normal（Phase 1 で severity を nil に変更）" do
    client = FakeAnthropicClient.raising(Anthropic::Error.new("overloaded"))

    result = ClaudePanelAnalyzer.new(@inspection, client: client).analyze

    assert_equal "Claude API エラー: overloaded", result[:error]
    assert_equal "normal", result[:severity]
  end

  test "現状: 想定外の例外も error 付きだが severity は normal（Phase 1 で severity を nil に変更）" do
    client = FakeAnthropicClient.raising(RuntimeError.new("timeout"))

    result = ClaudePanelAnalyzer.new(@inspection, client: client).analyze

    assert_equal "解析エラー: timeout", result[:error]
    assert_equal "normal", result[:severity]
  end

  test "現状: 画像なしは API を呼ばず error 付きの normal（Phase 1 で severity を nil に変更）" do
    client = FakeAnthropicClient.replying(claude_json)

    result = ClaudePanelAnalyzer.new(inspections(:analyzing), client: client).analyze

    assert_equal "画像が添付されていません", result[:error]
    assert_equal "normal", result[:severity]
    assert_empty client.requests
  end
end
