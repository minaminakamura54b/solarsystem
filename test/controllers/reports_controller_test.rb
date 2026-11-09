require "test_helper"

# 報告書の画面（版の一覧・発行・プレビュー・発行した版）
class ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
    @site.update!(module_rated_w: 400)
    load_initial_rule_set
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg] * 2)
    blocks = register_blocks(@site, %w[A01])
    @i1, @i2 = @inspection.inspection_images.order(:sequence).to_a
    analyzed_image(@i1, [ blocks["A01"] ], y0: 0.4)
    analyzed_image(@i2, [ blocks["A01"] ], y0: 0.4)
    @anomaly = anomaly_at(@i1, 0, 1, 3, type: "hotspot", severity: "warning", review_status: "confirmed", locked: true,
                                        rule_snapshot: RuleSet.active_set.rule_for("hotspot").snapshot, report_text: "所見の文")
    InspectionReview.new(@inspection).complete!(all_images_checked: true)
  end

  test "点検の画面から報告書へ。警告を確認して発行し、版を表示できる" do
    get inspection_path(@inspection, site_id: @site.id)
    assert_match "報告書（0 版発行）", response.body

    get inspection_reports_path(@inspection, site_id: @site.id)
    assert_response :success
    assert_select "#warnings li", minimum: 1
    assert_select "input[name=revision_reason]", 0, "第 1 版は改訂の理由が要らない"

    post inspection_reports_path(@inspection, site_id: @site.id), params: { company_name: "株式会社テスト" }
    assert_redirected_to inspection_reports_path(@inspection)
    assert_equal 0, @inspection.inspection_reports.count, "警告を確認しなければ発行しない"

    post inspection_reports_path(@inspection, site_id: @site.id), params: { acknowledge_warnings: "1", company_name: "株式会社テスト" }
    report = @inspection.inspection_reports.sole
    get inspection_report_path(@inspection, report, site_id: @site.id)
    assert_response :success
    assert_match "熱異常スクリーニング報告書", response.body
    assert_match "第 1 版", response.body
    assert_match "株式会社テスト", response.body
    assert_match ReportConfig.current.business_name, response.body
    assert_match "A01-1-03", response.body
    assert_match "—（個別の画像で確認）", response.body, "パネルごとの候補を通していない異常"
    assert_match "点検の範囲と限界", response.body
    assert_match "人が確認し、異常ではないと判断した候補の件数", response.body
  end

  test "所見が今のデータと合わないときは「所見は作成していません」と載せる" do
    get preview_inspection_reports_path(@inspection, site_id: @site.id)
    assert_response :success
    assert_match "所見は作成していません", response.body
    assert_match "プレビュー（未発行）", response.body
  end

  test "発行後に内容が変わったら、点検の画面と報告書の画面に知らせ、改訂の理由を求める" do
    ReportIssue.new(@inspection).issue!(acknowledge_warnings: true)
    @site.update!(module_rated_w: 410)

    get inspection_path(@inspection, site_id: @site.id)
    assert_select "#report-changed", text: /第 1 版の発行後に変更があります/
    get inspection_reports_path(@inspection, site_id: @site.id)
    assert_select "#changed"
    assert_select "input[name=revision_reason][required]"
  end

  test "報告書を発行した点検は削除できない" do
    ReportIssue.new(@inspection).issue!(acknowledge_warnings: true)

    delete inspection_path(@inspection, site_id: @site.id)
    assert_redirected_to inspection_path(@inspection)
    assert Inspection.exists?(@inspection.id)
  end
end
