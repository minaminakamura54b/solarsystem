require "test_helper"

# 報告書の内容（版の固定コピー）と発行（Phase 7）
class ReportIssueTest < ActiveSupport::TestCase
  setup do
    @site = sites(:south)
    @site.update!(module_rated_w: 400)
    load_initial_rule_set
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg] * 3)
    @blocks = register_blocks(@site, %w[A01 A02])
    @i1, @i2, @i3 = @inspection.inspection_images.order(:sequence).to_a
    analyzed_image(@i1, [ @blocks["A01"] ], y0: 0.4)
    analyzed_image(@i2, [ @blocks["A01"] ], y0: 0.4)
    @i3.update_columns(analysis_status: "excluded", review_reason: "alignment_failed", exclusion_note: "まとめて除外",
                       alignment: { "review_reason" => "no_blocks_in_view" })
    rule = RuleSet.active_set.rule_for("hotspot").snapshot
    @a1 = anomaly_at(@i1, 0, 1, 3, type: "hotspot", severity: "warning", rule_snapshot: rule, threshold_basis: "raw")
    @a2 = anomaly_at(@i2, 0, 1, 3, type: "hotspot", severity: "warning", rule_snapshot: rule, threshold_basis: "raw")
    @rejected = anomaly_at(@i1, 0, 2, 8, type: "hotspot", rule_snapshot: rule)
    PanelCandidateBuilder.new(@inspection).call
    candidate = @a1.reload.panel_candidate
    PanelCandidateReview.new(candidate).confirm!(note: nil)
    PanelCandidateReview.new(@rejected.reload.panel_candidate).reject!(reason: "structure", note: nil)
    @inspection.block_row_findings.create!(pv_block: @blocks["A02"], block_row: 2, status: "insufficient", insufficient_reason: "画像の上側にしか写っておらず")
    assert InspectionReview.new(@inspection).complete!(all_images_checked: true).completed?
    @inspection.reload
  end

  def snapshot = ReportSnapshotBuilder.new(@inspection).build

  test "本表は確定した異常を 1 件 1 行（重複として却下した観測はまとめる）。N 枚中 M 枚を枚数で載せる" do
    items = snapshot["items"]

    assert_equal 1, items.size
    item = items.first
    assert_equal "A01-1-03", item["panel"]
    assert_equal [ 2, 2 ], [ item["visible"], item["observed"] ]
    assert_equal 1, item["others"].size, "代表以外の、異常が出た画像"
    assert_equal 0.4, item["affected_dc_kw"]
    assert_equal ReportSnapshotBuilder::NO_EXPLANATION, item["explanation"], "所見が無ければ「所見は作成していません」"
  end

  test "点検の範囲と限界: 写ったパネル・使わなかった画像の理由・配置図に無い所・判断の材料が足りない段" do
    coverage = snapshot["coverage"]

    assert_equal [ 40, 20, 20 ], coverage.values_at("registered", "covered", "uncovered")
    assert_equal({ "位置合わせ不可（登録した架台が写っていない）" => 1 }, coverage["unused_by_reason"])
    assert_equal 1, coverage["outside_layout_images"]
    assert_equal [ "A02 2 段目" ], coverage["insufficient_rows"].map { |r| r["label"] }
    assert_equal 20, snapshot["map"]["uncovered_panels"].size
    assert_equal [ [ "A01", 1, 3 ] ], snapshot["map"]["anomaly_panels"]
  end

  test "付録: 人が確認し、異常ではないと判断した候補の件数（重複として却下した観測は数えない）" do
    assert_equal({ "total" => 1, "by_reason" => { "部材・構造物" => 1 } }, snapshot["rejections"])
  end

  test "暫定の判定基準を使ったら、判定基準と警告と免責に載せる。使っていなければ載せない" do
    RuleSet.active_set.update_columns(provisional: false) # 暫定でない版（依頼元と合意した版）を使った場合
    assert_not snapshot.dig("criteria", "provisional")
    assert_not snapshot["disclaimers"].any? { |l| l.include?("暫定") }

    RuleSet.active_set.mark_provisional!
    s = snapshot
    assert s.dig("criteria", "provisional")
    assert s["warnings"].any? { |w| w.include?("暫定の判定基準") }
    assert_includes s["disclaimers"], "判定基準は暫定の版で、今後見直す予定です。"
  end

  test "測定パラメータにカメラの既定値を使ったときだけ、免責にその 1 行を載せる" do
    line = "放射率など測定パラメータの一部は、カメラの既定値を使用しています（撮影条件の欄に記載）。"
    assert_not_includes snapshot["disclaimers"], line

    @i1.update_columns(measurement_params: { "emissivity" => { "value" => nil, "source" => "not_set" }, "reflected_temperature_c" => { "value" => 20.0, "source" => "inspection" } })
    assert_includes snapshot["disclaimers"], line
  end

  test "発行すると版として残り、同じ内容では次の版を出さない。変わったら改訂の理由を付けて第 2 版" do
    issue = ReportIssue.new(@inspection)
    assert_raises(ReportIssue::Error) { issue.issue! } # 総括文が無い警告を確認していない

    report = ReportIssue.new(@inspection).issue!(acknowledge_warnings: true, company_name: "株式会社テスト", qualification: "サーモグラフィ")
    assert_equal 1, report.version_number
    assert_equal "株式会社テスト", report.snapshot.dig("issue", "company_name")
    assert_includes report.acknowledged_warnings, "総括文が書かれていません（総括文の欄は空になります）"
    assert_not ReportIssue.new(@inspection).changed_since_latest?
    error = assert_raises(ReportIssue::Error) { ReportIssue.new(@inspection).issue!(acknowledge_warnings: true, revision_reason: "x") }
    assert_match "内容が変わっていません", error.message

    @site.update!(module_rated_w: 410)
    assert ReportIssue.new(@inspection.reload).changed_since_latest?
    error = assert_raises(ReportIssue::Error) { ReportIssue.new(@inspection).issue!(acknowledge_warnings: true) }
    assert_match "改訂の理由", error.message
    second = ReportIssue.new(@inspection).issue!(acknowledge_warnings: true, revision_reason: "定格出力の訂正")
    assert_equal 2, second.version_number
    assert_equal 0.4, report.reload.snapshot["items"].first["affected_dc_kw"], "前の版の内容は変わらない"
    assert_equal 0.41, second.snapshot["items"].first["affected_dc_kw"]
  end

  test "レビューを完了していない点検は発行できない。発行した版は変えられず、削除もできない" do
    report = ReportIssue.new(@inspection).issue!(acknowledge_warnings: true)
    assert_not report.update(revision_reason: "書き換え")
    assert_not report.destroy
    assert_not @inspection.destroy, "報告書を発行した点検は削除しない"

    InspectionReview.new(@inspection).reopen!
    assert_raises(ReportIssue::Error) { ReportIssue.new(@inspection.reload).issue!(acknowledge_warnings: true, revision_reason: "x") }
  end

  test "報告書に個人名・確信度を載せない（屋号は設定ファイル）" do
    s = snapshot
    assert_equal ReportConfig.current.business_name, s["business_name"]
    json = JSON.generate(s)
    assert_no_match(/確信度|confidence|%/, json)
  end
end
