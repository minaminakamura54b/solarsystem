require "test_helper"

# 点検の範囲と、要確認の画像の理由ごとのまとめての除外
class BulkImageExclusionTest < ActiveSupport::TestCase
  setup do
    @site = sites(:south)
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg] * 4)
    @blocks = register_blocks(@site, %w[A01 A02 A03])
    @i1, @i2, @i3, @i4 = @inspection.inspection_images.order(:sequence).to_a
    analyzed_image(@i1, [ @blocks["A01"] ], y0: 0.4)
  end

  def align_failed(image, reason, grids: [])
    image.update_columns(analysis_status: "needs_review", review_reason: "alignment_failed",
                         alignment: { "status" => "needs_review", "review_reason" => reason, "draft_grids" => grids })
  end

  def draft_grid(block, x0: 0.05)
    { "rows" => 2, "cols" => 10, "corners" => [ [ x0, 0.4 ], [ x0 + 0.4, 0.4 ], [ x0 + 0.4, 0.6 ], [ x0, 0.6 ] ],
      "panel_orientation" => "portrait", "source" => "layout", "pv_block_id" => block.id }
  end

  test "写ったパネルは、解析できた画像の位置合わせのグリッドに中心が入った登録パネル" do
    summary = InspectionCoverage.new(@inspection).summary

    assert_equal 60, summary.registered
    assert_equal 20, summary.covered
    assert_equal 40, summary.uncovered
  end

  test "手動のグリッド（架台とつながっていない）の画像は、写ったパネルに数えない" do
    @i2.update_columns(analysis_status: "completed", panel_grids: [ draft_grid(@blocks["A02"]).except("pv_block_id", "source") ])

    summary = InspectionCoverage.new(@inspection).summary

    assert_equal 20, summary.covered
    assert_equal 1, summary.layout_unlinked_images
  end

  test "画像の外にはみ出したパネルは写ったパネルに数えない" do
    @i2.update_columns(analysis_status: "completed", panel_grids: [ draft_grid(@blocks["A02"], x0: 0.8) ])

    assert_equal 30, InspectionCoverage.new(@inspection).summary.covered # A02 は中心が 1 未満の 1〜5 列目（0.82〜0.98）の 10 枚だけ
  end

  test "位置合わせの理由ごとにまとめ、除外すると写っていないまま残るパネルの数を出す" do
    align_failed(@i2, "no_along_anchor", grids: [ draft_grid(@blocks["A01"]) ])     # 写っているパネルはすでに写っている
    align_failed(@i3, "no_along_anchor", grids: [ draft_grid(@blocks["A02"]) ])     # A02 はほかの画像に写っていない
    align_failed(@i4, "no_blocks_in_view")
    exclusion = BulkImageExclusion.new(@inspection)

    keys = exclusion.groups.map { |g| [ g.key, g.images.size ] }.to_h
    assert_equal({ "needs_review:alignment_failed:no_along_anchor" => 2, "needs_review:alignment_failed:no_blocks_in_view" => 1 }, keys)
    assert_equal "要確認: 位置合わせ不可（架台の端が見つからない）", exclusion.group("needs_review:alignment_failed:no_along_anchor").label

    _, impact = exclusion.preview("needs_review:alignment_failed:no_along_anchor")
    assert_equal 20, impact.newly_uncovered
    assert_equal 0, impact.unknown_position
    _, impact = exclusion.preview("needs_review:alignment_failed:no_blocks_in_view")
    assert_equal 1, impact.unknown_position
  end

  test "品質チェック・解析エンジンの理由もまとめられる" do
    @i2.update_columns(analysis_status: "needs_review", review_reason: "insufficient_baseline")
    @i3.update_columns(analysis_status: "failed", review_reason: "timeout")

    labels = BulkImageExclusion.new(@inspection).groups.map(&:label)

    assert_includes labels, "要確認: #{InspectionsHelper::REVIEW_REASON_MESSAGES['insufficient_baseline']}"
    assert_includes labels, "失敗: #{InspectionsHelper::REVIEW_REASON_MESSAGES['timeout']}"
  end

  test "位置合わせの理由が分からないときは、画像ごとに違う解析エンジンのメッセージではなく理由の名前を出す" do
    @i2.update_columns(analysis_status: "needs_review", review_reason: "alignment_failed",
                       alignment: { "review_reason" => "something_new", "message" => "x: DJI_0001.JPG" })

    assert_equal [ "要確認: 位置合わせ不可（その他: something_new）" ], BulkImageExclusion.new(@inspection).groups.map(&:label)
  end

  test "除外は確認した画像だけ。理由は画像に残り、メモに理由の名前を書く。点検の状態を集計し直す" do
    align_failed(@i2, "no_along_anchor")
    align_failed(@i3, "no_along_anchor")
    @i4.update_columns(analysis_status: "completed")
    key = "needs_review:alignment_failed:no_along_anchor"

    count = BulkImageExclusion.new(@inspection).exclude!(key, image_ids: [ @i2.id ], note: "撮り直さない")

    assert_equal 1, count
    @i2.reload
    assert @i2.excluded?
    assert_equal "alignment_failed", @i2.review_reason
    assert_equal "まとめて除外: 要確認: 位置合わせ不可（架台の端が見つからない）／撮り直さない", @i2.exclusion_note
    assert @i3.reload.needs_review?
    assert_equal "needs_review", @inspection.reload.analysis_status
  end

  test "確認のあとに状態が変わった画像は除外しない" do
    align_failed(@i2, "no_along_anchor")
    key = "needs_review:alignment_failed:no_along_anchor"
    @i2.update_columns(analysis_status: "completed")

    assert_raises(BulkImageExclusion::Error) { BulkImageExclusion.new(@inspection).exclude!(key, image_ids: [ @i2.id ]) }
    assert @i2.reload.completed?
  end
end
