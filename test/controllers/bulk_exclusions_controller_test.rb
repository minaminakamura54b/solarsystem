require "test_helper"

# 要確認の画像のまとめての除外の画面
class BulkExclusionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg] * 3)
    blocks = register_blocks(@site, %w[A01 A02])
    @i1, @i2, @i3 = @inspection.inspection_images.order(:sequence).to_a
    analyzed_image(@i1, [ blocks["A01"] ], y0: 0.4)
    draft = { "rows" => 2, "cols" => 10, "corners" => [ [ 0.05, 0.4 ], [ 0.45, 0.4 ], [ 0.45, 0.6 ], [ 0.05, 0.6 ] ], "source" => "layout", "pv_block_id" => blocks["A02"].id }
    [ @i2, @i3 ].each do |img|
      img.update_columns(analysis_status: "needs_review", review_reason: "alignment_failed",
                         alignment: { "review_reason" => "no_along_anchor", "draft_grids" => [ draft ] })
    end
    @inspection.refresh_status!
    @key = "needs_review:alignment_failed:no_along_anchor"
  end

  test "点検の画面から、理由ごとの枚数と、除外すると写っていないまま残るパネルの数を確認して除外できる" do
    get inspection_path(@inspection, site_id: @site.id)
    assert_match "要確認・失敗の画像 2 枚を、理由ごとにまとめて除外する", response.body

    get inspection_bulk_exclusion_path(@inspection, site_id: @site.id)
    assert_response :success
    assert_match "登録したパネル 40 枚のうち、解析できた画像に写ったパネル", response.body
    assert_select "#groups td", text: "要確認: 位置合わせ不可（架台の端が見つからない）"

    get inspection_bulk_exclusion_path(@inspection, site_id: @site.id, reason: @key)
    assert_select "#preview", text: /写っていないパネルが 20 枚/

    post inspection_bulk_exclusion_path(@inspection, site_id: @site.id), params: { reason: @key, image_ids: [ @i2.id, @i3.id ], note: "" }
    assert_redirected_to inspection_bulk_exclusion_path(@inspection)
    assert_equal %w[excluded excluded], [ @i2.reload.analysis_status, @i3.reload.analysis_status ]
    assert_equal "review_pending", @inspection.reload.review_reason
  end

  test "まとめる画像が無い理由は、一覧に戻して知らせる" do
    get inspection_bulk_exclusion_path(@inspection, site_id: @site.id, reason: "needs_review:timeout")
    assert_redirected_to inspection_bulk_exclusion_path(@inspection)
  end
end
