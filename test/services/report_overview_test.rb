require "test_helper"

# 報告書の「発電所の様子」のサーモ画像（見直し R4）
class ReportOverviewTest < ActiveSupport::TestCase
  # 画像の撮影位置（発電所の中の東西・南北の m）
  POSITIONS = [ [ 0, 0 ], [ 100, 0 ], [ 0, 100 ], [ 100, 100 ], [ 50, 50 ], [ 55, 45 ] ].freeze

  setup do
    @site = sites(:south)
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg] * POSITIONS.size)
    @blocks = register_blocks(@site, %w[A01 A02 A03])
    @images = @inspection.inspection_images.order(:sequence).to_a
    frame = GeoFrame.new(35.0, 139.0)
    @images.zip(POSITIONS).each do |img, (e, n)|
      analyzed_image(img, [ @blocks["A01"] ], y0: 0.4)
      lat, lng = frame.to_latlng(e, n)
      img.update_columns(gps_lat: lat, gps_lng: lng)
    end
  end

  def overview = ReportOverview.new(@inspection.reload)

  test "撮影位置で散らばるように、離れた所から順に 4 枚を提案する（中央の画像は選ばない）" do
    assert_equal @images.first(4).map(&:id).sort, overview.proposal.sort
  end

  test "同じくらい離れていれば、写っている架台の多い画像を選ぶ" do
    analyzed_image(@images[3], [ @blocks["A02"], @blocks["A03"] ], y0: 0.4)
    proposal = overview.proposal

    assert_equal @images[3].id, proposal.first, "4 隅は中心から同じ距離なので、架台が 2 つ写った画像から選ぶ"
    assert_equal "A02〜A03", overview.candidate(@images[3].id).blocks
  end

  test "異常（却下したもの以外）の画像・解析できなかった画像・対象範囲の外の画像は候補にしない" do
    anomaly_at(@images[0], 0, 1, 1, review_status: "confirmed")
    anomaly_at(@images[1], 0, 1, 1, review_status: "pending")
    anomaly_at(@images[2], 0, 1, 1, review_status: "rejected", rejection_reason: "glare")
    @images[3].update_columns(analysis_status: "excluded")
    ids = overview.candidates.map(&:id)

    assert_equal [ @images[2], @images[4], @images[5] ].map(&:id), ids

    analyzed_image(@images[4], [ @blocks["A02"] ], y0: 0.4)
    InspectionScope.new(@inspection).confirm!([ @blocks["A01"].id ], source: "manual")
    assert_equal [ @images[2], @images[5] ].map(&:id), overview.candidates.map(&:id), "対象範囲の架台が写っていない画像は外す"
  end

  test "品質チェックに問題のない画像を先に選び、足りなければ注意の画像から選ぶ" do
    @images.first(3).each { |img| img.update_columns(quality_report: { "status" => "warning", "checks" => [] }) }
    proposal = overview.proposal

    assert_equal @images[3].id, proposal.first
    assert_equal [ @images[3], @images[4], @images[5] ].map(&:id).sort, proposal.first(3).sort
    assert_equal 4, proposal.size
  end

  test "撮影位置が無ければ、撮影の順に等間隔で選ぶ" do
    @images.each { |img| img.update_columns(gps_lat: nil, gps_lng: nil) }

    assert_equal [ @images[0], @images[2], @images[3], @images[5] ].map(&:id), overview.proposal
  end

  test "人が差し替えたら、その画像を使う。上限・候補でない画像は断り、候補から外れた画像は載せない。提案に戻せる" do
    o = overview
    o.select!([ @images[4].id, @images[5].id ])
    assert overview.manual?
    assert_equal [ @images[4].id, @images[5].id ], overview.selected_ids

    overview.add!(@images[0].id)
    overview.remove!(@images[4].id)
    assert_equal [ @images[5].id, @images[0].id ], overview.selected_ids

    assert_raises(ReportOverview::Error) { overview.select!(@images.first(5).map(&:id)) }
    @images[1].update_columns(analysis_status: "excluded")
    assert_raises(ReportOverview::Error) { overview.add!(@images[1].id) }

    anomaly_at(@images[0], 0, 1, 1, review_status: "confirmed")
    assert_equal [ @images[5].id ], overview.selected_ids, "後で異常が確定した画像は載せない"

    overview.reset!
    assert_not overview.manual?
  end

  test "固定コピーに、撮影時刻と写っている架台を入れる" do
    snapshot = ReportSnapshotBuilder.new(@inspection.reload).build

    assert_equal 4, snapshot["overview_images"].size
    entry = snapshot["overview_images"].first
    assert_equal %w[id sequence captured_at blocks], entry.keys
    assert_equal "A01", entry["blocks"]
    assert_equal "proposal", snapshot["overview_source"]
  end
end
