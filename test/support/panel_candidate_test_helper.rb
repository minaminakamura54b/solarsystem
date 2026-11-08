# パネルの候補のテスト用: 架台（2 段 × 10 列）を登録し、画像ごとの解析結果（パネルの位置）を合成で作る
module PanelCandidateTestHelper
  # labels の架台を東西に並べて登録する。戻り値: { "A01" => PvBlock, ... }
  def register_blocks(site, labels = %w[A01])
    frame = GeoFrame.new(35.0, 139.0)
    rows = labels.each_with_index.map do |label, i|
      e0 = i * 12.0
      pts = [ [ e0, 4 ], [ e0 + 11.6, 4 ], [ e0 + 11.6, 0 ], [ e0, 0 ] ].map { |e, n| frame.to_latlng(e, n) }
      "#{label},2,10,#{pts.flatten.map { |v| format('%.8f', v) }.join(',')}"
    end
    csv = "block_label,rows,cols,corner1_lat,corner1_lng,corner2_lat,corner2_lng,corner3_lat,corner3_lng,corner4_lat,corner4_lng\n#{rows.join("\n")}\n"
    importer = BlockLayoutImport.new(site, csv)
    importer.apply!(expected_digest: importer.plan.digest)
    site.pv_blocks.index_by(&:label)
  end

  # 画像を「解析済み」にする。blocks を横に並べたグリッドを、画像の縦位置 y0（0〜1）に置く
  def analyzed_image(image, blocks, y0:)
    grids = []
    panels = []
    blocks.each_with_index do |block, gi|
      x0 = 0.05 + gi * 0.45
      corners = [ [ x0, y0 ], [ x0 + 0.4, y0 ], [ x0 + 0.4, y0 + 0.2 ], [ x0, y0 + 0.2 ] ]
      grids << { "rows" => 2, "cols" => 10, "corners" => corners, "panel_orientation" => "portrait", "source" => "layout", "pv_block_id" => block.id }
      2.times do |r|
        10.times do |c|
          x1, y1 = x0 + c * 0.04, y0 + r * 0.1
          panels << { "index" => panels.size, "grid_index" => gi, "row" => r, "col" => c, "excluded" => false,
                      "bbox" => { "x1" => x1, "y1" => y1, "x2" => x1 + 0.04, "y2" => y1 + 0.1 },
                      "polygon" => [ [ x1, y1 ], [ x1 + 0.04, y1 ], [ x1 + 0.04, y1 + 0.1 ], [ x1, y1 + 0.1 ] ] }
        end
      end
    end
    image.update_columns(analysis_status: "completed", panel_grids: grids, raw_analysis: { "panels" => panels })
    image
  end

  # 画像の中のパネル（グリッド gi・段 row・列 col）に異常を置く。u, v はパネルの中の位置
  def anomaly_at(image, gi, row, col, type: "partial_module", u: 0.5, v: 0.5, delta_t: 2.0, **attrs)
    panel_index = gi * 20 + (row - 1) * 10 + (col - 1)
    p = image.raw_analysis["panels"][panel_index]["bbox"]
    cx = p["x1"] + (p["x2"] - p["x1"]) * u
    cy = p["y1"] + (p["y2"] - p["y1"]) * v
    block_id = image.panel_grids[gi]["pv_block_id"]
    panel = Panel.find_by!(pv_block_id: block_id, block_row: row, block_col: col)
    image.anomalies.create!({ inspection: image.inspection, panel:, panel_index_in_image: panel_index, anomaly_type: type,
                              severity: "mild", delta_t:, bbox: { "x1" => cx - 0.002, "y1" => cy - 0.002, "x2" => cx + 0.002, "y2" => cy + 0.002 } }.merge(attrs))
  end
end
