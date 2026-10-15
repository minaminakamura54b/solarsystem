module ClaudeTestHelper
  # ブロック内だけ ClaudeStructuredOutput が偽クライアントを使い、CLAUDE_MODEL を設定する。
  # ジョブ内部で ClaudeStructuredOutput.new が呼ばれる場合もこれで差し替わる（本物の API は呼ばない）
  def with_fake_claude(client, model: "test-model")
    previous_client = ClaudeStructuredOutput.default_client
    previous_model = ENV["CLAUDE_MODEL"]
    ClaudeStructuredOutput.default_client = client
    ENV["CLAUDE_MODEL"] = model
    yield client
  ensure
    ClaudeStructuredOutput.default_client = previous_client
    ENV["CLAUDE_MODEL"] = previous_model
  end

  # AnomalyExplainer の応答（固定スキーマの JSON）。extra で余計な項目（severity など）を足せる
  def explainer_json(**extra)
    {
      "cause_candidates" => [ { "cause" => "バイパスダイオードの故障", "basis" => "帯 2 本の発熱" } ],
      "reasoning" => "帯状の発熱からバイパスダイオードの作動が考えられます",
      "additional_checks" => [ "ストリング電流の測定" ],
      "recommended_action" => "電気測定で確認したうえで、ジャンクションボックスを点検してください",
      "report_text" => "サブストリング 2 本分の帯状の発熱があり、バイパスダイオードが作動している可能性があります。"
    }.merge(extra.stringify_keys).to_json
  end

  # InspectionSummaryWriter の応答
  def summary_json(**extra)
    {
      "summary_text" => "確定した熱異常は 1 件でした。",
      "priority_actions" => [ "重大の異常のパネルを電気測定で確認する" ],
      "additional_checks" => [ "除外した画像の撮り直し" ]
    }.merge(extra.stringify_keys).to_json
  end

  # リクエストの system でどちらのプロンプトか見分けて、対応する応答を返す偽クライアント
  def fake_claude_for_findings(anomaly_extra: {}, summary_extra: {})
    FakeAnthropicClient.new do |params|
      params[:system_].to_s.include?("点検 1 回分") ? summary_json(**summary_extra) : explainer_json(**anomaly_extra)
    end
  end
end
