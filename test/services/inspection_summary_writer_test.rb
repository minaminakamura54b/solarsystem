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
    assert_equal [ "除外した画像の範囲を撮り直す" ], @inspection.summary_internal_improvements
    assert_nil @inspection.summary_additional_checks
    assert_equal "inspection_summary_v4", @inspection.summary_prompt_version
    assert_equal [ "completed", "critical" ], [ @inspection.analysis_status, @inspection.severity ]
  end

  test "入力は集計だけで、顧客向けの事実（平易な言葉）と社内向けの技術的な情報に分ける。固定スキーマに重大度は無い" do
    load_initial_rule_set # 初期値の版は暫定
    client = FakeAnthropicClient.replying(summary_json)
    write(client)

    request = client.requests.first
    input = request[:messages].first[:content]
    customer, internal = input.split("【社内向けの技術的な情報】")
    assert customer.start_with?("【顧客向けの事実】")
    assert_includes customer, "画像: 解析に使った 1 枚 / 使わなかった 1 枚"
    assert_includes customer, "日射量: 800〜800 W/m²（パネル面 1 枚）"
    assert_includes customer, "気温 21.5〜21.5℃"
    assert_includes customer, "判定基準: 暫定の判定基準を使用"
    assert_includes customer, "点検全体の結果（ルールで確定・人が確認済み。変更しない）: 重大"
    assert_includes customer, "重大度の段階: 3 段階: 軽微 < 注意 < 重大"
    assert_includes customer, "確定した異常: 1 件"
    assert_includes customer, "- ホットスポット（局所的な発熱） / 重大度 重大 / 周りとの温度差 25.1℃ / パネル 特定できず / サーモ画像で確認"
    assert_includes customer, "確認中のまま残った候補: 1 件（結果に含めていない）"
    assert_includes internal, "点検の対象範囲: 未確定（発電所全体として数えている）"
    assert_includes internal, "日射量の記録: あり・気象の記録: あり"
    %w[ΔT 証拠レベル POA 2026-09-initial].each { |word| assert_not_includes customer, word }
    assert_includes request[:system_], "入力の重大度と結果は、ルールで確定した事実として渡します"
    assert_includes request[:system_], "その重大度に合った対応"
    assert_equal InspectionSummaryWriter::PROMPT_PATH.read, request[:system_]
    assert_equal %w[summary_text priority_actions internal_improvements], request[:output_config][:format_][:schema][:properties].keys.map(&:to_s)
  end

  test "点検の範囲と、解析できなかった範囲の有無・内訳を入力に入れる。プロンプトで必ず触れさせ、入力にない数字を作らせない" do
    @second.update_columns(review_reason: "alignment_failed", alignment: { "review_reason" => "no_blocks_in_view" })
    client = FakeAnthropicClient.replying(summary_json)
    write(client)

    request = client.requests.first
    input = request[:messages].first[:content]
    customer, internal = input.split("【社内向けの技術的な情報】")
    assert_includes customer, "解析できたパネル: 配置図が登録されていないため、パネルの枚数では数えていない"
    assert_includes customer, "解析に使わなかった画像: 1 枚（画像からパネルの位置を特定できなかった 1 枚）"
    assert_includes customer, "配置図に登録されていない所が写った画像（点検の対象外）: 1 枚"
    assert_includes customer, "解析できなかった範囲: あり（解析に使わなかった画像 1 枚・配置図に登録されていない所が写った画像 1 枚）"
    assert_not_includes customer, "位置合わせ不可"
    assert_includes internal, "使わなかった画像の技術的な理由: #{BulkImageExclusion.reason_label(@second.reload)} 1 枚"
    assert_includes request[:system_], "「解析できなかった範囲」が「あり」のときは、summary_text で必ずそのことに触れ"
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
    assert_includes input, "確定した異常: 2 件（隣り合う複数のパネルの発熱・架台の段全体の温度の高さは 1 件と数える）"
    assert_includes input, "- 架台の段全体の温度の高さ / 重大度 注意 / 段全体の周りとの温度差 +1.6℃ / 架台 A01 1 段目（10 枚）"
    assert_includes input, "点検した範囲: 発電所全体（架台 A01（1 基・パネル 20 枚））"
    assert_includes input, "解析できたパネル: 対象のパネル 20 枚のうち 20 枚（解析できなかったパネル 0 枚）"
    assert_includes input, "段全体の温度を比べられなかった段: 1 段（撮影の角度が偏っていて、段全体の温度を比べられなかった 1 段。パネルごとの温度の比較は行っている）"
    assert_includes input, "解析できなかった範囲: あり（段全体の温度を比べられなかった段 1 段）"
    assert_includes input, "段全体を判断できなかった理由: 画像の上側にしか写っておらず 1 段"

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
    assert_includes input, "点検全体の結果（ルールで確定・人が確認済み。変更しない）: 正常（確定した異常なし）"
    assert_includes input, "確定した異常: 0 件"
    assert_not_includes input, "異常の一覧"
    system = client.requests.first[:system_]
    assert_includes system, "確定した異常が 0 件なら、根拠のない現地確認や電気的な測定を勧めない"
    assert_includes system, "言えることが無ければ空の配列にする"
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
