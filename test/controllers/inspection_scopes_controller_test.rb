require "test_helper"

# 点検の対象範囲の画面と、報告書の設定（見直し R1）
class InspectionScopesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg])
    @blocks = register_blocks(@site, %w[A01 A02])
    analyzed_image(@inspection.inspection_images.first, [ @blocks["A01"] ], y0: 0.4)
  end

  test "点検の画面から対象範囲を決め、案のまま確定できる。取り消すと発電所全体" do
    get inspection_path(@inspection, site_id: @site.id)
    assert_select "#report-settings", text: /未確定（発電所全体として数えています）/

    get inspection_scope_path(@inspection, site_id: @site.id)
    assert_response :success
    assert_select "polygon[data-block-id]", 2
    assert_select "input[name='block_ids[]'][checked]", 1, "案（写った A01）が選ばれている"

    patch inspection_scope_path(@inspection, site_id: @site.id), params: { block_ids: [ @blocks["A01"].id ], source: "proposal" }
    assert_redirected_to inspection_path(@inspection, anchor: "report-settings")
    assert @inspection.reload.scope_confirmed?

    delete inspection_scope_path(@inspection, site_id: @site.id)
    assert_not @inspection.reload.scope_confirmed?
  end

  test "報告書に載せる備考を保存できる（社内メモとは別）" do
    patch report_settings_inspection_path(@inspection, site_id: @site.id), params: { report_remarks: " 薄曇り " }
    assert_equal "薄曇り", @inspection.reload.report_remarks
  end
end
