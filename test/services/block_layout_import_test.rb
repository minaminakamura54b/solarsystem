require "test_helper"

# 架台の CSV による配置の登録。架台は地上の m で作り、GeoFrame で緯度経度にして CSV にする（合成データ）
class BlockLayoutImportTest < ActiveSupport::TestCase
  ORIGIN = [ 35.0, 139.0 ].freeze
  HEADER = "block_label,rows,cols,corner1_lat,corner1_lng,corner2_lat,corner2_lng,corner3_lat,corner3_lng,corner4_lat,corner4_lng"

  setup do
    @site = sites(:south) # 仮配置のパネル P001〜P003
    @frame = GeoFrame.new(*ORIGIN)
  end

  # 東西に長い架台（西端 e、南端 n、長さ 11.6 m・奥行き 4 m）の 4 隅の緯度経度（順番は order で入れ替える）
  def corners(e, n, length: 11.6, depth: 4.0, order: [ 0, 1, 2, 3 ])
    pts = [ [ e, n + depth ], [ e + length, n + depth ], [ e + length, n ], [ e, n ] ].map { |x, y| @frame.to_latlng(x, y) }
    order.map { |i| pts[i] }.flatten.map { |v| format("%.8f", v) }
  end

  def csv(*rows, header: HEADER) = ([ header ] + rows.map { |r| r.join(",") }).join("\n") + "\n"

  def two_rows_csv
    csv([ "", 2, 10, *corners(0, 13) ], [ "", 2, 10, *corners(11.85, 13) ], [ "", 2, 10, *corners(0, 0, order: [ 2, 0, 3, 1 ]) ])
  end

  def import(text) = BlockLayoutImport.new(@site, text)

  test "4 隅（順不同）から上端・下端と始まり・終わりを決め、架台ラベルを北の列から自動で付ける" do
    importer = import(two_rows_csv)

    assert importer.valid?, importer.errors.inspect
    assert_equal %w[A01 A02 B01], importer.blocks.map(&:label).sort
    south = importer.blocks.find { |b| b.label == "B01" }
    us, ue, le, ls = south.corners_local
    assert us[1] > ls[1], "上端（北）が先"
    assert us[0] < ue[0], "始まり（西）が先"
    assert_in_delta 11.6, south.length, 0.01
    assert_in_delta 4.0, south.depth, 0.01
    assert_in_delta le[0], ue[0], 0.01
  end

  test "パネルは架台ラベル-段-列で、位置は北の列から・西から。緯度経度はパネルの中心" do
    importer = import(two_rows_csv)
    rows = importer.panel_rows

    assert_equal 60, rows.size
    first = rows.find { |r| r["panel_number"] == "A01-1-01" }
    assert_equal [ 0, 0, "A", 1, 1 ], first.values_at("position_x", "position_y", "row_number", "block_row", "block_col")
    e, n = @frame.to_local(first["gps_lat"], first["gps_lng"])
    assert_in_delta 0.58, e, 0.01 # 11.6 / 10 / 2
    assert_in_delta 16.0, n, 0.01 # 13 + 4 - 4 / 2 / 2
    assert_equal [ 10, 0 ], rows.find { |r| r["panel_number"] == "A02-1-01" }.values_at("position_x", "position_y")
    assert_equal [ 0, 2 ], rows.find { |r| r["panel_number"] == "B01-1-01" }.values_at("position_x", "position_y")
    assert_equal rows.size, rows.map { |r| r.values_at("position_x", "position_y") }.uniq.size
  end

  test "パネルの向く方位が北なら、南側が上端になる" do
    importer = import(csv([ "X1", 2, 10, *corners(0, 0), "portrait", 0 ], header: HEADER + ",panel_orientation,facing_azimuth_deg"))

    us, _, _, ls = importer.blocks.first.corners_local
    assert us[1] < ls[1]
  end

  test "日本語の列名でも読み、書き出し用の列は無視する" do
    header = "架台ラベル,段数,列数,隅1緯度,隅1経度,隅2緯度,隅2経度,隅3緯度,隅3経度,隅4緯度,隅4経度,出どころ,確認が必要,観測の数"
    importer = import(csv([ "Z9", 2, 10, *corners(0, 0), "image_map", "true", 12 ], header:))

    assert importer.valid?, importer.errors.inspect
    assert_equal "image_map", importer.blocks.first.source
  end

  test "長方形でない・重なる・ラベルが重複する・値が不正なら、何も登録せずエラーを出す" do
    skew = corners(0, 0)
    skew[0], skew[1] = @frame.to_latlng(3, 4).map { |v| format("%.8f", v) } # 北西の隅を東へ 3 m ずらす（平行四辺形に近い形）
    assert_match "長方形", import(csv([ "S1", 2, 10, *skew ])).errors.join

    overlap = import(csv([ "O1", 2, 10, *corners(0, 0) ], [ "O2", 2, 10, *corners(5, 1) ]))
    assert_match "重なっています", overlap.errors.join
    assert_empty overlap.blocks

    dup = import(csv([ "D1", 2, 10, *corners(0, 0) ], [ "D1", 2, 10, *corners(0, 13) ]))
    assert_match "重複", dup.errors.join

    bad = import(csv([ "B-1", 0, 10, *corners(0, 0) ]))
    assert_match "「-」は使えません", bad.errors.join
    assert_match "段数", bad.errors.join
  end

  test "登録すると架台とパネルを置き換え、仮配置のパネルに付いた異常は割り当てを外す（Phase 5b と同じ）" do
    inspection = analyzable_inspection
    image = inspection.inspection_images.first
    placeholder = @site.panels.find_by!(number: "P001")
    anomaly = image.anomalies.create!(inspection:, panel: placeholder, anomaly_type: "hotspot", severity: "warning", review_status: "confirmed", locked: true)

    importer = import(two_rows_csv)
    importer.apply!(expected_digest: importer.plan.digest)

    @site.reload
    assert_equal 3, @site.pv_blocks.count
    assert_equal 60, @site.panels.count
    assert_equal 60, @site.panel_count
    assert @site.panels.all? { |p| p.pv_block_id && p.layout_source == "manual" }
    assert_not_nil @site.geo_origin_lat
    anomaly.reload
    assert_nil anomaly.panel_id
    assert anomaly.panel_reassignment_required
    assert_equal [ "confirmed", "warning", true ], [ anomaly.review_status, anomaly.severity, anomaly.locked ]
  end

  test "2 回目は同じ番号のパネルを更新し、消えた架台を削除する" do
    first = import(two_rows_csv)
    first.apply!(expected_digest: first.plan.digest)
    kept = @site.panels.find_by!(number: "A01-1-01")

    second = import(csv([ "A01", 2, 10, *corners(0, 13) ]))
    plan = second.plan
    assert_equal [ 0, 20, 40 ], [ plan.panel_plan.creates.size, plan.panel_plan.updates.size, plan.panel_plan.deletes.size ]
    second.apply!(expected_digest: plan.digest)

    assert_equal [ "A01" ], @site.pv_blocks.pluck(:label)
    assert_equal kept.id, @site.panels.find_by!(number: "A01-1-01").id
    assert_equal 20, @site.panels.count
  end

  test "確認画面の後に架台が変わったら確定しない" do
    importer = import(two_rows_csv)
    digest = importer.plan.digest
    other = import(csv([ "Q1", 2, 10, *corners(50, 50) ]))
    other.apply!(expected_digest: other.plan.digest)

    assert_raises(BlockLayoutImport::StalePlan) { import(two_rows_csv).apply!(expected_digest: digest) }
  end

  test "書き出した CSV を取り込むと同じ架台になる" do
    first = import(two_rows_csv)
    first.apply!(expected_digest: first.plan.digest)
    before = @site.pv_blocks.order(:label).map { |b| [ b.label, b.rows, b.cols, b.corners_local ] }

    again = import(BlockLayoutImport.export_csv(@site.reload))
    assert again.valid?, again.errors.inspect
    again.apply!(expected_digest: again.plan.digest)

    after = @site.reload.pv_blocks.order(:label).map { |b| [ b.label, b.rows, b.cols, b.corners_local ] }
    assert_equal before.map { |l, r, c, _| [ l, r, c ] }, after.map { |l, r, c, _| [ l, r, c ] }
    before.zip(after).each do |(_, _, _, a), (_, _, _, b)|
      a.flatten.zip(b.flatten).each { |x, y| assert_in_delta x, y, 0.01 }
    end
  end
end
