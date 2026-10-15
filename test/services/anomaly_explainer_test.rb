require "test_helper"

class AnomalyExplainerTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
    @image.update_columns(irradiance_w_m2: 742, irradiance_type: "poa")
    @inspection.site.update!(cell_layout: "full_cell", substring_count: 3)
    @anomaly = @image.anomalies.create!(
      inspection: @inspection, anomaly_type: "substring_bypass", active_bands: 2, severity: "warning",
      measure: "region_mean", delta_t: 8.4, normalized_delta_t: 11.3, threshold_basis: "normalized", area_ratio: 0.66,
      evidence_level: "B", selected_causes: [ "bypass_diode" ], review_status: "confirmed", locked: true,
      reviewer_note: "山田が確認"
    )
  end

  def explain(client, record = @anomaly, **opts)
    with_fake_claude(client) { AnomalyExplainer.new.explain(record, **opts) }
  end

  test "確定した異常に所見・原因候補・推奨対応が付き、prompt_version と入力の要約値を保存する" do
    client = FakeAnthropicClient.replying(explainer_json)

    assert_equal :explained, explain(client)

    @anomaly.reload
    assert_equal "バイパスダイオードの故障", @anomaly.cause_candidates.first["cause"]
    assert_match "バイパスダイオード", @anomaly.report_text
    assert_match "電気測定", @anomaly.recommended_action
    assert_equal [ "ストリング電流の測定" ], @anomaly.additional_checks
    assert_match "帯状", @anomaly.explanation
    assert_equal "anomaly_explainer_v2", @anomaly.prompt_version
    assert @anomaly.explanation_input_digest.present?
    assert @anomaly.explained_at.present?
    assert_nil @anomaly.explanation_error
  end

  test "Claude が severity や正常の判断を返しても、DB の判定は変わらず、余計な項目は保存しない" do
    client = FakeAnthropicClient.replying(explainer_json(severity: "normal", is_anomaly: false, final_severity: "mild"))

    assert_equal :explained, explain(client)

    @anomaly.reload
    assert_equal [ "warning", nil, "confirmed", true ], [ @anomaly.severity, @anomaly.final_severity, @anomaly.review_status, @anomaly.locked ]
    assert_equal "warning", InspectionReview.new(@inspection).final_severity
    assert_not_includes @anomaly.attributes.values.compact.map(&:to_s).join, "is_anomaly"
  end

  test "送るのは構造化データの文字だけ。固定スキーマに severity は無く、モデル名は CLAUDE_MODEL、人のメモは送らない" do
    client = FakeAnthropicClient.replying(explainer_json)

    with_fake_claude(client, model: "model-from-env") { AnomalyExplainer.new.explain(@anomaly) }

    request = client.requests.first
    assert_equal "model-from-env", request[:model]
    assert_equal AnomalyExplainer::PROMPT_PATH.read, request[:system_]
    input = request[:messages].first[:content]
    assert_kind_of String, input # 画像は送らない
    assert_includes input, "種類: substring_bypass（サブストリングのバイパス、帯 2 本。"
    assert_includes input, "重大度（ルールで確定・人が確認済み。変更しない）: 注意（3 段階: 軽微 < 注意 < 重大）"
    assert_includes input, "ΔT: 8.4℃（高温領域の平均温度 − 基準温度） / 正規化ΔT: 11.3℃"
    assert_includes input, "日射量: 742 W/m²（POA）"
    assert_includes input, "モジュール: フルセル・サブストリング 3"
    assert_includes input, "証拠レベル: B（サーモ＋RGB）"
    assert_includes input, "人が選んだ原因候補: バイパスダイオードの故障"
    assert_not_includes input, "山田"
    schema = request[:output_config][:format_][:schema]
    assert_equal :json_schema, request[:output_config][:format_][:type]
    assert_not_includes schema[:properties].keys.map(&:to_s), "severity"
    assert_equal false, schema[:additionalProperties]
  end

  test "入力が前回と同じなら作り直さない。force なら作り直す。データが変われば作り直す" do
    client = FakeAnthropicClient.replying(explainer_json)
    explain(client)

    assert_equal :skipped, explain(client)
    assert_equal 1, client.requests.size

    assert_equal :explained, explain(client, force: true)
    assert_equal 2, client.requests.size

    @anomaly.update_columns(evidence_level: "A")
    assert_not AnomalyExplainer.new(output: nil).current?(@anomaly.reload)
    assert_equal :explained, explain(client)
    assert_equal 3, client.requests.size
  end

  test "CLAUDE_MODEL が未設定なら API を呼ばずに失敗として記録し、判定は変えない" do
    client = FakeAnthropicClient.replying(explainer_json)

    result = with_fake_claude(client, model: nil) { AnomalyExplainer.new.explain(@anomaly) }

    assert_equal :failed, result
    assert_empty client.requests
    @anomaly.reload
    assert_match "CLAUDE_MODEL", @anomaly.explanation_error
    assert_nil @anomaly.report_text
    assert_equal [ "warning", "confirmed" ], [ @anomaly.severity, @anomaly.review_status ]
  end

  test "API エラー・拒否・途中で切れた応答・JSON でない応答・所見文が空の応答は失敗として記録する" do
    request = Anthropic::Errors::APIConnectionError.new(url: URI("https://api.anthropic.com/v1/messages"))
    cases = {
      FakeAnthropicClient.raising(request) => "接続できませんでした",
      FakeAnthropicClient.replying(explainer_json, stop_reason: :refusal) => "拒否",
      FakeAnthropicClient.replying("{\"cause_candidates\": [", stop_reason: :max_tokens) => "途中で切れました",
      FakeAnthropicClient.replying("所見です") => "JSON として読めません",
      FakeAnthropicClient.replying(explainer_json(report_text: "")) => "report_text"
    }
    cases.each do |client, message|
      assert_equal :failed, explain(client, force: true), message
      assert_match message, @anomaly.reload.explanation_error
      assert_equal "warning", @anomaly.severity
    end
  end

  test "失敗しても、入力が同じなら前の所見は残す。入力が変わっていたら古い所見を消す" do
    explain(FakeAnthropicClient.replying(explainer_json))
    error = Anthropic::Errors::APIConnectionError.new(url: URI("https://api.anthropic.com/v1/messages"))

    explain(FakeAnthropicClient.raising(error), force: true)
    @anomaly.reload
    assert @anomaly.report_text.present?
    assert @anomaly.explanation_error.present?

    @anomaly.update_columns(evidence_level: "A")
    explain(FakeAnthropicClient.raising(error))
    @anomaly.reload
    assert_nil @anomaly.report_text
    assert_nil @anomaly.explained_at
    assert @anomaly.explanation_error.present?
  end

  test "重大度は修正後の値を渡す。プロンプトに重大度を評価・変更しないこと、緊急度を重大度と整合させることを書いている" do
    @anomaly.update_columns(review_status: "corrected", final_severity: "critical")
    client = FakeAnthropicClient.replying(explainer_json)

    explain(client)

    request = client.requests.first
    assert_includes request[:messages].first[:content], "重大度（ルールで確定・人が確認済み。変更しない）: 重大（"
    assert_includes request[:system_], "入力の「重大度」は、ルールで確定した事実として渡します"
    assert_includes request[:system_], "重大度を評価・変更したり"
    assert_includes request[:system_], "対応の緊急度は、入力の重大度と整合させる"
  end

  test "前の版（v1）のプロンプトで作った所見は、古い所見として扱い作り直す" do
    client = FakeAnthropicClient.replying(explainer_json)
    explain(client)
    v1_digest = Digest::SHA256.hexdigest("anomaly_explainer_v1\n#{AnomalyExplainer.new(output: nil).input_text(@anomaly)}")
    @anomaly.update_columns(prompt_version: "anomaly_explainer_v1", explanation_input_digest: v1_digest)

    assert_not AnomalyExplainer.new(output: nil).current?(@anomaly.reload)
    assert_equal :explained, explain(client)
    assert_equal "anomaly_explainer_v2", @anomaly.reload.prompt_version
  end

  test "確定していない異常の所見は作らない" do
    @anomaly.update_columns(review_status: "pending")

    assert_raises(ArgumentError) { explain(FakeAnthropicClient.replying(explainer_json)) }
  end

  test "群は群の値と構成パネルの最も弱い証拠レベルで所見を作り、群の判定は変えない" do
    group = @image.anomaly_groups.create!(inspection: @inspection, group_type: "panel_row_group", panel_count: 3,
                                          panel_indices: [ 1, 2, 3 ], measure: "panel_mean", delta_t: 4.2,
                                          threshold_basis: "raw", severity: "mild", review_status: "confirmed", locked: true)
    @anomaly.update_columns(anomaly_group_id: group.id, evidence_level: "C")
    client = FakeAnthropicClient.replying(explainer_json(severity: "critical"))

    assert_equal :explained, explain(client, group)

    input = client.requests.first[:messages].first[:content]
    assert_includes input, "種類: panel_row_group（隣接パネル群。"
    assert_includes input, "パネル数: 3"
    assert_includes input, "重大度（ルールで確定・人が確認済み。変更しない）: 軽微（"
    assert_includes input, "正規化ΔT: なし（未正規化）"
    assert_includes input, "証拠レベル: C（サーモのみ）"
    group.reload
    assert_match "バイパスダイオード", group.report_text
    assert_equal [ "mild", "confirmed" ], [ group.severity, group.review_status ]
  end
end
