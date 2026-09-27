module ClaudeTestHelper
  # ブロック内だけ ClaudePanelAnalyzer が偽クライアントを使うようにする。
  # ジョブ内部で ClaudePanelAnalyzer.new が呼ばれる場合もこれで差し替わる。
  def with_fake_claude(client)
    previous = ClaudePanelAnalyzer.default_client
    ClaudePanelAnalyzer.default_client = client
    yield client
  ensure
    ClaudePanelAnalyzer.default_client = previous
  end

  def attach_panel_image(inspection)
    inspection.image.attach(
      io: file_fixture("panel.png").open,
      filename: "panel.png",
      content_type: "image/png"
    )
    inspection
  end

  def claude_json(severity: "warning", anomalies: nil, **extra)
    anomalies ||= [
      { "type" => "ホットスポット", "location" => "左上", "description" => "局所的な高温", "severity" => "warning" }
    ]
    {
      "severity" => severity,
      "anomaly_count" => anomalies.size,
      "anomalies" => anomalies,
      "summary" => "テスト用の概要",
      "recommendation" => "テスト用の推奨アクション"
    }.merge(extra.stringify_keys).to_json
  end
end
