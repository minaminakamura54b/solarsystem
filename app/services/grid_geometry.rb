# 画像の中のグリッド（架台とつながった位置合わせのグリッド）の幾何（点検の範囲・対象範囲の案で使う）。
# グリッドの 4 隅は 上端の始まり・上端の終わり・下端の終わり・下端の始まり（0〜1 の正規化座標）
module GridGeometry
  LAYOUT_SOURCES = AnalysisResultImporter::BASIS.keys.freeze

  module_function

  def layout_grids(grids)
    Array(grids).select { |g| g["pv_block_id"].present? && LAYOUT_SOURCES.include?(g["source"]) }
  end

  # 中心が画像の中に入ったパネル [架台の id, 段, 列]（段・列は 1 始まり）
  def panel_keys(grids)
    grids.flat_map do |g|
      rows, cols, corners = g["rows"].to_i, g["cols"].to_i, g["corners"]
      next [] unless corners.is_a?(Array) && corners.size == 4

      (0...rows).flat_map do |r|
        (0...cols).filter_map do |c|
          x, y = bilinear(corners, (c + 0.5) / cols, (r + 0.5) / rows)
          [ g["pv_block_id"].to_i, r + 1, c + 1 ] if inside?(x, y)
        end
      end
    end
  end

  # 少しでも写った架台（パネルの中心か、架台の隅が画像の中に入った）
  def touched_block_ids(grids)
    grids.filter_map do |g|
      corners = g["corners"]
      next unless corners.is_a?(Array) && corners.size == 4

      hit = corners.any? { |x, y| inside?(x.to_f, y.to_f) } || panel_keys([ g ]).any?
      g["pv_block_id"].to_i if hit
    end.uniq
  end

  def inside?(x, y) = x.between?(0, 1) && y.between?(0, 1)

  # 4 隅の中の (u, v) の位置
  def bilinear(c, u, v)
    top = [ c[0][0] + (c[1][0] - c[0][0]) * u, c[0][1] + (c[1][1] - c[0][1]) * u ]
    bottom = [ c[3][0] + (c[2][0] - c[3][0]) * u, c[3][1] + (c[2][1] - c[3][1]) * u ]
    [ top[0] + (bottom[0] - top[0]) * v, top[1] + (bottom[1] - top[1]) * v ]
  end
end
