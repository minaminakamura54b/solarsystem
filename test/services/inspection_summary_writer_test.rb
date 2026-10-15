require "test_helper"

class InspectionSummaryWriterTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection(files: %w[thermal_plain_T.jpg lowres_T.jpg])
    @first, @second = @inspection.inspection_images.to_a
    @first.update_columns(analysis_status: "completed", irradiance_w_m2: 800, irradiance_type: "poa", air_temp_c: 21.5)
    @second.update_columns(analysis_status: "excluded")
    @inspection.refresh_status!
    @first.anomalies.create!(inspection: @inspection, anomaly_type: "hotspot", severity: "critical", measure: "region_max",
                             delta_t: 25.1, evidence_level: "C", review_status: "confirmed", locked: true)
    @first.anomalies.create!(inspection: @inspection, anomaly_type: "hotspot", severity: "mild", review_status: "pending")
    assert InspectionReview.new(@inspection).complete!(all_images_checked: true, acknowledge_pending: true).completed?
    @inspection.reload
  end

  def write(client, **opts)
    with_fake_claude(client) { InspectionSummaryWriter.new.write(@inspection, **opts) }
  end

  test "レビュー完了した点検に総括文を付け、重要度・状態は変えない" do
    client = FakeAnthropicClient.replying(summary_json(severity: "normal", overall_severity: "mild"))

    assert_equal :explained, write(client)

    @inspection.reload
    assert_equal "確定した熱異常は 1 件でした。", @inspection.summary_text
    assert_equal [ "重大の異常のパネルを電気測定で確認する" ], @inspection.summary_priority_actions
    assert_equal [ "除外した画像の撮り直し" ], @inspection.summary_additional_checks
    assert_equal "inspection_summary_v1", @inspection.summary_prompt_version
    assert_equal [ "completed", "critical" ], [ @inspection.analysis_status, @inspection.severity ]
  end

  test "入力は集計だけ（件数・重要度・除外・未確定の候補・撮影条件）。固定スキーマに重要度は無い" do
    client = FakeAnthropicClient.replying(summary_json)
    write(client)

    request = client.requests.first
    input = request[:messages].first[:content]
    assert_includes input, "画像: 判定に使った 1 枚 / 除外した 1 枚"
    assert_includes input, "日射量: 800〜800 W/m²（POA 1 枚）"
    assert_includes input, "気温 21.5〜21.5℃"
    assert_includes input, "点検全体の重要度（人が確認済み）: 重大"
    assert_includes input, "確定した異常: 1 件"
    assert_includes input, "- ホットスポット / 重大度 重大 / ΔT 25.1℃ / パネル 未割り当て / 証拠レベル C"
    assert_includes input, "未確定のまま残った候補: 1 件（重要度に含めていない）"
    assert_equal InspectionSummaryWriter::PROMPT_PATH.read, request[:system_]
    assert_equal %w[summary_text priority_actions additional_checks], request[:output_config][:format_][:schema][:properties].keys.map(&:to_s)
  end

  test "確定した異常が0件なら、正常（確定した異常なし）として渡す" do
    @inspection.anomalies.update_all(review_status: "rejected")
    InspectionReview.new(@inspection).complete!(all_images_checked: true)
    client = FakeAnthropicClient.replying(summary_json)

    write(client)

    input = client.requests.first[:messages].first[:content]
    assert_includes input, "点検全体の重要度（人が確認済み）: 正常（確定した異常なし）"
    assert_includes input, "確定した異常: 0 件"
    assert_not_includes input, "異常の一覧"
  end

  test "入力が同じなら作り直さない。失敗は記録し、重要度は変えない" do
    write(FakeAnthropicClient.replying(summary_json))
    client = FakeAnthropicClient.replying(summary_json)
    assert_equal :skipped, write(client)
    assert_empty client.requests

    assert_equal :failed, write(FakeAnthropicClient.replying(summary_json(summary_text: "")), force: true)
    @inspection.reload
    assert_match "summary_text", @inspection.summary_error
    assert @inspection.summary_text.present?, "入力が同じなら前の総括文は残す"
    assert_equal "critical", @inspection.severity
  end

  test "レビューを完了していない点検の総括文は作らない" do
    InspectionReview.new(@inspection).reopen!

    assert_raises(ArgumentError) { write(FakeAnthropicClient.replying(summary_json)) }
  end
end
