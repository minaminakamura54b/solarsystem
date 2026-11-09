require "test_helper"

# 報告書の「発電所の様子」の画像を差し替える画面（見直し R4）
class ReportOverviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
    load_initial_rule_set
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg] * 5)
    blocks = register_blocks(@site, %w[A01])
    @images = @inspection.inspection_images.order(:sequence).to_a
    @images.each { |img| analyzed_image(img, [ blocks["A01"] ], y0: 0.4) }
    InspectionReview.new(@inspection).complete!(all_images_checked: true)
  end

  test "発行の画面に提案を出し、差し替えの画面で外す・載せる・提案に戻すができる。顧客向けの報告書に載る" do
    get inspection_reports_path(@inspection, site_id: @site.id)
    assert_select "#overview img", 4
    assert_match "自動の提案", response.body

    get inspection_report_overview_path(@inspection)
    assert_response :success
    assert_select "#selected img", 4
    assert_select "#candidates button[disabled]", 1, "4 枚選んでいれば、ほかの画像は載せられない"

    proposal = ReportOverview.new(@inspection).proposal
    spare = (@images.map(&:id) - proposal).sole
    patch inspection_report_overview_path(@inspection), params: { remove: proposal.first }
    assert_redirected_to inspection_report_overview_path(@inspection)
    patch inspection_report_overview_path(@inspection), params: { add: spare }
    @inspection.reload
    assert_equal proposal.drop(1) + [ spare ], @inspection.report_overview_image_ids

    patch inspection_report_overview_path(@inspection), params: { add: proposal.first }
    assert_equal "載せられるのは 4 枚までです", flash[:alert]

    get preview_inspection_reports_path(@inspection)
    assert_match "発電所の様子（サーモ画像）", response.body
    assert_equal "manual", ReportSnapshotBuilder.new(@inspection.reload).build["overview_source"]

    delete inspection_report_overview_path(@inspection)
    assert_nil @inspection.reload.report_overview_image_ids
  end
end
