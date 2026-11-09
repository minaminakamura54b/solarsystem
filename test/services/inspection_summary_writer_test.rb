require "test_helper"

class InspectionSummaryWriterTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection(files: %w[thermal_plain_T.jpg lowres_T.jpg])
    @inspection.update_columns(claude_enabled: true) # Claude を「使う」にした点検（既定は使わない）
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
    assert_equal "inspection_summary_v3", @inspection.summary_prompt_version
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
    assert_includes input, "点検全体の重要度（ルールで確定・人が確認済み。変更しない）: 重大"
    assert_includes input, "重大度の段階: 3 段階: 軽微 < 注意 < 重大"
    assert_includes request[:system_], "入力の重大度と重要度は、ルールで確定した事実として渡します"
    assert_includes request[:system_], "各対応の緊急度は対象の異常の重大度と整合させる"
    assert_includes input, "確定した異常: 1 件"
    assert_includes input, "- ホットスポット / 重大度 重大 / ΔT 25.1℃ / パネル 未割り当て / 証拠レベル C"
    assert_includes input, "未確定のまま残った候補: 1 件（重要度に含めていない）"
    assert_equal InspectionSummaryWriter::PROMPT_PATH.read, request[:system_]
    assert_equal %w[summary_text priority_actions additional_checks], request[:output_config][:format_][:schema][:properties].keys.map(&:to_s)
  end

  test "点検の範囲と、解析できなかった範囲の有無・内訳を入力に入れる。プロンプトで必ず触れさせ、入力にない数字を作らせない" do
    @second.update_columns(review_reason: "alignment_failed", alignment: { "review_reason" => "no_blocks_in_view" })
    client = FakeAnthropicClient.replying(summary_json)
    write(client)

    request = client.requests.first
    input = request[:messages].first[:content]
    assert_includes input, "点検の範囲: 配置図（架台とパネル）が登録されていないため、写ったパネルの数は出していない"
    assert_includes input, "除外した画像（判定に使っていない）: 1 枚（位置合わせ不可（登録した架台が写っていない） 1 枚）"
    assert_includes input, "配置図に登録されていない所に写った画像（点検の対象外）: 1 枚"
    assert_includes input, "解析できなかった範囲: あり（除外した画像 1 枚・配置図に登録されていない所に写った画像 1 枚）"
    assert_includes request[:system_], "「解析できなかった範囲」が「あり」のときは、総括文で必ずそのことに触れ"
    assert_includes request[:system_], "入力にない数字を作らない"
  end

  test "確定した架台の段は 1 件と数え、写ったパネル・判断の材料が足りない段の数も渡す" do
    blocks = register_blocks(@inspection.site, %w[A01])
    analyzed_image(@first, [ blocks["A01"] ], y0: 0.4)
    @second.update_columns(analysis_status: "completed")
    @inspection.block_row_findings.create!(pv_block: blocks["A01"], block_row: 1, status: "evaluated", effect_c: 1.62, severity: "warning", review_status: "confirmed", locked: true)
    @inspection.block_row_findings.create!(pv_block: blocks["A01"], block_row: 2, status: "insufficient", insufficient_reason: "画像の上側にしか写っておらず")
    InspectionReview.new(@inspection).complete!(all_images_checked: true, acknowledge_pending: true)
    client = FakeAnthropicClient.replying(summary_json)
    write(client)

    input = client.requests.first[:messages].first[:content]
    assert_includes input, "確定した異常: 2 件（隣接パネル群・架台の段は 1 件と数える）"
    assert_includes input, "- 架台の段の温度上昇 / 重大度 注意 / 段の効果 +1.6℃ / 架台 A01 1 段目（10 枚）"
    assert_includes input, "点検の範囲: 登録したパネル 20 枚のうち、解析できた画像に写ったパネル 20 枚（写っていない 0 枚）"
    assert_includes input, "判断の材料が足りない架台の段（写った位置が偏っているなど）: 1 段"
    assert_includes input, "解析できなかった範囲: あり（判断の材料が足りない架台の段 1 段）"

    @inspection.block_row_findings.insufficient.delete_all
    client = FakeAnthropicClient.replying(summary_json)
    write(client, force: true)
    assert_includes client.requests.first[:messages].first[:content], "解析できなかった範囲: なし"
  end

  test "確定した異常が0件なら、正常（確定した異常なし）として渡す" do
    @inspection.anomalies.update_all(review_status: "rejected")
    InspectionReview.new(@inspection).complete!(all_images_checked: true)
    client = FakeAnthropicClient.replying(summary_json)

    write(client)

    input = client.requests.first[:messages].first[:content]
    assert_includes input, "点検全体の重要度（ルールで確定・人が確認済み。変更しない）: 正常（確定した異常なし）"
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
