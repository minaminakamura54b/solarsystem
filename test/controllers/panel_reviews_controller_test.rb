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
end
