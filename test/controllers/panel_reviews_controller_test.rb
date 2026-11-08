require "test_helper"

# パネルごとの候補の画面
class PanelReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg thermal_plain_T.jpg])
    blocks = register_blocks(@site, %w[A01 A02 A03])
    @i1, @i2 = @inspection.inspection_images.order(:sequence).to_a
    analyzed_image(@i1, blocks.values.first(2), y0: 0.4)
    analyzed_image(@i2, blocks.values.last(2), y0: 0.4)
    anomaly_at(@i1, 0, 1, 1, type: "multi_hotspot", u: 0.1)
    anomaly_at(@i1, 1, 1, 1, type: "multi_hotspot", u: 0.1)
    anomaly_at(@i2, 1, 1, 1, type: "multi_hotspot", u: 0.1)
    @other = anomaly_at(@i2, 0, 2, 5)
    PanelCandidateBuilder.new(@inspection).call
  end

  def path(**opts) = inspection_panel_review_path(@inspection, site_id: @site.id, **opts)

  test "パネルごとに 1 行で表示し、目印で絞り込める" do
    get path
    assert_response :success
    assert_select "#candidates tr[id^=candidate_]", 4
    assert_match "多くの架台の同じ位置（3）", response.body

    get path(flag: "same_position")
    assert_select "#candidates tr[id^=candidate_]", 3
  end

  test "目印で絞り込んだ候補を、部材・構造物としてまとめて却下できる。判断済みの候補は一覧から消える" do
    ids = @inspection.panel_candidates.select { |c| c.flags.include?("same_position") }.map(&:id)

    post bulk_reject_inspection_panel_review_path(@inspection, site_id: @site.id), params: { candidate_ids: ids, reason: "structure", flag: "same_position" }

    assert_redirected_to inspection_panel_review_path(@inspection, flag: "same_position")
    assert_equal %w[structure] * 3, @inspection.anomalies.where(anomaly_type: "multi_hotspot").pluck(:rejection_reason)
    assert_equal "pending", @other.reload.review_status
    get path
    assert_select "#candidates tr[id^=candidate_]", 1
  end

  test "1 件ずつ確定・却下できる。理由が無ければ却下しない" do
    c = @inspection.panel_candidates.find_by!(panel: @other.panel)
    post reject_inspection_panel_candidate_path(@inspection, c, site_id: @site.id)
    assert_equal "pending", c.reload.review_status

    post confirm_inspection_panel_candidate_path(@inspection, c, site_id: @site.id)
    assert_equal [ "confirmed", "confirmed" ], [ c.reload.review_status, @other.reload.review_status ]
  end

  test "作り直すと未判断の候補だけ作り直す" do
    post rebuild_inspection_panel_review_path(@inspection, site_id: @site.id)
    assert_redirected_to inspection_panel_review_path(@inspection)
    assert_equal 4, @inspection.panel_candidates.count
  end

  test "架台・段の候補を上に表示し、判断の材料が足りない段は理由つきで表示する。確定・却下できる" do
    block = @site.pv_blocks.first
    hot = @inspection.block_row_findings.create!(pv_block: block, block_row: 2, status: "evaluated", effect_c: 1.2, views_count: 6, upper_views: 3, lower_views: 3,
                                                 severity: "mild", observations: [ { "image_id" => @i1.id, "sequence" => 1, "y" => 0.5, "effect" => 1.2, "bbox" => { "x1" => 0.1, "y1" => 0.4, "x2" => 0.5, "y2" => 0.5 } } ])
    @inspection.block_row_findings.create!(pv_block: block, block_row: 1, status: "insufficient", insufficient_reason: "画像の下側にしか写っておらず、見え方の影響と区別できません")

    get path
    assert_select "#row-candidates tr#row_finding_#{hot.id}"
    assert_select "#row-insufficient", text: /判断の材料が足りない段（1 段。正常とは扱いません）/
    assert_match "画像の下側にしか写っておらず", response.body
    assert_select "svg[aria-label='架台・段の効果の配置図'] polygon", minimum: 2

    post reject_row_inspection_block_row_finding_path(@inspection, hot, site_id: @site.id)
    assert_equal "pending", hot.reload.review_status, "理由が無ければ却下しない"
    post confirm_row_inspection_block_row_finding_path(@inspection, hot, site_id: @site.id)
    assert_equal [ "confirmed", true ], [ hot.reload.review_status, hot.locked ]
  end

  test "「部材・構造物」でまとめて却下するときに部材の位置を登録でき、次の点検では目印を付けてたたむ（自動では却下しない）" do
    ids = @inspection.panel_candidates.select { |c| c.flags.include?("same_position") }.map(&:id)
    post bulk_reject_inspection_panel_review_path(@inspection, site_id: @site.id), params: { candidate_ids: ids, reason: "structure", register_structure: "1" }
    assert_equal 1, @site.structure_positions.count, "3 つの架台の同じ位置は 1 か所として登録する"
    position = StructurePosition.where(site: @site).sole
    assert_equal [ 1, 1 ], [ position.block_row, position.block_col ]

    # 次の点検: 同じ位置の点状の発熱
    nxt = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg])
    img = nxt.inspection_images.first
    analyzed_image(img, @site.pv_blocks.order(:label).first(2), y0: 0.4)
    a = anomaly_at(img, 0, 1, 1, type: "multi_hotspot", u: 0.1)
    other = anomaly_at(img, 1, 2, 7, type: "hotspot", u: 0.7, v: 0.7)
    PanelCandidateBuilder.new(nxt).call
    flagged = nxt.panel_candidates.find_by!(panel: a.panel)
    assert_includes flagged.flags, "registered_structure"
    assert_not_includes nxt.panel_candidates.find_by!(panel: other.panel).flags, "registered_structure"
    get inspection_panel_review_path(nxt, site_id: @site.id)
    assert_select "#candidates tr[id^=candidate_]", 1
    assert_select "#hidden-structure", text: /登録済みの部材の位置に出た候補が 1 件/
    get inspection_panel_review_path(nxt, site_id: @site.id, flag: "registered_structure")
    assert_select "#candidates tr#candidate_#{flagged.id}"
    assert_equal "pending", a.reload.review_status, "自動では却下しない"
  end

  test "部材の位置の登録は、理由が「部材・構造物」でチェックしたときだけ" do
    ids = @inspection.panel_candidates.select { |c| c.flags.include?("same_position") }.map(&:id)
    post bulk_reject_inspection_panel_review_path(@inspection, site_id: @site.id), params: { candidate_ids: ids, reason: "glare", register_structure: "1" }
    assert_equal 0, @site.structure_positions.count
  end
end
